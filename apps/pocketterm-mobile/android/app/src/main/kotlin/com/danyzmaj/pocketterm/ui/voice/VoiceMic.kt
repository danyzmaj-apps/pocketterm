package com.danyzmaj.pocketterm.ui.voice

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MicNone
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.SpeechCheck
import com.danyzmaj.pocketterm.core.SpeechEvent
import com.danyzmaj.pocketterm.core.SpeechFix
import com.danyzmaj.pocketterm.core.SpeechLanguage
import com.danyzmaj.pocketterm.core.SpeechStatus
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What the person did with what they said: [send] it as the composer would, or insert it into the composer. */
data class VoiceResult(val text: String, val send: Boolean)

/** [existing] and then [spoken], a space between them when [existing] has words. */
fun appendSpoken(existing: String, spoken: String): String {
    val before = existing.trimEnd()
    return if (before.isEmpty()) spoken else "$before $spoken"
}

/** Why the phone can't listen in [language], as [c] says, for the person. */
fun speechProblemText(c: SpeechCheck, language: SpeechLanguage): String {
    val lang = language.title
    return when (c.status) {
        SpeechStatus.denied -> "PocketTerm isn’t allowed to use the microphone. Allow it in Settings."
        SpeechStatus.restricted -> "Speech recognition is turned off on this phone."
        SpeechStatus.noLanguage -> when (c.fix) {
            SpeechFix.download ->
                "$lang for speech recognition isn’t on this phone yet. Download it once; what you say stays on the phone."
            SpeechFix.speechSettings ->
                "This phone has no $lang for speech recognition on the device. Add it in the phone’s speech settings."
            else -> "$lang isn’t supported for speech recognition on this phone. Tap the language above to pick another."
        }
        SpeechStatus.downloading -> "$lang for speech recognition is downloading. Try again when it’s done."
        SpeechStatus.unavailable, SpeechStatus.ready ->
            "This phone can’t recognize speech on the device, so voice prompts are off here."
    }
}

/** Held this long, a press is a hold rather than a tap. */
private const val holdAfterMs = 300L

/** Slid this far up or left while held, lifting the finger cancels. */
val voiceCancelDistance = 100.dp

/** A hold on the microphone in progress: whether the finger is still down, and whether it slid away to cancel. */
class VoiceHold {
    var down by mutableStateOf(true)
        private set
    private var awayState by mutableStateOf(false)

    var away: Boolean
        get() = awayState
        set(v) {
            if (down) awayState = v
        }

    fun release() {
        down = false
    }
}

/**
 * The composer's microphone. A tap opens the voice sheet, which listens until Stop; a hold opens it
 * at once and listens while held: lifting the finger stops and leaves what was said to check,
 * sliding far up or left first cancels. [existing]: the composer's text then, shown dimmed above
 * what's said; the result's text is it with what was said after ([appendSpoken]). [small]: inside
 * the field, beside the send button: smaller and dimmer.
 */
@Composable
fun VoiceMic(
    existing: String,
    title: String,
    onResult: (VoiceResult) -> Unit,
    modifier: Modifier = Modifier,
    small: Boolean = false,
) {
    val latestExisting by rememberUpdatedState(existing)
    val latestResult by rememberUpdatedState(onResult)
    // The sheet open, with the composer's text as it was then and the hold that opened it (null: a tap).
    var sheet by remember { mutableStateOf<Pair<String, VoiceHold?>?>(null) }
    // A finger is on it and it hasn't opened yet: it grows on a disc, so a hold shows it's taking.
    var pressed by remember { mutableStateOf(false) }
    val open: (VoiceHold?) -> Unit = { hold ->
        if (sheet == null) sheet = latestExisting to hold
    }
    val cancelPx = with(LocalDensity.current) { voiceCancelDistance.toPx() }
    val color = if (small) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.primary
    val grow by animateFloatAsState(if (pressed) 1.15f else 1f, label = "mic-press")
    val disc by animateFloatAsState(if (pressed) 1f else 0f, label = "mic-disc")

    Box(
        modifier
            .tag(if (small) "session-mic-small" else "session-mic")
            .semantics {
                role = Role.Button
                contentDescription = "Voice prompt"
                onClick {
                    open(null)
                    true
                }
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    if (sheet != null) return@awaitEachGesture
                    pressed = true
                    // Up before the hold time: a tap (true). Moved past the slop, or taken by a scroll or the system
                    // (its lift comes consumed): neither (false). Null: still down, a hold.
                    val early = withTimeoutOrNull(holdAfterMs) {
                        var tap: Boolean? = null
                        while (tap == null) {
                            val c = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                            tap = when {
                                c == null -> false
                                !c.pressed -> !c.isConsumed
                                c.isConsumed || (c.position - down.position).getDistance() > viewConfiguration.touchSlop -> false
                                else -> null
                            }
                        }
                        tap
                    }
                    pressed = false
                    when (early) {
                        true -> open(null)
                        false -> Unit
                        null -> {
                            // The sheet is a window of its own, but the finger's touches keep coming here until it lifts.
                            val hold = VoiceHold()
                            open(hold)
                            while (hold.down) {
                                val c = awaitPointerEvent().changes.firstOrNull { it.id == down.id }
                                if (c == null || !c.pressed) {
                                    hold.release()
                                } else {
                                    val d = c.position - down.position
                                    hold.away = d.y < -cancelPx || d.x < -cancelPx
                                }
                            }
                        }
                    }
                }
            }
            .size(width = if (small) 36.dp else 48.dp, height = 48.dp),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(if (small) 32.dp else 40.dp)
                .alpha(disc)
                .background(color.copy(alpha = .16f), CircleShape),
        )
        Icon(
            Icons.Rounded.MicNone,
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(if (small) 20.dp else 24.dp).scale(grow),
        )
    }

    sheet?.let { (text, hold) ->
        VoiceSheet(existing = text, title = title, hold = hold) { result ->
            sheet = null
            if (result != null) latestResult(VoiceResult(appendSpoken(text, result.text), result.send))
        }
    }
}

