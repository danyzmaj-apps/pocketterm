package com.danyzmaj.pocketterm.ui.home

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.PauseCircle
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.Agent
import com.danyzmaj.pocketterm.core.AgentIntegration
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.TermStatus
import com.danyzmaj.pocketterm.core.TermWindow
import com.danyzmaj.pocketterm.core.TerminalException
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.state.ProjectSort
import com.danyzmaj.pocketterm.ui.common.ago
import com.danyzmaj.pocketterm.ui.common.linkNote
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import java.util.Locale

// The words and small pieces the list's rows are made of; the session and terminal pages use some too.

/** What went wrong, as the phone says it: a computer's refusal in its own words. */
fun termError(e: Throwable): String = if (e is TerminalException) e.message else e.message ?: e.toString()

/** `/Users/me/Dev/x` as `~/Dev/x` (`C:\Users\me\x` as `~\x`). */
fun shortPath(r: TerminalRemote, path: String): String =
    if (r.home.isNotEmpty() && path.startsWith(r.home)) "~${path.substring(r.home.length)}" else path

/** A folder's last part: the project. A Windows computer's paths take `\`. */
fun baseName(path: String): String = path.split('/', '\\').lastOrNull { it.isNotEmpty() } ?: path

private val drive = Regex("""^[A-Za-z]:[\\/]""")

/**
 * A folder typed in as the computer's path: `~/x` (from [home]), `/x`, or `C:\x` on a Windows
 * computer; null for anything else (a search).
 */
fun typedPath(typed: String, home: String): String? {
    val q = typed.trim()
    if (q.startsWith("~")) {
        val rest = q.substring(1)
        return home + if (drive.containsMatchIn(home)) rest.replace('/', '\\') else rest
    }
    return if (q.startsWith("/") || drive.containsMatchIn(q)) q else null
}

/** How people name a window's terminal app ([TermWindow.app]). */
fun termLabel(app: String): String = when (app) {
    "wezterm" -> "WezTerm"
    "iterm" -> "iTerm2"
    "ghostty" -> "Ghostty"
    else -> app
}

/** Which terminal [w] is in: "WezTerm", or "tmux · Ghostty" for a tmux pane shown in Ghostty. */
fun termBadge(w: TermWindow): String = if (w.app == "tmux" && w.via.isNotEmpty()) "tmux · ${w.via}" else termLabel(w.app)

/**
 * How the phone names the project in [cwd]: its folder's name, General for the home folder (a
 * session started without picking a project), Somewhere when unknown.
 */
fun projectName(r: TerminalRemote, cwd: String): String = when {
    cwd.isEmpty() -> "Somewhere"
    cwd == r.home -> "General"
    else -> baseName(cwd)
}

// ---------------------------------------------------------------------- session words

/** "Needs you", "Working…", a stop it needs to hear about, or how long it has been idle. */
fun sessionState(s: LiveSummary): String = when {
    s.ask != null -> "Needs you"
    s.busy -> "Working…"
    s.failed -> "Stopped on an error"
    s.paused && s.queue.isNotEmpty() -> "Queue paused"
    else -> s.at?.let { ago(it) } ?: "Idle"
}

/**
 * What the agent's status bar shows of [s], each part only when known, after its omp profile when
 * that isn't the default: "personal · Opus 4.5 · 49% · $43.34".
 */
fun sessionFacts(s: LiveSummary): String = listOfNotNull(
    s.profile.ifEmpty { null },
    s.model.ifEmpty { null }?.let(::shortModel),
    s.ctx?.let { "$it%" },
    s.cost?.let(::money),
).joinToString(" · ")

private val claudePrefix = Regex("^claude[ -]", RegexOption.IGNORE_CASE)
private val releaseDate = Regex("""[-@]\d{8}$""")

/** [model] short enough for a row: no "Claude " before it, no release date after it, at most 22 characters. */
fun shortModel(model: String): String {
    val m = model.replaceFirst(claudePrefix, "").replaceFirst(releaseDate, "")
    return if (m.length > 22) "${m.substring(0, 21)}…" else m
}

/** [usd] as omp's status line writes it: "$43.34"; under a cent "<$0.01". */
fun money(usd: Double): String = if (usd < 0.01) "<$0.01" else "$" + String.format(Locale.US, "%.2f", usd)

