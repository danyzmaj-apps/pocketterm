package com.danyzmaj.pocketterm.ui.home

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.Agent
import com.danyzmaj.pocketterm.core.Opened
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private val spaces = Regex("""\s+""")

/**
 * Where to start a session: find a project (or type a path) and open a window there, or in General
 * (the home folder: a quick question without picking a project), or make a new project; with the
 * agent (in an omp profile, when the computer has some) or just a shell. Once the computer opened
 * it, the sheet goes and the session's page (the window's screen, for a shell) opens, saying where
 * on the computer it went. A refusal shows and the form stays. [cwd]: a folder to start the search
 * at (a project's), null for none.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun NewSessionSheet(remote: TerminalRemote, cwd: String?, onDismiss: () -> Unit) {
    val session = LocalGraph.current.session
    val nav = LocalNav.current
    val toaster = LocalToaster.current
    val scope = rememberCoroutineScope()
    remote.observe()
    val desktop = remote.desktopId

    var query by remember { mutableStateOf(cwd?.let { shortPath(remote, it) } ?: "") }
    var agent by remember { mutableStateOf(true) }
    var launching by remember { mutableStateOf<String?>(null) }
    // Making a new project: its name and the computer's root it goes in (the first while none is picked or the picked one is gone).
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var rootPath by remember { mutableStateOf<String?>(null) }
    // The omp profile picked last time; the one the agent starts in is it while the computer has it, else the default.
    var profile by remember { mutableStateOf(session.newSessionProfile(desktop)) }
    val chosen = if (remote.agent == Agent.omp && profile in remote.profiles) profile else ""

    // Opens what the computer opened: an agent's session (its key is its window's), else the window's screen.
    fun opened(o: Opened, withAgent: Boolean) {
        onDismiss()
        if (withAgent) nav.openSession(o.window, starting = true) else nav.openTerminal(o.window, starting = true)
        if (o.where.isNotEmpty()) toaster.show("Opened in ${o.where}")
    }

    fun start(at: String, open: suspend (startAgent: Boolean, profile: String) -> Opened) {
        if (launching != null) return
        launching = at
        val withAgent = agent
        scope.launch {
            try {
                opened(open(withAgent, if (withAgent) chosen else ""), withAgent)
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                launching = null
                toaster.show(termError(e))
            }
        }
    }

    fun launch(path: String) = start(path) { a, p -> remote.launch(path, startAgent = a, profile = p) }

    // Makes the project under [root] on the computer and opens a window there, as [launch].
    fun create(root: String) = start(root) { a, p -> remote.create(root, name.trim(), startAgent = a, profile = p) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(.85f).imePadding().tag("new-session-sheet")) {
            Text(
                if (creating) "New project" else "New session",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            remote.opensIn?.let { opensIn ->
                // "Opens in kitty, as a tab in the project's window", when the computer says which. At most two
                // lines: with large text the projects below still need the room.
                Text(
                    listOfNotNull("Opens in $opensIn", remote.placement?.describe).joinToString(", "),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(horizontal = 24.dp, vertical = 2.dp).tag("opens-in"),
                )
            }
            ListItem(
                modifier = Modifier.tag("start-agent").clickable(role = Role.Switch) { agent = !agent },
                colors = sheetItemColors(),
                headlineContent = { Text("Start ${remote.agent.label}") },
                supportingContent = { Text("Off: just a shell") },
                trailingContent = { Switch(checked = agent, onCheckedChange = null) },
            )
            if (agent && remote.agent == Agent.omp && remote.profiles.isNotEmpty()) {
                FlowRow(
                    Modifier.padding(horizontal = 24.dp).padding(bottom = 8.dp).tag("start-profile"),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    for (p in listOf("") + remote.profiles) {
                        FilterChip(
                            selected = chosen == p,
                            onClick = {
                                profile = p
                                session.setNewSessionProfile(desktop, p)
                            },
                            label = { Text(p.ifEmpty { "default" }) },
                            modifier = Modifier.tag("start-profile-${p.ifEmpty { "default" }}"),
                        )
                    }
                }
            }
            Column(Modifier.padding(horizontal = 24.dp)) { LinkNoteBar(remote) }
            AnimatedContent(creating, label = "form", modifier = Modifier.weight(1f)) { making ->
                if (making) {
                    CreateForm(
                        remote = remote,
                        name = name,
                        onName = { name = it },
                        root = (remote.roots ?: emptyList()).let { roots -> rootPath?.takeIf { it in roots } ?: roots.firstOrNull() },
                        onRoot = { rootPath = it },
                        busy = launching != null,
                        onBack = { creating = false },
                        onCreate = ::create,
                    )
                } else {
                    PickList(
                        remote = remote,
                        query = query,
                        onQuery = { query = it },
                        launching = launching,
                        onLaunch = ::launch,
                        onNewProject = { creating = true },
                    )
                }
            }
        }
    }
}

/** Name the project and pick the folder it goes in. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CreateForm(
    remote: TerminalRemote,
    name: String,
    onName: (String) -> Unit,
    root: String?,
    onRoot: (String) -> Unit,
    busy: Boolean,
    onBack: () -> Unit,
    onCreate: (String) -> Unit,
) {
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    val ready = remote.online && name.trim().isNotEmpty() && !busy
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp)) {
        OutlinedTextField(
            name,
            onValueChange = onName,
            singleLine = true,
            placeholder = { Text("Project name") },
            leadingIcon = { Icon(Icons.Outlined.CreateNewFolder, null) },
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None),
            modifier = Modifier.fillMaxWidth().focusRequester(focus).tag("project-name"),
        )
        Spacer(Modifier.height(12.dp))
        Text("In", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(6.dp))
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (r in remote.roots ?: emptyList()) {
                FilterChip(
                    selected = r == root,
                    onClick = { onRoot(r) },
                    label = { Text(shortPath(remote, r)) },
                    modifier = Modifier.tag("root-$r"),
                )
            }
        }
        Spacer(Modifier.height(16.dp))
        Row(Modifier.fillMaxWidth()) {
            TextButton(onClick = onBack, enabled = !busy, modifier = Modifier.tag("new-project-back")) { Text("Back") }
            Spacer(Modifier.weight(1f))
            Button(
                onClick = { root?.let(onCreate) },
                enabled = root != null && ready,
                modifier = Modifier.tag("new-project-create"),
            ) {
                if (busy) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp) else Text("Create and open")
            }
        }
    }
}

/** Find a project (or type a path) and open a window there, or in General; or start a new project. */
@Composable
private fun PickList(
    remote: TerminalRemote,
    query: String,
    onQuery: (String) -> Unit,
    launching: String?,
    onLaunch: (String) -> Unit,
    onNewProject: () -> Unit,
) {
    val words = query.lowercase().split(spaces).filter { it.isNotEmpty() }
    val open = remote.windows.map { it.cwd }.toSet()
    val home = remote.home
    // General stands for the home folder; it gives way only to a search for something else.
    val general = home.isNotEmpty() && words.all { "general ~".contains(it) }
    val places = (open.filter { it.isNotEmpty() && it != home } + remote.projects.filter { it !in open && it != home })
        .filter { p -> words.all { shortPath(remote, p).lowercase().contains(it) } }
    val typed = typedPath(query, home)?.takeIf { !(general && it == home) }
    // null: a computer that predates Project folders, and can't make a project.
    val roots = remote.roots
    val noRoots = roots != null && roots.isEmpty()
    val noRootsHint = remote.online && noRoots && places.isEmpty() && typed == null
    Column(Modifier.fillMaxWidth()) {
        OutlinedTextField(
            query,
            onValueChange = onQuery,
            singleLine = true,
            placeholder = { Text("Find a project, or type ~/path") },
            leadingIcon = { Icon(Icons.Outlined.Folder, null) },
            keyboardOptions = KeyboardOptions(
                autoCorrectEnabled = false,
                capitalization = KeyboardCapitalization.None,
                keyboardType = KeyboardType.Uri,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).tag("session-folder"),
        )
        if (noRootsHint) {
            Text(
                "No project folders yet. On your computer, open PocketTerm → Settings → Project folders and add " +
                    "the folders that hold your projects. You can still type a ~/path above.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp).tag("no-roots"),
            )
        }
        LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
            if (general) {
                item(key = "general") {
                    Place(remote, home, open = home in open, launching = launching, onLaunch = onLaunch, name = "General", tagId = "place-general")
                }
            }
            if (query.isEmpty() && roots != null) {
                item(key = "new-project") {
                    val enabled = remote.online && roots.isNotEmpty() && launching == null
                    ListItem(
                        modifier = Modifier.tag("new-project").clickable(enabled = enabled, onClick = onNewProject),
                        colors = sheetItemColors(),
                        leadingContent = { Icon(Icons.Outlined.CreateNewFolder, null, tint = dimmed(enabled)) },
                        headlineContent = { Text("New project…", color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else .38f)) },
                        // The hint above says it already.
                        supportingContent = if (noRoots && !noRootsHint) {
                            { Text("Add a project folder in PocketTerm on your computer: Settings → Project folders") }
                        } else {
                            null
                        },
                    )
                }
            }
            items(listOfNotNull(typed) + places, key = { "p-$it" }) { p ->
                Place(remote, p, open = p in open, launching = launching, onLaunch = onLaunch)
            }
        }
    }
}

@Composable
private fun dimmed(enabled: Boolean) = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else .38f)

/**
 * A project's row, as the home list names it: the folder's name ([name] instead, if given), its
 * short path under it, and a terminal for a folder a window is [open] in.
 */
@Composable
private fun Place(
    remote: TerminalRemote,
    path: String,
    open: Boolean,
    launching: String?,
    onLaunch: (String) -> Unit,
    name: String? = null,
    tagId: String = "place-$path",
) {
    val enabled = remote.online
    ListItem(
        modifier = Modifier.tag(tagId).clickable(enabled = enabled) { onLaunch(path) },
        colors = sheetItemColors(),
        leadingContent = { Icon(if (open) Icons.Outlined.Terminal else Icons.Outlined.Folder, null, tint = dimmed(enabled)) },
        headlineContent = {
            Text(
                name ?: baseName(path),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else .38f),
            )
        },
        supportingContent = { Text(shortPath(remote, path), maxLines = 1, overflow = TextOverflow.Ellipsis) },
        trailingContent = if (launching == path) {
            { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp) }
        } else {
            null
        },
    )
}