/**
 * The orchestrator's microphone: listens only while held and never sends. [onListening] gets
 * (listening, the words so far, the loudness) for the composer's live line; on release [onText]
 * gets what was heard (trimmed, never empty), for the caller to put after the field's text.
 * [onError]: why it can't listen ([speechProblemText]), null as a hold starts.
 */
@Composable
fun HoldToTalkMic(
    onText: (String) -> Unit,
    onListening: (Boolean, String, Double) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onError: (String?) -> Unit = {},
) {
    val graph = LocalGraph.current
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()
    val text by rememberUpdatedState(onText)
    val listeningCb by rememberUpdatedState(onListening)
    val error by rememberUpdatedState(onError)
    val talk = remember { HoldTalk() }
    talk.report = { listeningCb(it.voice != HoldTalk.Voice.off, it.live, it.level) }

    DisposableEffect(Unit) {
        onDispose { talk.sub?.cancel() }
    }

    fun finish() {
        if (talk.voice == HoldTalk.Voice.off) return
        talk.stopWait?.cancel()
        talk.sub?.cancel()
        talk.sub = null
        val heard = talk.live.trim()
        talk.live = ""
        talk.level = 0.0
        talk.voice = HoldTalk.Voice.off
        talk.changed()
        if (heard.isNotEmpty()) {
            text(heard)
            haptics.picked()
        }
    }

    suspend fun down() {
        if (talk.voice != HoldTalk.Voice.off) return
        talk.released = false
        error(null)
        talk.voice = HoldTalk.Voice.checking
        talk.changed()
        // The language the voice sheet listens in: the phone's choice, else Auto's.
        val language = graph.voiceLanguage.resolve(graph.speech)
        val check = try {
            graph.speech.check(language)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            SpeechCheck(SpeechStatus.unavailable)
        }
        if (!check.ready) {
            error(speechProblemText(check, language))
            talk.voice = HoldTalk.Voice.off
            talk.changed()
            return
        }
        // Lifted while it checked: nothing heard.
        if (talk.released) {
            talk.voice = HoldTalk.Voice.off
            talk.changed()
            return
        }
        haptics.longPress()
        talk.sub = scope.launch {
            try {
                graph.speech.listen(language).collect { e ->
                    when (e) {
                        is SpeechEvent.Heard -> {
                            talk.live = e.text
                            talk.changed()
                        }
                        is SpeechEvent.Level -> {
                            talk.level = e.level
                            talk.changed()
                        }
                        is SpeechEvent.Ended -> finish()
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
            finish()
        }
        talk.voice = HoldTalk.Voice.listening
        talk.changed()
    }

    suspend fun up() {
        talk.released = true
        if (talk.voice != HoldTalk.Voice.listening) return
        talk.voice = HoldTalk.Voice.stopping
        talk.changed()
        talk.stopWait = scope.launch {
            delay(3000)
            finish()
        }
        try {
            graph.speech.stop()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            finish()
        }
    }

    val on = talk.voice == HoldTalk.Voice.listening || talk.voice == HoldTalk.Voice.stopping
    val c = MaterialTheme.colorScheme
    Box(
        modifier
            .tag("orchestrator-mic")
            .semantics {
                role = Role.Button
                contentDescription = "Microphone"
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                awaitEachGesture {
                    val first = awaitFirstDown(requireUnconsumed = false)
                    first.consume()
                    scope.launch { down() }
                    // Up, or taken by the system: either way it stops.
                    do {
                        val event = awaitPointerEvent()
                    } while (event.changes.any { it.id == first.id && it.pressed })
                    scope.launch { up() }
                }
            }
            .size(48.dp),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (on) Icons.Rounded.Mic else Icons.Rounded.MicNone,
            contentDescription = null,
            tint = when {
                !enabled -> c.onSurface.copy(alpha = .38f)
                on -> c.primary
                else -> c.onSurfaceVariant
            },
        )
    }
}

/** [HoldToTalkMic]'s listening, kept across recompositions; [changed] tells the composer. */
private class HoldTalk {
    enum class Voice { off, checking, listening, stopping }

    var voice by mutableStateOf(Voice.off)
    var live = ""
    var level = 0.0

    /** The finger came up (perhaps before listening started). */
    var released = false
    var sub: Job? = null
    var stopWait: Job? = null
    var report: (HoldTalk) -> Unit = {}

    fun changed() = report(this)
}
