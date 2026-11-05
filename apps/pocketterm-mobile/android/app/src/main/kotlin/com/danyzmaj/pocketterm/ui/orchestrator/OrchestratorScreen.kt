package com.danyzmaj.pocketterm.ui.orchestrator

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ArrowUpward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.OpenInFull
import androidx.compose.material.icons.rounded.StopCircle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.ItemKind
import com.danyzmaj.pocketterm.core.LiveItem
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.TerminalException
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.core.routedKey
import com.danyzmaj.pocketterm.state.HomeController
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.session.MarkdownText
import com.danyzmaj.pocketterm.ui.terminal.Tooltipped
import com.danyzmaj.pocketterm.ui.home.termError
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import com.danyzmaj.pocketterm.ui.voice.HoldToTalkMic
import com.danyzmaj.pocketterm.ui.voice.appendSpoken
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration.Companion.seconds

/**
 * The orchestrator's chat, full screen: what was asked and answered, and a composer that starts the
 * orchestrator on the computer when none runs.
 */
@Composable
fun OrchestratorScreen(home: HomeController) {
    home.observe()
    val remote = home.remote
    if (remote == null) {
        // The computer went (signed out of it, locked): nothing to ask.
        val nav = LocalNav.current
        LaunchedEffect(Unit) { nav.back() }
        return
    }
    OrchestratorPage(remote, home.desktops.selected?.name)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OrchestratorPage(remote: TerminalRemote, computer: String?) {
    remote.observe()
    val nav = LocalNav.current
    val graph = LocalGraph.current
    val c = MaterialTheme.colorScheme
    val o = remote.orchestrator

    // The orchestrator the computer streams to this phone: without a watch it sends no transcript.
    DisposableEffect(remote, o?.key) {
        val unwatch = o?.key?.let { remote.watchSession(it) }
        onDispose { unwatch?.invoke() }
    }

    val draftKey = remember(remote) { routedKey(remote.desktopId, "orchestrator") }
    var field by rememberSaveable(stateSaver = TextFieldValue.Saver) {
        val d = graph.session.drafts.load(draftKey)
        mutableStateOf(TextFieldValue(d, TextRange(d.length)))
    }
    val currentField by rememberUpdatedState(field)
    DisposableEffect(draftKey) {
        onDispose { graph.session.drafts.save(draftKey, currentField.text) }
    }
    // What went wrong last, shown above the composer; Stop sets it too.
    var error by remember { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf(false) }
    var starting by remember { mutableStateOf(false) }
    // Held, the microphone listens: what it heard so far, and how loud.
    var listening by remember { mutableStateOf(false) }
    var live by remember { mutableStateOf("") }
    var level by remember { mutableDoubleStateOf(0.0) }
    val focus = remember { FocusRequester() }

    fun send() {
        val text = field.text.trim()
        if (text.isEmpty() || sending) return
        sending = true
        error = null
        // The app's scope: closed while it goes, the prompt is sent all the same, and its draft goes.
        graph.scope.launch {
            try {
                var orch = remote.orchestrator
                if (orch == null) {
                    starting = true
                    remote.startOrchestrator()
                    // The computer reports it once omp is up (it says hello).
                    orch = withTimeoutOrNull(30.seconds) {
                        remote.revision.first { remote.orchestrator != null }
                        remote.orchestrator
                    } ?: throw TerminalException(
                        "The orchestrator didn't start on the computer. Look at its terminal window.",
                    )
                }
                remote.prompt(orch.key, text)
                field = TextFieldValue("")
                graph.session.drafts.save(draftKey, "")
            } catch (e: Exception) {
                error = termError(e)
            } finally {
                sending = false
                starting = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    val state = when {
                        o?.ask != null -> " · Needs you"
                        o?.busy == true -> " · Working…"
                        else -> ""
                    }
                    Text(
                        buildAnnotatedString {
                            append("Orchestrator")
                            withStyle(SpanStyle(color = c.onSurfaceVariant)) { append(state) }
                        },
                        maxLines = 1,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = { nav.back() }, modifier = Modifier.tag("orchestrator-close")) {
                        Icon(Icons.Rounded.Close, contentDescription = "Close")
                    }
                },
                actions = {
                    if (o != null && o.busy && remote.online) {
                        Tooltipped("Stop") {
                            IconButton(
                                onClick = {
                                    graph.scope.launch {
                                        try {
                                            remote.abort(o.key)
                                        } catch (e: Exception) {
                                            error = termError(e)
                                        }
                                    }
                                },
                                modifier = Modifier.tag("orchestrator-stop"),
                            ) { Icon(Icons.Rounded.StopCircle, contentDescription = "Stop") }
                        }
                    }
                    if (o != null) {
                        Tooltipped("Open conversation") {
                            IconButton(
                                onClick = { open(nav, o.key) },
                                modifier = Modifier.tag("orchestrator-open"),
                            ) { Icon(Icons.Rounded.OpenInFull, contentDescription = "Open conversation") }
                        }
                    }
                },
            )
        },
    ) { inner ->
        // Held, the microphone lights the whole sheet: it's listening.
        val edge by animateColorAsState(if (listening) c.primary else Color.Transparent, label = "listening")
        val wash by animateColorAsState(if (listening) c.primary.copy(alpha = .06f) else Color.Transparent, label = "wash")
        Surface(
            color = wash,
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier
                .padding(inner)
                .consumeWindowInsets(inner)
                .imePadding()
                .padding(start = 8.dp, end = 8.dp, bottom = 8.dp)
                .fillMaxSize()
                .border(2.dp, edge, RoundedCornerShape(16.dp))
                .tag("orchestrator-sheet"),
        ) {
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    Chat(remote, o, computer) { open(nav, it) }
                }
                Composer(
                    field = field,
                    onField = { field = it },
                    focus = focus,
                    listening = listening,
                    live = live,
                    level = level,
                    error = error,
                    starting = starting,
                    computer = computer,
                    sending = sending,
                    onSend = ::send,
                    onHeard = { heard ->
                        // Never sends: what was heard goes after what's there, to edit or send.
                        val text = appendSpoken(field.text, heard)
                        field = TextFieldValue(text, TextRange(text.length))
                        focus.requestFocus()
                    },
                    onListening = { on, words, loud ->
                        listening = on
                        live = if (on) words else ""
                        level = if (on) loud else 0.0
                    },
                    onError = { error = it },
                )
            }
        }
    }
}