// ---------------------------------------------------------------------- row state

/** How a session stands, as its row shows it: the icon's shape and colour. */
enum class TileState { idle, working, needsYou, failed, paused, done }

/**
 * Sessions seen working in this run of the app, and those of them that have finished since the
 * person last opened them: what a row's Done shows. Kept for the app's life, so it survives the
 * list being left and coming back.
 */
private val wasBusy = mutableSetOf<String>()
private val finished = mutableSetOf<String>()

/**
 * Notes which of [sessions] finished a run since last looked at. A run that ends while its
 * conversation is open ([watched]) was seen as it ended, so its row doesn't ask for attention after.
 */
fun noteFinished(sessions: Iterable<LiveSummary>, watched: String?) {
    for (s in sessions) {
        if (s.key == watched) {
            wasBusy.remove(s.key)
            finished.remove(s.key)
            if (s.busy) wasBusy.add(s.key)
        } else if (s.busy) {
            wasBusy.add(s.key)
            finished.remove(s.key)
        } else if (wasBusy.remove(s.key) && s.ask == null && !s.failed) {
            finished.add(s.key)
        }
    }
}

/** Session [key] was opened: its finished run has been seen. */
fun seenFinished(key: String) {
    finished.remove(key)
}

/** [s] as its row shows it. */
fun tileState(s: LiveSummary): TileState = when {
    s.ask != null -> TileState.needsYou
    s.busy -> TileState.working
    s.failed -> TileState.failed
    s.paused && s.queue.isNotEmpty() -> TileState.paused
    s.key in finished -> TileState.done
    else -> TileState.idle
}

/** [state]'s colour on the system surface; null for idle (the quiet one). */
@Composable
fun stateColor(state: TileState): Color? {
    val c = LocalStatus.current
    return when (state) {
        TileState.idle -> null
        TileState.working -> c.working
        TileState.needsYou -> c.needs
        TileState.failed -> c.failed
        TileState.paused -> c.paused
        TileState.done -> c.done
    }
}

/**
 * A session's state as an icon: the agent's sparkle (idle, and ringed by a spinner while it works),
 * a raised hand when it needs you, an error, a pause, a check once a run finished unseen. The words
 * beside it say the state, so it's decorative, except Done, which only it shows.
 */
@Composable
fun StateIcon(state: TileState, modifier: Modifier = Modifier) {
    val color by animateColorAsState(stateColor(state) ?: MaterialTheme.colorScheme.onSurfaceVariant, label = "state")
    Box(modifier.size(28.dp), contentAlignment = Alignment.Center) {
        if (state == TileState.working) {
            CircularProgressIndicator(Modifier.size(28.dp), color = color, strokeWidth = 2.dp)
        }
        val icon = when (state) {
            TileState.needsYou -> Icons.Outlined.PanTool
            TileState.failed -> Icons.Outlined.ErrorOutline
            TileState.paused -> Icons.Outlined.PauseCircle
            TileState.done -> Icons.Outlined.CheckCircle
            else -> Icons.Outlined.AutoAwesome
        }
        Icon(
            icon,
            contentDescription = if (state == TileState.done) "Finished" else null,
            tint = color,
            modifier = Modifier.size(if (state == TileState.working) 16.dp else 20.dp),
        )
    }
}

/** A thin bar filled as far as the context window is: the accent, then warn above 70%, error above 90%. */
@Composable
fun ContextBar(percent: Int, modifier: Modifier = Modifier) {
    val status = LocalStatus.current
    val target = when {
        percent > 90 -> status.failed
        percent > 70 -> status.needs
        else -> MaterialTheme.colorScheme.primary
    }
    val color by animateColorAsState(target, label = "ctx color")
    val fill by animateFloatAsState(percent.coerceIn(0, 100) / 100f, label = "ctx fill")
    LinearProgressIndicator(
        progress = { fill },
        modifier = modifier.fillMaxWidth().height(3.dp),
        color = color,
        trackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
        strokeCap = StrokeCap.Round,
        gapSize = 0.dp,
        drawStopIndicator = {},
    )
}

/** A small rounded label on a list row: a window's terminal ([termBadge]), or that it shows only as a screen. */
@Composable
fun TermBadge(text: String, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(5.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        contentColor = MaterialTheme.colorScheme.onSurfaceVariant,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 1.dp),
        )
    }
}

