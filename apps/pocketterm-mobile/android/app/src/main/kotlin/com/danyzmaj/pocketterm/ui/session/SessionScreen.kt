package com.danyzmaj.pocketterm.ui.session

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.outlined.NotificationsNone
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.danyzmaj.pocketterm.core.Agent
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.TermCap
import com.danyzmaj.pocketterm.state.HomeController
import com.danyzmaj.pocketterm.state.Tip
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.SessionRoute
import com.danyzmaj.pocketterm.ui.common.CloseConfirm
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.ago
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.home.LinkNoteBar
import com.danyzmaj.pocketterm.ui.queue.sessionTitle
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import com.danyzmaj.pocketterm.ui.tips.TipAnchor
import kotlinx.coroutines.delay

/** How long a just-launched agent may take to report before the page says so. */
private const val START_WAIT_MS = 20_000L

/**
 * One coding session, live: its transcript laid out for the phone, what its agent asks, and a composer
 * that prompts it. Shown while the home screen's computer is the one it opened on.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionScreen(route: SessionRoute, home: HomeController) {
    val nav = LocalNav.current
    val graph = LocalGraph.current
    home.observe()
    // The page belongs to the computer it opened on: another one selected meanwhile takes it away.
    val remote = remember { home.remote }
    if (remote == null || home.remote !== remote) {
        LaunchedEffect(Unit) { nav.popToRoot() }
        return
    }
    remote.observe()
    val activities = remote.activities?.observe()
    val key = route.key
    val scope = rememberCoroutineScope()
    val toaster = rememberPageToaster()
    val haptics = rememberHaptics()
    val model = remember(remote, key) {
        SessionModel(remote, key, route.starting, route.offerContinue, route.autoContinue, scope, graph.session.drafts)
    }
    model.toaster = toaster
    model.nav = nav
    model.haptics = haptics
    val sources = rememberAttachSources(model.attachments)
    DisposableEffect(model) {
        val unwatch = remote.watchSession(key)
        model.startAutoContinue()
        onDispose {
            unwatch()
            model.dispose()
        }
    }
    // The draft is kept a moment after typing pauses, and when the app goes to the background.
    LaunchedEffect(model.field.text) {
        delay(300)
        model.saveDraft()
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, model) {
        val observer = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_PAUSE) model.saveDraft() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    var late by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        delay(START_WAIT_MS)
        late = true
    }

    val s = remote.session(key)
    if (s != null) model.seen = true
    val v = remote.view(key)
    val online = remote.online
    val ended = online && !remote.fromCache && s == null && (model.seen || !route.starting)
    val windowKey = model.windowKey(s)
    val window = windowKey?.let { remote.window(it) }
    val agent = model.agent(s)
    val title = if (s == null) window?.title?.ifEmpty { null } ?: agent.label else sessionTitle(s)
    val readable = model.can(windowKey, TermCap.read)
    val screen: () -> Unit = { windowKey?.let { nav.openTerminal(it) } }

    // A transcript that started over shows from its newest.
    LaunchedEffect(v?.epoch) { if (v != null) model.list.scrollToItem(0) }

    CompositionLocalProvider(LocalToaster provides toaster) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = { nav.back() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                    },
                    title = {
                        Column {
                            Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium)
                            StatusLine(s, agent)
                        }
                    },
                    actions = {
                        if (activities != null && s != null) {
                            val following = activities.following(key)
                            TipAnchor(Tip.follow) {
                                IconButton(onClick = { model.toggleFollow(activities, s) }, modifier = Modifier.tag("follow-lock-screen")) {
                                    Icon(
                                        if (following) Icons.Filled.NotificationsActive else Icons.Outlined.NotificationsNone,
                                        contentDescription = if (following) "Stop following in notifications" else "Follow in notifications",
                                        tint = if (following) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                    )
                                }
                            }
                        }
                        if (readable) {
                            TipAnchor(Tip.openScreen) {
                                IconButton(onClick = screen, modifier = Modifier.tag("open-screen")) {
                                    Icon(Icons.Filled.Terminal, contentDescription = "Screen")
                                }
                            }
                        }
                        if (window != null && online && window.can(TermCap.close)) {
                            IconButton(onClick = { model.closing = true }, modifier = Modifier.tag("close-window")) {
                                Icon(Icons.Filled.Close, contentDescription = "Close window")
                            }
                        }
                    },
                )
            },
            bottomBar = {
                BottomPanel(model, s, title, ended = ended, online = online && (s != null || !route.starting), readable = readable, screen = screen, sources = sources)
            },
            snackbarHost = { SnackbarHost(toaster.host) },
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
                LinkNoteBar(remote)
                Transcript(model, s, ended = ended, late = late, screen = screen, modifier = Modifier.weight(1f))
            }
        }
    }

    if (model.closing && window != null && online && !ended) {
        CloseConfirm(
            remote,
            window.key,
            session = s?.key,
            onDismiss = { model.closing = false },
            onClosed = {
                model.closing = false
                nav.back()
            },
        )
    }
}

/** "Needs you" / "Working…" / "Idle · 5 min ago", then the profile, model and context, as one line. */
@Composable
private fun StatusLine(s: LiveSummary?, agent: Agent) {
    val status = LocalStatus.current
    val text = buildAnnotatedString {
        if (s == null) {
            append(agent.label)
        } else {
            when {
                s.ask != null -> withStyle(SpanStyle(color = status.needs)) { append("Needs you") }
                s.busy -> withStyle(SpanStyle(color = status.working)) { append("Working…") }
                else -> append("Idle${s.at?.let { " · ${ago(it)}" } ?: ""}")
            }
            if (s.profile.isNotEmpty()) append(" · ${s.profile}")
            if (s.model.isNotEmpty()) append(" · ${s.model}")
            s.ctx?.let { append(" · $it%") }
        }
    }
    Text(text, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** The transcript, or what the page says while there's none. */
@Composable
private fun Transcript(model: SessionModel, s: LiveSummary?, ended: Boolean, late: Boolean, screen: () -> Unit, modifier: Modifier) {
    val remote = model.remote
    val v = remote.view(model.key)
    model.outgoingTick
    model.settleOutgoing(v, s)
    val outgoing = model.outgoing.toList()
    val rows = v?.items?.map { it.row() } ?: emptyList()
    if (rows.isEmpty() && outgoing.isEmpty()) {
        val agent = model.agent(s).label
        val starting = model.starting && !model.seen
        val text = when {
            starting && late ->
                "$agent hasn't reported yet. It may be asking something on its screen first (like whether to trust this folder): " +
                    "open the screen to answer."
            starting -> "Starting $agent…"
            ended -> "This session has ended."
            v != null -> "Nothing yet. Prompt $agent below."
            remote.online -> "Loading…"
            else -> "Not on this phone yet."
        }
        val window = if (starting && model.can(model.windowKey(s), TermCap.read)) model.windowKey(s) else null
        Column(modifier) {
            TranscriptEmpty(text, if (window != null && remote.online) screen else null)
        }
        return
    }
    TranscriptList(
        list = model.list,
        rows = rows,
        outgoing = outgoing,
        working = s != null && s.busy && s.ask == null,
        earlier = v?.older ?: false,
        loadingOlder = model.loadingOlder,
        online = remote.online,
        expanded = model.expanded,
        onToggle = { id -> if (model.expanded[id] == true) model.expanded.remove(id) else model.expanded[id] = true },
        onOlder = { model.older() },
        onRetry = { model.retry(it) },
        modifier = modifier,
    )
}

/**
 * What's under the transcript: the session's end, or what its agent asks and the composer. With little
 * room (keyboard up on a small phone, landscape, large text) it takes at most four fifths of the screen
 * and scrolls, the composer last, instead of running off the screen.
 */
@Composable
private fun BottomPanel(
    model: SessionModel,
    s: LiveSummary?,
    title: String,
    ended: Boolean,
    online: Boolean,
    readable: Boolean,
    screen: () -> Unit,
    sources: AttachSources,
) {
    val density = LocalDensity.current
    val window = with(density) { LocalWindowInfo.current.containerSize.height.toDp() }
    val ime = with(density) { WindowInsets.ime.getBottom(this).toDp() }
    val room: Dp = (window - ime).coerceAtLeast(0.dp)
    val ask = s?.ask
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(
            Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime))
                .heightIn(max = room * .8f)
                .verticalScroll(rememberScrollState(), reverseScrolling = true),
        ) {
            HorizontalDivider()
            if (ended) {
                Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 6.dp, end = 8.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "This session has ended.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f).padding(vertical = 6.dp),
                    )
                    if (readable) TextButton(onClick = screen, modifier = Modifier.tag("ended-screen")) { Text("Screen") }
                }
                return@Column
            }
            AnimatedContent(
                ask,
                contentKey = { it?.id },
                transitionSpec = { (expandVertically() + fadeIn()) togetherWith (shrinkVertically() + fadeOut()) },
                label = "ask",
            ) { a ->
                when {
                    a == null -> {}
                    a.isMenu -> MenuCard(
                        model.remote,
                        model.key,
                        window = model.windowKey(s).takeIf { model.can(it, TermCap.keys) },
                        ask = a,
                        onScreen = if (readable) screen else null,
                        maxHeight = room * .55f,
                    )
                    else -> AskCard(model.remote, model.key, a, onScreen = if (readable) screen else null, maxHeight = room * .45f)
                }
            }
            Composer(model, s, title, online = online, sources = sources)
        }
    }
}