/** Session [key]'s own page in place of this one: it answers what it asks and shows its whole transcript. */
private fun open(nav: com.danyzmaj.pocketterm.ui.Nav, key: String) {
    nav.back()
    nav.openSession(key)
}

/** The person's prompts and the orchestrator's answers (no tools), newest at the bottom. */
@Composable
private fun BoxScope.Chat(remote: TerminalRemote, o: LiveSummary?, computer: String?, onOpen: (String) -> Unit) {
    val chat = o?.let { remote.view(it.key) }?.items.orEmpty()
        .filter { (it.kind == ItemKind.user || it.kind == ItemKind.assistant) && it.text.isNotBlank() }
    val c = MaterialTheme.colorScheme
    if (chat.isEmpty()) {
        Text(
            "Ask about the sessions on ${computer ?: "this computer"}: what’s running, what’s stuck, what each " +
                "one did. It can also prompt or stop them.",
            color = c.onSurfaceVariant,
            textAlign = TextAlign.Center,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.align(Alignment.Center).padding(32.dp),
        )
        return
    }
    val ask = o?.ask
    LazyColumn(
        reverseLayout = true,
        contentPadding = PaddingValues(vertical = 8.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        if (o != null && ask != null) {
            item(key = "orchestrator-answer") {
                Row(
                    Modifier.padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp).tag("orchestrator-answer"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Needs you: ${ask.text}", color = LocalStatus.current.needs, modifier = Modifier.weight(1f))
                    TextButton(onClick = { onOpen(o.key) }) { Text("Answer") }
                }
            }
        } else if (o?.busy == true) {
            item(key = "orchestrator-working") {
                Row(
                    Modifier.padding(horizontal = 16.dp, vertical = 6.dp).tag("orchestrator-working"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text("Working…", color = c.onSurfaceVariant)
                }
            }
        }
        items(chat.asReversed(), key = { it.id }) { i ->
            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).animateItem()) {
                if (i.kind == ItemKind.user) UserBubble(i) else MarkdownText(i.text)
            }
        }
    }
}