/** A row's line after [w]'s badge, when the window is known; [screenOnly]: an agent window no live session claims. */
@Composable
fun Badged(w: TermWindow?, screenOnly: Boolean = false, line: @Composable () -> Unit) {
    if (w == null) return line()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        // Narrow (a split screen, large text): the badges give way instead of running past the row.
        Row(Modifier.widthIn(max = 220.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            TermBadge(termBadge(w), Modifier.weight(1f, fill = false))
            if (screenOnly) TermBadge("Screen only", Modifier.weight(1f, fill = false).tag("screen-only-${w.key}"))
        }
        Box(Modifier.weight(1f)) { line() }
    }
}

// ---------------------------------------------------------------------- link

/**
 * What's wrong with the link to [remote]'s computer, if anything, as a bar for the top of a screen:
 * a spinner while it's trying, Retry when it's stuck (`link-note`, `link-retry`).
 */
@Composable
fun LinkNoteBar(remote: TerminalRemote, modifier: Modifier = Modifier) {
    // Its own observer: with the same remote passed in, Compose skips this when only the caller recomposes.
    val note = linkNote(remote.observe()) ?: return
    Surface(modifier.fillMaxWidth().tag("link-note"), color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(
            Modifier.padding(start = 16.dp, end = if (note.retry) 4.dp else 16.dp, top = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (note.busy) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                Box(Modifier.size(10.dp))
            }
            Text(
                note.text,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f).padding(vertical = 6.dp),
            )
            if (note.retry) TextButton(onClick = remote::reconnect, modifier = Modifier.tag("link-retry")) { Text("Retry") }
        }
    }
}

// ---------------------------------------------------------------------- grouping

/** The sessions in one project folder. */
data class SessionGroup(val cwd: String, val sessions: List<LiveSummary>)

/**
 * Sessions by project folder, each project's in the computer's order (as it first saw them), so a
 * session changing state never moves.
 *
 * [sort] orders the projects; by name, [home] goes by General, the name it shows under
 * ([projectName]). By activity, the projects in [ranked] keep its order, so the list doesn't
 * reshuffle while it's looked at; projects not in it yet go first, the most recently active first.
 * An empty [ranked] ranks them all afresh.
 */
fun groupedSessions(
    sessions: List<LiveSummary>,
    sort: ProjectSort,
    ranked: List<String> = emptyList(),
    home: String = "",
): List<SessionGroup> {
    val byCwd = linkedMapOf<String, MutableList<LiveSummary>>()
    for (s in sessions) byCwd.getOrPut(s.cwd) { mutableListOf() }.add(s)
    val order: List<String> = when (sort) {
        ProjectSort.byName -> {
            fun name(cwd: String) = if (cwd == home) "general" else baseName(cwd).lowercase()
            byCwd.keys.sortedWith { a, b ->
                if (a.isEmpty() != b.isEmpty()) {
                    if (a.isEmpty()) 1 else -1
                } else {
                    val r = name(a).compareTo(name(b))
                    if (r != 0) r else a.compareTo(b)
                }
            }
        }
        ProjectSort.activity -> {
            fun latest(cwd: String) = byCwd[cwd]!!.maxOf { it.at ?: 0L }
            val known = ranked.toSet()
            // A stable sort, as Dart's: equally recent projects keep the computer's order.
            byCwd.keys.filter { it !in known }.sortedByDescending(::latest) + ranked.filter { it in byCwd }
        }
    }
    return order.map { SessionGroup(it, byCwd[it]!!) }
}

// ---------------------------------------------------------------------- the computer's windows and tabs

/** A tab of an app window on the computer: the terminals in it (split panes share it); [number] counts from 1 within its window. */
data class MacTab(val id: String, val number: Int, val panes: List<TermWindow>)

/** An app window on the computer (what Cmd+N opens) and its tabs; [number] counts from 1 among [app]'s windows ("kitty window 2"). */
data class MacWindow(val id: String, val app: String, val number: Int, val tabs: List<MacTab>)

/** The app [w] shows in: the terminal app a tmux pane is shown in, else its own, as [terminals] (the computer's) name it. */
fun termApp(w: TermWindow, terminals: List<TermStatus> = emptyList()): String =
    w.via.ifEmpty { null } ?: terminals.firstOrNull { it.id == w.app }?.label ?: termLabel(w.app)

