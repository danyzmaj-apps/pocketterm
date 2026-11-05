package com.danyzmaj.pocketterm.ui.home

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.UnfoldLess
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.material.icons.outlined.UnfoldMoreDouble
import androidx.compose.material.icons.outlined.VerticalAlignCenter
import androidx.compose.material.icons.outlined.WebAsset
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material3.AssistChip
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.Agent
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.TermCap
import com.danyzmaj.pocketterm.core.TermState
import com.danyzmaj.pocketterm.core.TermWindow
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.state.ProjectSort
import com.danyzmaj.pocketterm.state.Tip
import com.danyzmaj.pocketterm.state.TileLook
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.CloseConfirm
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.orchestrator.OrchestratorBar
import com.danyzmaj.pocketterm.ui.terminal.KeepAwake
import com.danyzmaj.pocketterm.ui.terminal.canSwitch
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import com.danyzmaj.pocketterm.ui.theme.argb
import com.danyzmaj.pocketterm.ui.tips.TipAnchor
import com.danyzmaj.pocketterm.ui.tips.TourStep
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A row of the list (a session's or a window's) for its menu and sheets: [shown] is the computer's name for it. */
private data class RowRef(val row: String, val own: String, val window: TermWindow?, val session: String?)

/** A close asked for: [window], and its session when it has one. */
private data class CloseAsk(val window: String, val session: String?)

/** By activity: the projects' order as last shown, kept until the list is pulled to refresh or the sort changes. */
private class Ranked(var cwds: List<String> = emptyList())

