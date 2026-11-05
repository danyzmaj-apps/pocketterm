package com.danyzmaj.pocketterm.ui.voice

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.ui.semantics.semantics
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import com.danyzmaj.pocketterm.core.SpeechCheck
import com.danyzmaj.pocketterm.core.SpeechEnd
import com.danyzmaj.pocketterm.core.SpeechEvent
import com.danyzmaj.pocketterm.core.SpeechFix
import com.danyzmaj.pocketterm.core.SpeechLanguage
import com.danyzmaj.pocketterm.core.SpeechSource
import com.danyzmaj.pocketterm.core.SpeechStatus
import com.danyzmaj.pocketterm.state.VoiceLanguage
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.common.Haptics
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private enum class Phase { checking, problem, downloading, listening, stopping, review }

/**
 * What the voice sheet shows, full screen: the composer's [existing] text dimmed, then what's said,
 * live and large; once stopped, editable in place with Keep talking, Insert and Send. [title]: the
 * session it's for, under the sheet's own title. [hold]: opened by a hold, which lifting stops.
 * Leaving the app or a call stops it, keeping what was said. [onClose] gets what the person did
 * with it, null when cancelled or closed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceSheet(existing: String, title: String, hold: VoiceHold?, onClose: (VoiceResult?) -> Unit) {
    val graph = LocalGraph.current
    val scope = rememberCoroutineScope()
    val haptics = rememberHaptics()
    val close by rememberUpdatedState(onClose)
    val m = remember { VoiceSheetModel(graph.speech, graph.voiceLanguage, scope, hold, haptics) { close(it) } }

    DisposableEffect(m) {
        m.start()
        // Out of sight: the microphone stops, what was said stays to check when the person is back.
        val observer = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_STOP) m.stop() }
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            // Closed while listening: what was heard goes, and the microphone stops at once.
            m.dispose()
        }
    }
    if (hold != null) {
        LaunchedEffect(hold) {
            snapshotFlow { hold.down }.collect { down -> if (!down) m.holdReleased() }
        }
    }

    val focus = LocalFocusManager.current
    val away = m.held && hold?.away == true
    val heading = when (m.phase) {
        Phase.checking, Phase.listening, Phase.stopping -> if (away) "Release to cancel" else "Listening"
        Phase.downloading -> "Downloading"
        Phase.problem, Phase.review -> "Voice prompt"
    }

    Dialog(
        onDismissRequest = { m.close(null) },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Scaffold(
            // A tap outside the text puts the keyboard away.
            modifier = Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { focus.clearFocus() } },
            topBar = {
                TopAppBar(
                    title = {
                        Column {
                            Text(heading)
                            if (title.isNotBlank()) {
                                Text(
                                    title,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = { m.close(null) }, modifier = Modifier.tag("voice-close")) {
                            Icon(Icons.Rounded.Close, contentDescription = "Close")
                        }
                    },
                    actions = { LanguageChip(m) },
                )
            },
            bottomBar = {
                Box(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime))) {
                    Controls(m, away)
                }
            },
        ) { padding ->
            Column(
                Modifier
                    .padding(padding)
                    .fillMaxSize()
                    // The newest words stay in view as they come; while they fit, they read from the top.
                    .verticalScroll(rememberScrollState(), reverseScrolling = true)
                    .padding(horizontal = 20.dp, vertical = 8.dp),
            ) {
                val before = existing.trim()
                if (before.isNotEmpty() && m.phase != Phase.problem) {
                    Text(
                        before,
                        modifier = Modifier.tag("voice-existing").padding(bottom = 8.dp),
                        style = TextStyle(fontSize = 20.sp, lineHeight = 27.sp),
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .45f),
                    )
                }
                Body(m)
            }
        }
    }
}

private val big = TextStyle(fontSize = 28.sp, lineHeight = 36.sp, fontWeight = FontWeight.Medium)

@Composable
private fun Body(m: VoiceSheetModel) {
    val c = MaterialTheme.colorScheme
    when (m.phase) {
        Phase.problem -> {
            Text(
                speechProblemText(m.problem, m.language),
                modifier = Modifier.tag("voice-problem"),
                style = TextStyle(fontSize = 18.sp, lineHeight = 25.sp),
                color = c.onSurface,
            )
            m.note?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, style = MaterialTheme.typography.bodyMedium, color = c.onSurfaceVariant)
            }
        }
        Phase.downloading -> Text(
            "Downloading ${m.language.title} for speech recognition…",
            style = TextStyle(fontSize = 18.sp, lineHeight = 25.sp),
            color = c.onSurfaceVariant,
        )
        Phase.checking, Phase.listening, Phase.stopping -> LiveWords(m.heard, Modifier.tag("voice-live"))
        Phase.review -> {
            TextField(
                value = m.edit,
                onValueChange = { m.edit = it },
                modifier = Modifier.fillMaxWidth().tag("voice-edit"),
                textStyle = big.copy(color = c.onSurface),
                placeholder = { Text("Nothing heard", style = big, color = c.onSurface.copy(alpha = .38f)) },
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                ),
            )
            m.note?.let {
                Spacer(Modifier.height(12.dp))
                Text(it, modifier = Modifier.tag("voice-note"), style = MaterialTheme.typography.bodyMedium, color = LocalStatus.current.needs)
            }
        }
    }
}

/**
 * What's being said, large: each new word fades in as the recognizer adds it; a word it revises
 * swaps in place. One string, so it wraps, reads to TalkBack and is found as the text it is. Until
 * something's heard, "Speak now…".
 */