/**
 * [windows] as they sit on the computer: its app windows, each with its tabs, numbered in the order
 * they first come in [windows]. A terminal that doesn't say its app window (an older computer) is
 * left out; one that doesn't say its tab is a tab of its own.
 */
fun macLayout(windows: List<TermWindow>, terminals: List<TermStatus> = emptyList()): List<MacWindow> {
    val byWindow = linkedMapOf<String, LinkedHashMap<String, MutableList<TermWindow>>>()
    for (w in windows) {
        if (w.osWindow.isEmpty()) continue
        byWindow.getOrPut(w.osWindow) { linkedMapOf() }.getOrPut(w.tabId.ifEmpty { w.key }) { mutableListOf() }.add(w)
    }
    val perApp = mutableMapOf<String, Int>()
    return byWindow.map { (id, tabs) ->
        val app = termApp(tabs.values.first().first(), terminals)
        val number = (perApp[app] ?: 0) + 1
        perApp[app] = number
        MacWindow(id, app, number, tabs.entries.mapIndexed { i, (t, panes) -> MacTab(t, i + 1, panes) })
    }
}

/** Where each terminal of [layout] sits, by its key: "kitty window 2 · tab 1". */
fun macPlaces(layout: List<MacWindow>): Map<String, String> = buildMap {
    for (w in layout) for (t in w.tabs) for (p in t.panes) put(p.key, "${w.app} window ${w.number} · tab ${t.number}")
}

/** [layout] counted: "3 windows · 7 tabs". */
fun layoutCount(layout: List<MacWindow>): String {
    val tabs = layout.sumOf { it.tabs.size }
    return "${layout.size} window${if (layout.size == 1) "" else "s"} · $tabs tab${if (tabs == 1) "" else "s"}"
}

/** The pane a tab shows for itself: the focused one, else its first. */
fun tabLead(t: MacTab): TermWindow = t.panes.firstOrNull { it.focused } ?: t.panes.first()

/** The live session running in tab [t], if one is. */
fun tabSession(r: TerminalRemote, t: MacTab): LiveSummary? {
    val keys = t.panes.map { it.key }.toSet()
    return r.sessions.firstOrNull { it.window != null && it.window in keys }
}

/**
 * Why [agent]'s windows show only as screens, from where PocketTerm stands in it ([integration],
 * null from a computer that doesn't say) on [computer].
 */
fun screensOnly(agent: Agent, integration: AgentIntegration?, computer: String): String {
    val (name, app, command) = when (agent) {
        Agent.omp -> Triple("omp", "omp", "omp")
        Agent.claude -> Triple("Claude", "Claude Code", "claude")
    }
    // What loads it in a session that's already open: Claude Code reloads in place, omp restarts on the conversation.
    val pickUp = when (agent) {
        Agent.omp -> "restart omp there (${agent.resume} keeps the conversation)"
        Agent.claude -> "type ${agent.pickUp} in these sessions (nothing restarts)"
    }
    val part = if (agent == Agent.omp) "extension" else "plugin"
    return when (integration) {
        AgentIntegration.missing ->
            "PocketTerm isn’t installed in $app on $computer. On the computer: PocketTerm Settings → Install, then $pickUp."
        AgentIntegration.installed -> when (agent) {
            Agent.omp ->
                "These omp sessions started before PocketTerm was installed in omp. Quit omp in them and run " +
                    "${agent.resume} to see them here as conversations."
            Agent.claude ->
                "These Claude sessions started before PocketTerm was installed in Claude Code. Type ${agent.pickUp} " +
                    "in them (nothing restarts) to see them here as conversations."
        }
        AgentIntegration.outdated ->
            "PocketTerm in $app is out of date on $computer. On the computer: PocketTerm Settings → Update, then $pickUp."
        AgentIntegration.off ->
            "$app on $computer has mods turned off, so PocketTerm’s $part doesn’t run. There: run $command /login, " +
                "start $command once, then $pickUp."
        null ->
            "These $name windows show only as screens: PocketTerm’s $app $part isn’t reporting from them. It may be " +
                "out of date (update it in PocketTerm’s Settings on the computer), or $name there started before it " +
                "was installed. Then $pickUp to see it above, as a conversation."
    }
}