/**
 * The home screen's body: the computer's coding sessions by project, in a steady order, under
 * sticky project headings (a tap folds one, a long press offers a new session there and folding),
 * then its other terminal windows. A row's long press offers Rename, Color and End session; a
 * swipe left ends it (or closes the window), asking first. The orchestrator's bar sits at the bottom.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
fun TerminalList(remote: TerminalRemote, computer: String?, modifier: Modifier = Modifier) {
    val graph = LocalGraph.current
    val session = graph.session
    val nav = LocalNav.current
    val toaster = LocalToaster.current
    val haptics = rememberHaptics()
    val desktop = remote.desktopId
    remote.observe()
    val tips = session.tips.observe()

    var folded by remember { mutableStateOf(session.collapsedProjects) }
    var sort by remember { mutableStateOf(session.projectSort) }
    var looks by remember { mutableStateOf(session.tileLooks(desktop)) }
    var filter by remember { mutableStateOf(session.profileFilter(desktop)) }
    val ranked = remember { Ranked() }
    var launching by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    var rowMenu by remember { mutableStateOf<RowRef?>(null) }
    var renaming by remember { mutableStateOf<RowRef?>(null) }
    var recoloring by remember { mutableStateOf<String?>(null) }
    var projectMenu by remember { mutableStateOf<String?>(null) }
    var profileMenu by remember { mutableStateOf(false) }
    var layoutSheet by remember { mutableStateOf(false) }
    var closeAsk by remember { mutableStateOf<CloseAsk?>(null) }

    fun setFolded(f: Set<String>) {
        folded = f
        session.setCollapsedProjects(f)
    }

    fun fold(cwd: String) = setFolded(if (cwd in folded) folded - cwd else folded + cwd)

    fun setSort(s: ProjectSort) {
        if (s == sort) return
        sort = s
        ranked.cwds = emptyList()
        session.setProjectSort(s)
    }

    fun setFilter(p: String?) {
        filter = p
        session.setProfileFilter(desktop, p)
    }

    fun look(row: String) = looks[row] ?: TileLook()

    fun setLook(row: String, look: TileLook) {
        looks = if (look.name == null && look.color == null) looks - row else looks + (row to look)
        session.setTileLooks(desktop, looks)
    }

    // The omp profile a session started here runs in: the New session sheet's last pick, while the computer still has it.
    fun newProfile(): String {
        val p = session.newSessionProfile(desktop)
        return if (remote.agent == Agent.omp && p in remote.profiles) p else ""
    }

    // Starts the agent in a new window in [cwd], opens its session and says where it opened. The app's
    // scope: the session still opens (or what went wrong still shows) if the list goes meanwhile.
    fun launchHere(cwd: String) {
        if (launching != null) return
        launching = cwd
        graph.scope.launch {
            try {
                val opened = remote.launch(cwd, startAgent = true, profile = newProfile())
                // An agent the phone started: its session's key is its window's.
                nav.openSession(opened.window, starting = true)
                if (opened.where.isNotEmpty()) toaster.show("Opened in ${opened.where}")
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                toaster.show(termError(e))
            } finally {
                launching = null
            }
        }
    }

    // The orchestrator has its own bar, not a place in the list; its window is still claimed.
    val sessions = remote.sessions.filter { !it.orchestrator }
    // The omp profiles there are: the default, the computer's, and any a session runs in.
    val known = linkedSetOf("").apply {
        addAll(remote.profiles)
        sessions.forEach { add(it.profile) }
    }
    val showFilter = known.size > 1
    // A profile no longer there reads as all of them; the kept choice stays for when it's back.
    val current = filter?.takeIf { showFilter && it in known }
    val visible = if (current == null) sessions else sessions.filter { it.profile == current }
    val groups = groupedSessions(visible, sort, ranked.cwds, remote.home)
    noteFinished(sessions, remote.watchedSession)
    // What's shown is what stays: a project's activity reorders it only on the next refresh.
    if (sort == ProjectSort.activity) ranked.cwds = groups.map { it.cwd }
    val claimed = remote.sessions.mapNotNull { it.window }.toSet()
    val layout = macLayout(remote.windows, remote.terminals)
    val places = macPlaces(layout)
    val windows = remote.windows.filter { it.key !in claimed }
    // Agent windows the phone can switch to the conversation view; the others say why they show as screens.
    val switchable = windows.filter { canSwitch(remote, it) }
    val switchTipRow = switchable.firstOrNull()?.key
    fun closes(window: String?) = window != null && remote.window(window)?.can(TermCap.close) == true
    // The first row a swipe can end, for the swipe tip.
    val swipeTipRow = (
        groups.filter { it.cwd !in folded }.flatMap { g -> g.sessions.filter { closes(it.window) }.map { it.key } } +
            windows.filter { closes(it.key) }.map { it.key }
        ).firstOrNull()

    fun closeLabel(w: TermWindow?): String? =
        if (w != null && w.can(TermCap.close) && remote.online) (if (w.agent != null) "End session" else "Close window") else null

    val bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()

    // The screen stays on while the list (and the pages over it) is up: a terminal is something you watch.
    KeepAwake()
    // The switch tour's rows may be scrolled out of view: the later tips wait for them.
    TourStep(Tip.switchOpen, active = switchTipRow != null)
    TourStep(Tip.switchDone, active = tips.switchedWindow?.let { w -> sessions.any { it.window == w } } == true)
    Box(modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.animateContentSize()) { LinkNoteBar(remote) }
            PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = {
                    refreshing = true
                    ranked.cwds = emptyList()
                    remote.hello()
                    scope.launch {
                        delay(600)
                        refreshing = false
                    }
                },
                modifier = Modifier.weight(1f),
            ) {
                LazyColumn(
                    Modifier.fillMaxSize().tag("terminal-list"),
                    // Rows scroll on under the navigation bar; the last one still comes up clear of the + and the orchestrator.
                    contentPadding = PaddingValues(bottom = 96.dp + bottom),
                ) {
                    if (sessions.isEmpty() && windows.isEmpty()) item(key = "empty") { EmptyHint(remote) }
                    if (layout.isNotEmpty() || groups.size > 1 || showFilter) {
                        item(key = "controls") {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (layout.isNotEmpty()) {
                                    AssistChip(
                                        onClick = { layoutSheet = true },
                                        label = { Text(layoutCount(layout), maxLines = 1) },
                                        leadingIcon = { Icon(Icons.Outlined.WebAsset, null, Modifier.size(18.dp)) },
                                        modifier = Modifier.tag("layout-summary"),
                                    )
                                }
                                Spacer(Modifier.weight(1f))
                                if (showFilter) {
                                    AssistChip(
                                        onClick = { profileMenu = true },
                                        label = { ChipLabel(profileLabel(current)) },
                                        leadingIcon = { Icon(Icons.Outlined.FilterList, null, Modifier.size(18.dp)) },
                                        trailingIcon = { Icon(Icons.Rounded.ArrowDropDown, null, Modifier.size(18.dp)) },
                                        modifier = Modifier.tag("profile-filter"),
                                    )
                                }
                                // A tap switches to the other order (there are only two), no menu.
                                if (groups.size > 1) {
                                    AssistChip(
                                        onClick = { setSort(if (sort == ProjectSort.byName) ProjectSort.activity else ProjectSort.byName) },
                                        label = { ChipLabel(sort.label) },
                                        leadingIcon = { Icon(Icons.Outlined.SwapVert, null, Modifier.size(18.dp)) },
                                        modifier = Modifier.tag("project-sort"),
                                    )
                                }
                            }
                        }
                    }
                    if (current != null && groups.isEmpty() && sessions.isNotEmpty()) {
                        item(key = "profile-filter-empty") {
                            Column(
                                Modifier.fillMaxWidth().padding(horizontal = 40.dp, vertical = 24.dp).tag("profile-filter-empty"),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Text(
                                    "No sessions from ${profileLabel(current)} here.",
                                    textAlign = TextAlign.Center,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                TextButton(onClick = { setFilter(null) }, Modifier.tag("profile-filter-show-all")) { Text("Show all") }
                            }
                        }
                    }
                    groups.forEachIndexed { i, g ->
                        val isFolded = g.cwd in folded
                        stickyHeader(key = "project-${g.cwd}") {
                            Tipped(if (i == 0) Tip.projectHeading else null) {
                                ProjectHeader(
                                    cwd = g.cwd,
                                    name = projectName(remote, g.cwd),
                                    folded = isFolded,
                                    launching = launching == g.cwd,
                                    onTap = { fold(g.cwd) },
                                    onLongPress = {
                                        haptics.longPress()
                                        projectMenu = g.cwd
                                    },
                                )
                            }
                        }
                        if (isFolded) {
                            item(key = "summary-${g.cwd}") {
                                ProjectSummary(g.sessions, Modifier.animateItem().tag("project-summary-${g.cwd}")) { fold(g.cwd) }
                            }
                        } else {
                            items(g.sessions, key = { "s-${it.key}" }) { s ->
                                val w = s.window?.let(remote::window)
                                val own = s.title.ifEmpty { s.agent.label }
                                val tip = when {
                                    s.window != null && s.window == tips.switchedWindow -> Tip.switchDone
                                    s.key == swipeTipRow -> Tip.swipeRow
                                    else -> null
                                }
                                Box(Modifier.animateItem()) {
                                    SwipeRow(s.key, closeLabel(w), onClose = { closeAsk = CloseAsk(w!!.key, s.key) }) {
                                        Tipped(tip) {
                                            SessionRow(
                                                s = s,
                                                w = w,
                                                look = look(s.key),
                                                own = own,
                                                onTap = {
                                                    seenFinished(s.key)
                                                    nav.openSession(s.key)
                                                },
                                                onLongPress = {
                                                    haptics.longPress()
                                                    rowMenu = RowRef(s.key, own, w, s.key)
                                                },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (windows.isNotEmpty()) {
                        stickyHeader(key = "windows-heading") {
                            SectionHeader(if (sessions.isEmpty()) "WINDOWS" else "OTHER WINDOWS", Modifier.tag("windows-heading"))
                        }
                        if (switchable.isNotEmpty()) {
                            item(key = "switch-tip") {
                                Hint(
                                    if (switchable.size == 1) {
                                        "1 session shows only its screen. Tap it to switch it to the conversation view."
                                    } else {
                                        "${switchable.size} sessions show only their screen. Tap one to switch it to the conversation view."
                                    },
                                    Modifier.tag("switch-tip"),
                                )
                            }
                        }
                        // An agent whose PocketTerm integration doesn't report: out of date, or installed after it
                        // started in a window the phone can't switch.
                        for (agent in Agent.entries) {
                            if (windows.any { it.agent == agent && !canSwitch(remote, it) }) {
                                item(key = "${agent.command}-screens-only") {
                                    Hint(
                                        screensOnly(agent, remote.agents[agent], computer ?: "the computer"),
                                        Modifier.tag("${agent.command}-screens-only"),
                                    )
                                }
                            }
                        }
                        items(windows, key = { "w-${it.key}" }) { w ->
                            val own = w.title.ifEmpty { w.program }
                            val tip = when (w.key) {
                                switchTipRow -> Tip.switchOpen
                                swipeTipRow -> Tip.swipeRow
                                else -> null
                            }
                            Box(Modifier.animateItem()) {
                                SwipeRow(w.key, closeLabel(w), onClose = { closeAsk = CloseAsk(w.key, null) }) {
                                    Tipped(tip) {
                                        WindowRow(
                                            remote = remote,
                                            w = w,
                                            look = look(w.key),
                                            own = own,
                                            onTap = { nav.openTerminal(w.key) },
                                            onLongPress = {
                                                haptics.longPress()
                                                rowMenu = RowRef(w.key, own, w, null)
                                            },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Beside the + (56 tall, 16 in from the edges).
        OrchestratorBar(
            remote,
            Modifier
                .align(Alignment.BottomStart)
                .navigationBarsPadding()
                .padding(start = 16.dp, end = 16.dp + 56.dp + 16.dp, bottom = 16.dp),
        )
    }

    rowMenu?.let { r ->
        val w = r.window
        RowMenuSheet(
            place = w?.let { places[it.key] },
            color = look(r.row).color,
            close = closeLabel(w),
            onRename = { renaming = r },
            onColor = { recoloring = r.row },
            onClose = { closeAsk = CloseAsk(w!!.key, r.session) },
            onDismiss = { rowMenu = null },
        )
    }
    renaming?.let { r ->
        val l = look(r.row)
        RenameSheet(
            initial = l.name ?: r.own,
            canReset = l.name != null,
            // The computer's own name, or nothing: back to it.
            onName = { name -> setLook(r.row, l.withName(if (name.trim() == r.own) null else name)) },
            onDismiss = { renaming = null },
        )
    }
    recoloring?.let { row ->
        ColorSheet(look(row).color, onColor = { c -> setLook(row, look(row).withColor(c)) }, onDismiss = { recoloring = null })
    }
    projectMenu?.let { cwd ->
        ProjectMenuSheet(
            remote = remote,
            cwd = cwd,
            newLabel = "New ${remote.agent.labelIn(newProfile())} session here",
            newEnabled = remote.online && launching == null,
            folded = cwd in folded,
            others = groups.size > 1,
            anyFolded = folded.isNotEmpty(),
            onNew = { launchHere(cwd) },
            onFold = { fold(cwd) },
            onFoldOthers = { setFolded(folded + remote.sessions.map { it.cwd } - cwd) },
            onUnfoldAll = { setFolded(emptySet()) },
            onDismiss = { projectMenu = null },
        )
    }
    if (profileMenu) {
        ProfileFilterSheet(known.filter { it.isNotEmpty() }.sorted(), current, onPick = ::setFilter, onDismiss = { profileMenu = false })
    }
    if (layoutSheet) {
        LayoutSheet(
            remote,
            onPick = { s, window ->
                if (s != null) {
                    seenFinished(s)
                    nav.openSession(s)
                } else {
                    nav.openTerminal(window)
                }
            },
            onDismiss = { layoutSheet = false },
        )
    }
    closeAsk?.let { c ->
        CloseConfirm(remote, c.window, c.session, onDismiss = { closeAsk = null }, onClosed = { closeAsk = null })
    }
}

/** [content] with [tip] pointed at it, if it has one. */
@Composable
private fun Tipped(tip: Tip?, content: @Composable () -> Unit) {
    if (tip == null) content() else TipAnchor(tip) { content() }
}