@Composable
private fun LiveWords(text: String, modifier: Modifier) {
    val color = MaterialTheme.colorScheme.onSurface
    val words = remember(text) { Regex("\\S+\\s*").findAll(text).map { it.value }.toList() }
    // A place that had a word keeps its fade (done or under way); only places past the old end fade in.
    val first = remember { words.size }
    val kept = remember { mutableListOf<Animatable<Float, AnimationVector1D>>() }
    // Grown or cut once per word count, not on every recomposition.
    val alphas = remember(words.size) {
        while (kept.size > words.size) kept.removeAt(kept.lastIndex)
        while (kept.size < words.size) kept.add(Animatable(if (kept.size < first) 1f else 0f))
        kept.toList()
    }
    LaunchedEffect(alphas) {
        for (a in alphas) if (a.targetValue < 1f) launch { a.animateTo(1f, tween(200)) }
    }
    if (words.isEmpty()) {
        Text("Speak now…", modifier = modifier, style = big, color = color.copy(alpha = .38f))
        return
    }
    val shown: AnnotatedString = buildAnnotatedString {
        words.forEachIndexed { i, w ->
            pushStyle(SpanStyle(color = color.copy(alpha = alphas.getOrNull(i)?.value ?: 1f)))
            append(w)
            pop()
        }
    }
    Text(shown, modifier = modifier, style = big)
}

/** The language it listens in; a tap switches to the other one. Not while starting, stopping, downloading or held. */
@Composable
private fun LanguageChip(m: VoiceSheetModel) {
    val can = !m.held && (m.phase == Phase.listening || m.phase == Phase.problem || m.phase == Phase.review)
    val language = m.language
    TextButton(
        onClick = { m.switchLanguage() },
        enabled = can,
        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
        modifier = Modifier.clearAndSetSemantics {
            testTag = "voice-language"
            contentDescription = "Language: ${language.title}. Switch"
            role = Role.Button
            if (can) {
                onClick {
                    m.switchLanguage()
                    true
                }
            } else {
                disabled()
            }
        },
    ) {
        Icon(Icons.Rounded.Translate, contentDescription = null, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(language.label)
    }
}

/** Which controls show: listening's orb, a problem's buttons, the download's spinner, or the review's. */
private enum class ControlSet { listening, problem, downloading, review }

@Composable
private fun Controls(m: VoiceSheetModel, away: Boolean) {
    val group = when (m.phase) {
        Phase.checking, Phase.listening, Phase.stopping -> ControlSet.listening
        Phase.problem -> ControlSet.problem
        Phase.downloading -> ControlSet.downloading
        Phase.review -> ControlSet.review
    }
    AnimatedContent(
        targetState = group,
        transitionSpec = { (fadeIn() + scaleIn(initialScale = .95f)) togetherWith fadeOut() using SizeTransform(clip = false) },
        contentAlignment = Alignment.BottomCenter,
        label = "voice-controls",
    ) { shown ->
        Box(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 12.dp)) {
            when (shown) {
                ControlSet.problem -> ProblemControls(m)
                ControlSet.downloading -> CircularProgressIndicator(Modifier.size(24.dp).align(Alignment.Center), strokeWidth = 2.dp)
                ControlSet.listening -> ListeningControls(m, away)
                ControlSet.review -> ReviewControls(m)
            }
        }
    }
}

@Composable
private fun ProblemControls(m: VoiceSheetModel) {
    val p = m.problem
    val fix = p.fix
    val (label, act) = when {
        p.status == SpeechStatus.downloading -> "Try again" to { m.start() }
        fix == SpeechFix.download -> "Download" to { m.fix(SpeechFix.download) }
        fix != null -> "Open Settings" to { m.fix(fix) }
        else -> null to null
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
        TextButton(onClick = { m.close(null) }, modifier = Modifier.tag("voice-cancel")) { Text("Cancel") }
        if (label != null && act != null) {
            Button(onClick = act, modifier = Modifier.tag("voice-fix")) { Text(label) }
        }
    }
}