/** A prompt the person sent: on the right, in a tonal bubble, with how many images went along. */
@Composable
private fun BoxScope.UserBubble(i: LiveItem) {
    val c = MaterialTheme.colorScheme
    Surface(
        color = c.secondaryContainer,
        contentColor = c.onSecondaryContainer,
        shape = RoundedCornerShape(18.dp, 18.dp, 4.dp, 18.dp),
        modifier = Modifier.align(Alignment.CenterEnd).padding(start = 48.dp).widthIn(max = 560.dp),
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            Text(i.text, style = MaterialTheme.typography.bodyLarge)
            if (i.images > 0) {
                Text(
                    if (i.images == 1) "⊕ 1 image" else "⊕ ${i.images} images",
                    style = MaterialTheme.typography.labelMedium,
                    color = c.onSecondaryContainer.copy(alpha = .7f),
                )
            }
        }
    }
}

/** The composer: live words while the mic is held, what went wrong, the field, the mic and Send. */
@Composable
private fun Composer(
    field: TextFieldValue,
    onField: (TextFieldValue) -> Unit,
    focus: FocusRequester,
    listening: Boolean,
    live: String,
    level: Double,
    error: String?,
    starting: Boolean,
    computer: String?,
    sending: Boolean,
    onSend: () -> Unit,
    onHeard: (String) -> Unit,
    onListening: (Boolean, String, Double) -> Unit,
    onError: (String?) -> Unit,
) {
    val c = MaterialTheme.colorScheme
    Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
        AnimatedVisibility(listening, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
            Surface(
                color = c.surfaceContainerHigh,
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).tag("orchestrator-live"),
            ) {
                Column(Modifier.padding(12.dp)) {
                    Text(
                        live.ifEmpty { "Listening…" },
                        color = if (live.isEmpty()) c.onSurfaceVariant else c.onSurface,
                        style = MaterialTheme.typography.bodyLarge,
                    )
                    Spacer(Modifier.height(8.dp))
                    LinearProgressIndicator(
                        progress = { level.toFloat().coerceIn(0f, 1f) },
                        modifier = Modifier.fillMaxWidth(),
                        drawStopIndicator = {},
                    )
                }
            }
        }
        if (error != null) {
            Text(
                error,
                color = LocalStatus.current.needs,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).tag("orchestrator-error"),
            )
        }
        if (starting) {
            Text(
                "Starting the orchestrator on ${computer ?: "the computer"}…",
                color = c.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp).tag("orchestrator-starting"),
            )
        }
        Row(
            Modifier.padding(start = 8.dp, end = 4.dp, top = 4.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            TextField(
                value = field,
                onValueChange = onField,
                placeholder = { Text("Ask the orchestrator…") },
                minLines = 1,
                // Dictation fills the field with a whole sentence; one tap empties it.
                trailingIcon = if (field.text.isEmpty()) null else {
                    {
                        IconButton(
                            onClick = { onField(TextFieldValue("")) },
                            modifier = Modifier.tag("orchestrator-clear"),
                        ) { Icon(Icons.Rounded.Close, contentDescription = "Clear") }
                    }
                },
                maxLines = 5,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                shape = RoundedCornerShape(24.dp),
                colors = TextFieldDefaults.colors(
                    focusedIndicatorColor = Color.Transparent,
                    unfocusedIndicatorColor = Color.Transparent,
                    disabledIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.weight(1f).focusRequester(focus).tag("orchestrator-input"),
            )
            HoldToTalkMic(onText = onHeard, onListening = onListening, onError = onError)
            val canSend = field.text.isNotBlank() && !sending
            Tooltipped("Send") {
                FilledIconButton(
                    onClick = onSend,
                    enabled = canSend,
                    modifier = Modifier.padding(bottom = 4.dp).size(48.dp).tag("orchestrator-send"),
                ) {
                    if (sending) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Rounded.ArrowUpward, contentDescription = "Send")
                    }
                }
            }
        }
    }
}