/** A pill's label, cross-fading to a new one so the switch reads as one. */
@Composable
private fun ChipLabel(text: String) {
    AnimatedContent(text, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "chip") { Text(it, maxLines = 1) }
}

/** A small explanation between rows. */
@Composable
private fun Hint(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.fillMaxWidth().padding(start = 16.dp, end = 24.dp, bottom = 8.dp),
    )
}

/** A heading over rows: the section's name in the accent, on the page's surface so rows scroll under it. */
@Composable
private fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .semantics { heading() }
            .padding(horizontal = 16.dp, vertical = 14.dp),
    )
}

/** A project's sticky heading: a tap folds it, a long press opens its menu; it spins while a session starts there. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ProjectHeader(cwd: String, name: String, folded: Boolean, launching: Boolean, onTap: () -> Unit, onLongPress: () -> Unit) {
    val turn by animateFloatAsState(if (folded) -90f else 0f, label = "fold")
    Row(
        Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            // Read (and found by tests) as the project's name, not the capitals drawn.
            .tag("project-$cwd", label = name)
            .combinedClickable(onClickLabel = if (folded) "Unfold" else "Fold", onLongClickLabel = "Project menu", onLongClick = onLongPress, onClick = onTap)
            .semantics {
                heading()
                stateDescription = if (folded) "Folded" else "Unfolded"
            }
            .padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            name.uppercase(),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (launching) {
            CircularProgressIndicator(Modifier.padding(end = 8.dp).size(16.dp).tag("project-launching-$cwd"), strokeWidth = 2.dp)
        }
        Icon(Icons.Outlined.ExpandMore, null, Modifier.rotate(turn), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A folded project's one row: how many sessions, and what needs you or is working, so folding never hides a question. */