@Composable
private fun ListeningControls(m: VoiceSheetModel, away: Boolean) {
    val listening = m.phase == Phase.listening
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        if (m.held) {
            MicOrb(m.level.toFloat(), away = away, busy = !listening, held = true)
            // A tap needs no hint: the orb is the stop button. A hold says how to stop or cancel.
            Text(
                if (away) "Release to cancel" else "Release to stop · Slide away to cancel",
                modifier = Modifier.tag("voice-hold-hint").padding(top = 8.dp),
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodyMedium,
                color = if (away) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            Box(
                Modifier
                    .tag("voice-stop")
                    .semantics { contentDescription = "Stop" }
                    .clickable(enabled = listening, role = Role.Button) { m.stop() },
            ) {
                MicOrb(m.level.toFloat(), away = false, busy = !listening, held = false)
            }
        }
    }
}

/**
 * The microphone while it listens: a disc whose rings swell with the loudness, in the error colour
 * while a slide away would cancel, dimmed while it isn't listening (starting or stopping).
 */
@Composable
private fun MicOrb(level: Float, away: Boolean, busy: Boolean, held: Boolean) {
    val c = MaterialTheme.colorScheme
    val loud by animateFloatAsState(if (busy) 0f else level, spring(stiffness = Spring.StiffnessMediumLow), label = "orb-level")
    val tint by animateColorAsState(
        when {
            away -> c.error
            busy -> c.onSurfaceVariant
            else -> c.primary
        },
        label = "orb-tint",
    )
    val on = if (away) c.onError else if (busy) c.surface else c.onPrimary
    val dim by animateFloatAsState(if (busy) .5f else 1f, label = "orb-dim")
    Box(Modifier.size(132.dp), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(132.dp)
                .graphicsLayer {
                    val s = .62f + .38f * loud
                    scaleX = s
                    scaleY = s
                    alpha = dim
                }
                .background(tint.copy(alpha = .14f), CircleShape),
        )
        Box(
            Modifier
                .size(104.dp)
                .graphicsLayer {
                    val s = .78f + .22f * loud
                    scaleX = s
                    scaleY = s
                    alpha = dim
                }
                .background(tint.copy(alpha = .24f), CircleShape),
        )
        Box(
            Modifier.size(72.dp).graphicsLayer { alpha = dim }.background(tint, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(if (held) Icons.Rounded.Mic else Icons.Rounded.Stop, contentDescription = null, tint = on, modifier = Modifier.size(32.dp))
        }
    }
}

@Composable
private fun ReviewControls(m: VoiceSheetModel) {
    val can = m.edit.trim().isNotEmpty()
    // No Cancel: the sheet's close button and Back already do that.
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledTonalButton(
            onClick = { m.keepTalking() },
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).tag("voice-more"),
        ) {
            Icon(Icons.Rounded.Mic, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text("Keep talking")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = { m.finish(send = false) },
                enabled = can,
                modifier = Modifier.weight(1f).heightIn(min = 48.dp).tag("voice-insert"),
            ) { Text("Insert") }
            Button(
                onClick = { m.finish(send = true) },
                enabled = can,
                modifier = Modifier.weight(1f).heightIn(min = 48.dp).tag("voice-send"),
            ) { Text("Send") }
        }
    }
}

/** The voice sheet's listening: its phases, what was heard, and what the person does with it (lib/voice.dart's _VoiceSheetState). */
private class VoiceSheetModel(
    private val source: SpeechSource,
    private val languages: VoiceLanguage,
    private val scope: CoroutineScope,
    private val hold: VoiceHold?,
    private val haptics: Haptics,
    private val onClose: (VoiceResult?) -> Unit,
) {
    var phase by mutableStateOf(Phase.checking)
        private set
    var problem by mutableStateOf(SpeechCheck(SpeechStatus.ready))
        private set
    var heard by mutableStateOf("")
        private set
    var level by mutableDoubleStateOf(0.0)
        private set
    var edit by mutableStateOf("")

    /** Why listening ended early, shown under the text. */
    var note by mutableStateOf<String?>(null)
        private set

    /** Still held to talk: lifting stops. False after a lift, or for a tap. */
    var held by mutableStateOf(hold?.down ?: false)
        private set

    /** What it listens in: until Auto has asked the phone, its first guess. */
    var language by mutableStateOf(languages.choice ?: languages.guess)
        private set

    /** What was said (and edited) before Keep talking: the new words go after it. */
    private var before = ""
    private var sub: Job? = null
    private var stopWait: Job? = null

    /** Bumped by each start, so one overtaken by a newer one (a language switch) gives up. */
    private var starts = 0
    private var gone = false

    fun close(result: VoiceResult?) {
        if (gone) return
        onClose(result)
    }

    fun dispose() {
        gone = true
        stopWait?.cancel()
        sub?.cancel()
        sub = null
    }

    fun start() {
        scope.launch { listen() }
    }

    private suspend fun listen() {
        val gen = ++starts
        phase = Phase.checking
        val l = languages.resolve(source)
        if (gen != starts || gone) return
        language = l
        val check = try {
            source.check(l)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            SpeechCheck(SpeechStatus.unavailable)
        }
        if (gen != starts || gone) return
        if (!check.ready) {
            problem = check
            phase = Phase.problem
            return
        }
        haptics.longPress()
        sub = scope.launch {
            try {
                source.listen(l).collect(::on)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ended(SpeechEnd.error, e.message ?: e.toString())
                return@launch
            }
            ended(SpeechEnd.stopped)
        }
        phase = Phase.listening
    }

    private fun on(e: SpeechEvent) {
        when (e) {
            is SpeechEvent.Heard -> if (phase == Phase.listening || phase == Phase.stopping) heard = appendSpoken(before, e.text)
            is SpeechEvent.Level -> level = e.level
            is SpeechEvent.Ended -> {
                val status = e.status
                if (status != null && status != SpeechStatus.ready && heard.isBlank()) {
                    sub?.cancel()
                    sub = null
                    // Auto's pick turned out missing only now: it listens in the next language Auto has, without asking.
                    if (status == SpeechStatus.noLanguage && languages.choice == null && language != SpeechLanguage.english) {
                        languages.missed(language)
                        start()
                        return
                    }
                    problem = SpeechCheck(status, if (status == SpeechStatus.noLanguage) SpeechFix.speechSettings else null)
                    phase = Phase.problem
                    return
                }
                ended(e.why, e.message)
            }
        }
    }

    fun holdReleased() {
        if (!held) return
        held = false
        if (hold?.away == true) {
            sub?.cancel()
            sub = null
            close(null)
            return
        }
        // Lifted before listening began (a permission prompt took the finger): it goes on until Stop, as for a tap.
        if (phase == Phase.listening) stop()
    }

    fun stop() {
        if (phase != Phase.listening) return
        phase = Phase.stopping
        // The recognizer settles the last words and says so; one that doesn't answer still leaves what it heard.
        stopWait = scope.launch {
            delay(3000)
            ended(SpeechEnd.stopped)
        }
        scope.launch {
            try {
                source.stop()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                ended(SpeechEnd.error, e.message ?: e.toString())
            }
        }
    }

    private fun ended(why: SpeechEnd, message: String? = null) {
        if (gone || (phase != Phase.listening && phase != Phase.stopping)) return
        stopWait?.cancel()
        stopWait = null
        sub?.cancel()
        sub = null
        level = 0.0
        haptics.picked()
        held = false
        note = when (why) {
            SpeechEnd.stopped -> null
            SpeechEnd.interrupted -> "Stopped: something else took the microphone."
            SpeechEnd.error -> if (message.isNullOrEmpty()) "Listening stopped." else "Listening stopped: $message"
        }
        edit = heard.trim()
        phase = Phase.review
    }

    /** Listens again, the new words after what's in the editor now. */
    fun keepTalking() {
        before = edit.trim()
        heard = before
        note = null
        start()
    }

    /**
     * Listens in the other language from now on, and keeps it for this phone. Mid-listening, the
     * words so far stay and listening goes on in the new one; a problem is checked again for it.
     */
    fun switchLanguage() {
        val all = SpeechLanguage.entries
        val next = all[(language.ordinal + 1) % all.size]
        language = next
        languages.choose(next)
        when (phase) {
            Phase.listening -> {
                sub?.cancel()
                sub = null
                before = heard.trim()
                heard = before
                start()
            }
            Phase.problem -> {
                note = null
                start()
            }
            Phase.review, Phase.checking, Phase.stopping, Phase.downloading -> Unit
        }
    }

    fun fix(fix: SpeechFix) {
        scope.launch {
            if (fix != SpeechFix.download) {
                try {
                    source.fix(fix, language)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    note = e.message ?: e.toString()
                }
                return@launch
            }
            phase = Phase.downloading
            try {
                source.fix(fix, language)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (gone) return@launch
                problem = SpeechCheck(SpeechStatus.noLanguage, SpeechFix.download)
                note = e.message ?: e.toString()
                phase = Phase.problem
                return@launch
            }
            note = null
            listen()
        }
    }

    fun finish(send: Boolean) {
        val text = edit.trim()
        if (text.isEmpty()) return
        close(VoiceResult(text, send))
    }
}