@Composable
private fun ProjectSummary(sessions: List<LiveSummary>, modifier: Modifier, onTap: () -> Unit) {
    val status = LocalStatus.current
    val n = sessions.size
    val asking = sessions.count { it.ask != null }
    val working = sessions.count { it.busy && it.ask == null }
    val color = when {
        asking > 0 -> status.needs
        working > 0 -> MaterialTheme.colorScheme.primary
        else -> MaterialTheme.colorScheme.outline
    }
    ListItem(
        modifier = modifier.clickable(onClick = onTap),
        leadingContent = { Icon(Icons.Outlined.AutoAwesome, null, tint = color) },
        headlineContent = {
            Text(
                buildAnnotatedString {
                    append("$n session${if (n == 1) "" else "s"}")
                    if (asking > 0) withStyle(SpanStyle(color = status.needs)) { append(" · ${if (asking == 1) "1 needs" else "$asking need"} you") }
                    if (working > 0) withStyle(SpanStyle(color = MaterialTheme.colorScheme.primary)) { append(" · $working working") }
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
    )
}

/**
 * [content], ending its session (closing its window, for no agent) when swiped left: [closeLabel]
 * says which, null when it can't (no window that closes, or offline). The row slides back and
 * [onClose] asks first.
 */
@Composable
private fun SwipeRow(key: String, closeLabel: String?, onClose: () -> Unit, content: @Composable () -> Unit) {
    val state = rememberSwipeToDismissBoxState()
    val scope = rememberCoroutineScope()
    SwipeToDismissBox(
        state = state,
        backgroundContent = { CloseBehind(key, closeLabel, state) },
        modifier = Modifier.tag("swipe-$key"),
        enableDismissFromStartToEnd = false,
        enableDismissFromEndToStart = closeLabel != null,
        onDismiss = {
            scope.launch { state.reset() }
            onClose()
        },
    ) { content() }
}

/** What a swipe uncovers: End session (Close window) on the error colour. */
@Composable
private fun CloseBehind(key: String, label: String?, state: SwipeToDismissBoxState) {
    if (label == null || state.dismissDirection != SwipeToDismissBoxValue.EndToStart) return
    Row(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.errorContainer)
            .padding(horizontal = 24.dp)
            .tag("swipe-action-$key"),
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.labelLarge)
        Spacer(Modifier.size(8.dp))
        Icon(Icons.Outlined.Close, null, tint = MaterialTheme.colorScheme.onErrorContainer)
    }
}

/**
 * A row's background: the page's surface (a swipe uncovers what's behind it only as it slides),
 * the person's colour over it when they gave one, easing to a new one; and, without a colour, a
 * flash in the warning colour once when [flash] turns on (a session starts needing you).
 */
@Composable
private fun rowBackground(look: TileLook, flash: Boolean): Modifier {
    val dark = isSystemInDarkTheme()
    val tint by animateColorAsState(
        look.color?.let { argb(it).copy(alpha = if (dark) .22f else .2f) } ?: Color.Transparent,
        label = "tint",
    )
    val pulse = remember { Animatable(0f) }
    var was by remember { mutableStateOf(flash) }
    LaunchedEffect(flash) {
        // Up quickly, down slowly: a light coming on and fading, once.
        if (flash && !was) {
            pulse.animateTo(1f, tween(180))
            pulse.animateTo(0f, tween(420))
        }
        was = flash
    }
    val needs = LocalStatus.current.needs
    return Modifier
        .background(MaterialTheme.colorScheme.surface)
        .background(tint)
        .background(needs.copy(alpha = .16f * pulse.value))
}

/**
 * A session's row: its state's icon, its name (the person's, else the session's title, else the
 * agent's), how it stands and its status-bar facts after its terminal's badge, and the context bar.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(s: LiveSummary, w: TermWindow?, look: TileLook, own: String, onTap: () -> Unit, onLongPress: () -> Unit) {
    val title = look.name ?: own
    ListItem(
        modifier = Modifier
            .then(rowBackground(look, flash = s.ask != null && look.color == null))
            // One label for the row, as the iPhone's: its name, then how it stands (TalkBack, and tests find it by both).
            .tag("session-${s.key}", label = "$title\n${listOf(sessionState(s), sessionFacts(s)).filter { it.isNotEmpty() }.joinToString(", ")}")
            .combinedClickable(onLongClickLabel = "Row menu", onLongClick = onLongPress, onClick = onTap),
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        leadingContent = { StateIcon(tileState(s)) },
        headlineContent = {
            AnimatedContent(title, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "title") {
                Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        },
        supportingContent = {
            Column {
                Badged(w) {
                    // The words cross-fade when the state changes; the facts change in place.
                    AnimatedContent(
                        s,
                        contentKey = { sessionState(it) },
                        transitionSpec = { fadeIn() togetherWith fadeOut() },
                        label = "state",
                    ) { now ->
                        val facts = sessionFacts(now)
                        Text(
                            buildAnnotatedString {
                                append(sessionState(now))
                                if (facts.isNotEmpty()) withStyle(SpanStyle(color = MaterialTheme.colorScheme.outline)) { append(" · $facts") }
                            },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                s.ctx?.let { ContextBar(it.toInt(), Modifier.padding(top = 6.dp, bottom = 2.dp).tag("ctx-${s.key}")) }
            }
        },
    )
}

/** A window no live session claims: its program, profile and folder, badged Screen only when an agent runs in it. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WindowRow(remote: TerminalRemote, w: TermWindow, look: TileLook, own: String, onTap: () -> Unit, onLongPress: () -> Unit) {
    val title = look.name ?: own
    val detail = "${if (w.profile.isEmpty()) w.program else "${w.program} · ${w.profile}"} · ${shortPath(remote, w.cwd)}"
    ListItem(
        modifier = Modifier
            .then(rowBackground(look, flash = false))
            // One label for the row, as the iPhone's: its name, then what runs where.
            .tag("term-${w.key}", label = "$title\n${listOfNotNull(if (w.agent != null) "Screen only" else null, detail).joinToString(", ")}")
            .combinedClickable(onLongClickLabel = "Row menu", onLongClick = onLongPress, onClick = onTap),
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        leadingContent = {
            Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
                Icon(
                    if (w.agent != null) Icons.Outlined.AutoAwesome else Icons.Outlined.Terminal,
                    null,
                    Modifier.size(20.dp),
                    tint = if (w.focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                )
            }
        },
        headlineContent = {
            AnimatedContent(title, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "title") {
                Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        },
        // The rows here are the windows no live session claims.
        supportingContent = {
            Badged(w, screenOnly = w.agent != null) {
                Text(
                    detail,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        },
    )
}

/** Nothing runs: where a new session opens, and what each terminal that isn't ready needs (tmux: when it isn't installed). */
@Composable
private fun EmptyHint(remote: TerminalRemote) {
    val online = remote.observe().online
    val unready = remote.terminals.filter { it.state != TermState.ready && (it.state != TermState.missing || it.id == "tmux") }
    val hint = online && remote.error == null
    if (!hint && !(online && unready.isNotEmpty())) return
    Column(Modifier.fillMaxWidth().padding(40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        if (hint) {
            Text(
                "Nothing runs in ${remote.opensIn ?: "your terminal"}. Tap + to start ${remote.agent.label}.",
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (online) {
            unready.forEachIndexed { i, t ->
                Text(
                    "${t.label}: ${t.note.ifEmpty { stateWord(t.state) }}",
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.padding(top = if (hint || i > 0) 12.dp else 0.dp).tag("terminal-${t.id}"),
                )
            }
        }
    }
}

private fun stateWord(s: TermState): String = when (s) {
    TermState.ready -> "ready"
    TermState.limited -> "limited"
    TermState.setup -> "needs setup on the computer"
    TermState.idle -> "not running"
    TermState.missing -> "not installed"
}

/** What a long press on a project's heading offers: a new session there, folding it, and folding the others. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ProjectMenuSheet(
    remote: TerminalRemote,
    cwd: String,
    newLabel: String,
    newEnabled: Boolean,
    folded: Boolean,
    others: Boolean,
    anyFolded: Boolean,
    onNew: () -> Unit,
    onFold: () -> Unit,
    onFoldOthers: () -> Unit,
    onUnfoldAll: () -> Unit,
    onDismiss: () -> Unit,
) {
    fun run(action: () -> Unit): () -> Unit = {
        onDismiss()
        action()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        SheetTitle(projectName(remote, cwd), cwd.ifEmpty { null }?.let { shortPath(remote, it) })
        // Somewhere unknown has nowhere to start one.
        if (cwd.isNotEmpty()) {
            ListItem(
                modifier = Modifier.tag("project-menu-new").clickable(enabled = newEnabled, onClick = run(onNew)),
                colors = sheetItemColors(),
                leadingContent = { Icon(Icons.Outlined.Add, null, tint = MaterialTheme.colorScheme.primary.copy(alpha = if (newEnabled) 1f else .38f)) },
                headlineContent = {
                    Text(newLabel, color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (newEnabled) 1f else .38f))
                },
            )
        }
        ListItem(
            modifier = Modifier.tag("project-menu-fold").clickable(onClick = run(onFold)),
            colors = sheetItemColors(),
            leadingContent = { Icon(if (folded) Icons.Outlined.UnfoldMore else Icons.Outlined.UnfoldLess, null) },
            headlineContent = { Text(if (folded) "Unfold" else "Fold") },
        )
        if (others) {
            ListItem(
                modifier = Modifier.tag("project-menu-fold-others").clickable(onClick = run(onFoldOthers)),
                colors = sheetItemColors(),
                leadingContent = { Icon(Icons.Outlined.VerticalAlignCenter, null) },
                headlineContent = { Text("Fold all others") },
            )
        }
        if (others && anyFolded) {
            ListItem(
                modifier = Modifier.tag("project-menu-unfold-all").clickable(onClick = run(onUnfoldAll)),
                colors = sheetItemColors(),
                leadingContent = { Icon(Icons.Outlined.UnfoldMoreDouble, null) },
                headlineContent = { Text("Unfold all") },
            )
        }
        Spacer(Modifier.height(16.dp))
    }
}
