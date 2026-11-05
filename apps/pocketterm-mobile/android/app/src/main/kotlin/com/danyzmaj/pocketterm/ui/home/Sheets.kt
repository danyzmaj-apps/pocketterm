package com.danyzmaj.pocketterm.ui.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Label
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FormatColorReset
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.Desktop
import com.danyzmaj.pocketterm.core.Desktops
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.state.MobileSession
import com.danyzmaj.pocketterm.state.tileColorNames
import com.danyzmaj.pocketterm.state.tileColors
import com.danyzmaj.pocketterm.ui.common.ago
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import com.danyzmaj.pocketterm.ui.theme.argb

// The home list's sheets: the computer picker, a row's menu, rename and colour, a project's menu,
// the profile filter and the windows-and-tabs overview.

/** A sheet's title, and the line under it when there is one. */
@Composable
fun SheetTitle(title: String, subtitle: String? = null) {
    Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 8.dp)) {
        Text(title, style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (subtitle != null) {
            Text(
                subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Why the server lists no computer. */
const val noDesktop =
    "Your computer isn't reporting to this server. Open PocketTerm on it and turn on Terminal from phone in its Settings."

/**
 * The account's computers, each with how it stands for this phone (locked until its code is
 * scanned, online, last seen), the selected one ticked; then scanning another computer's code.
 * Shared by the picker sheet and Settings.
 */
@Composable
fun ComputerRows(
    desktops: Desktops,
    session: MobileSession,
    desktopsError: String?,
    onPick: (Desktop) -> Unit,
    onScan: () -> Unit,
    colors: androidx.compose.material3.ListItemColors = ListItemDefaults.colors(),
) {
    desktops.observe()
    session.observe()
    val status = LocalStatus.current
    Column(Modifier.fillMaxWidth()) {
        if (desktops.all.isEmpty()) {
            Text(
                if (desktops.loaded) noDesktop else desktopsError ?: "Looking for your computers…",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
            )
        }
        for (d in desktops.all) {
            val locked = session.computerKey(d.id) == null
            val state = when {
                locked -> "Locked: scan its code"
                d.online -> "Online"
                else -> "Seen ${ago(d.seenAt.toEpochMilli())}"
            }
            ListItem(
                // One node reading "name\nstatus", as the iPhone's rows: the selected one says so.
                modifier = Modifier.semantics { selected = d.id == desktops.selected?.id }
                    .clickable { onPick(d) }
                    .tag("desktop-${d.id}", "${d.name}\n$state"),
                colors = colors,
                leadingContent = { Icon(if (d.windows) Icons.Rounded.DesktopWindows else Icons.Rounded.LaptopMac, null) },
                headlineContent = { Text(d.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                supportingContent = {
                    Text(
                        state,
                        color = when {
                            locked -> status.needs
                            d.online -> MaterialTheme.colorScheme.primary
                            else -> Color.Unspecified
                        },
                    )
                },
                trailingContent = if (d.id == desktops.selected?.id) {
                    { Icon(Icons.Filled.Check, "Selected", tint = MaterialTheme.colorScheme.primary) }
                } else {
                    null
                },
            )
        }
        ListItem(
            modifier = Modifier.tag("scan-computer").clickable(onClick = onScan),
            colors = colors,
            leadingContent = { Icon(Icons.Rounded.QrCodeScanner, null) },
            headlineContent = { Text("Scan a computer’s code") },
        )
    }
}

/** The account's computers, to show another one's sessions (the title's menu). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComputerPickerSheet(
    desktops: Desktops,
    session: MobileSession,
    desktopsError: String?,
    onPick: (Desktop) -> Unit,
    onScan: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        SheetTitle("Computers")
        // The title stays; many computers scroll under it.
        LazyColumn(Modifier.fillMaxWidth().tag("computers")) {
            item {
                ComputerRows(
                    desktops,
                    session,
                    desktopsError,
                    onPick = { onDismiss(); onPick(it) },
                    onScan = { onDismiss(); onScan() },
                    colors = sheetItemColors(),
                )
            }
            item { Spacer(Modifier.height(16.dp)) }
        }
    }
}

/** List items on a sheet: its own surface, not the page's. */
@Composable
fun sheetItemColors() = ListItemDefaults.colors(containerColor = Color.Transparent)

/**
 * A long press on a row: where it sits on the computer ("kitty window 2 · tab 1"), then Rename,
 * Color and End session (Close window, for no agent; only while it can close).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RowMenuSheet(
    place: String?,
    color: Long?,
    close: String?,
    onRename: () -> Unit,
    onColor: () -> Unit,
    onClose: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        if (place != null) {
            Text(
                place,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 24.dp, vertical = 4.dp).tag("row-menu-place"),
            )
        }
        ListItem(
            modifier = Modifier.tag("row-menu-rename").clickable { onDismiss(); onRename() },
            colors = sheetItemColors(),
            leadingContent = { Icon(Icons.Outlined.Edit, null) },
            headlineContent = { Text("Rename") },
        )
        ListItem(
            modifier = Modifier.tag("row-menu-color").clickable { onDismiss(); onColor() },
            colors = sheetItemColors(),
            leadingContent = { Icon(Icons.Outlined.Palette, null, tint = color?.let(::argb) ?: MaterialTheme.colorScheme.onSurfaceVariant) },
            headlineContent = { Text("Color") },
        )
        if (close != null) {
            ListItem(
                modifier = Modifier.tag("row-menu-close").clickable { onDismiss(); onClose() },
                colors = sheetItemColors(),
                leadingContent = { Icon(Icons.Outlined.Close, null, tint = MaterialTheme.colorScheme.error) },
                headlineContent = { Text(close, color = MaterialTheme.colorScheme.error) },
            )
        }
        Spacer(Modifier.height(16.dp))
    }
}

/**
 * Asks for a row's own name; empty, or Reset ([canReset]: it has one), goes back to the one the
 * computer gives it. [onName] gets what was typed, or '' for Reset.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RenameSheet(initial: String, canReset: Boolean, onName: (String) -> Unit, onDismiss: () -> Unit) {
    var edit by remember { mutableStateOf(TextFieldValue(initial, TextRange(0, initial.length))) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    fun done(name: String) {
        onDismiss()
        onName(name)
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 16.dp).imePadding()) {
            Text("Rename", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(12.dp))
            OutlinedTextField(
                edit,
                onValueChange = { edit = it },
                singleLine = true,
                leadingIcon = { Icon(Icons.AutoMirrored.Outlined.Label, null) },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { done(edit.text) }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus).tag("tile-rename-field"),
            )
            Spacer(Modifier.height(12.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                if (canReset) TextButton(onClick = { done("") }, Modifier.tag("tile-rename-reset")) { Text("Reset") }
                Button(onClick = { done(edit.text) }, Modifier.tag("tile-rename-save")) { Text("Save") }
            }
        }
    }
}

/** Asks for a row's colour ([tileColors], named for TalkBack), or none (when it has one); [onColor] gets it, null for none. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun ColorSheet(current: Long?, onColor: (Long?) -> Unit, onDismiss: () -> Unit) {
    fun pick(c: Long?) {
        onDismiss()
        onColor(c)
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 16.dp)) {
            Text("Color", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(16.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                tileColors.forEachIndexed { i, c ->
                    val picked = current == c
                    Box(
                        Modifier
                            .size(48.dp)
                            .tag("tile-color-${c.toString(16)}")
                            .semantics {
                                contentDescription = tileColorNames[i]
                                selected = picked
                            }
                            .background(argb(c), CircleShape)
                            .then(
                                if (picked) Modifier.border(3.dp, MaterialTheme.colorScheme.onSurface, CircleShape) else Modifier,
                            )
                            .clickable(role = Role.RadioButton) { pick(c) },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (picked) Icon(Icons.Filled.Check, null, tint = Color.White)
                    }
                }
            }
            if (current != null) {
                Spacer(Modifier.height(8.dp))
                TextButton(onClick = { pick(null) }, Modifier.tag("tile-color-none")) {
                    Icon(Icons.Outlined.FormatColorReset, null, Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("No color")
                }
            }
        }
    }
}

/** The profile filter's choices: every profile, the default, then [profiles]; [current] is ticked. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileFilterSheet(profiles: List<String>, current: String?, onPick: (String?) -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        SheetTitle("Show sessions from")
        LazyColumn {
            val choices = listOf("all" to null, "default" to "") + profiles.map { it to it }
            items(choices, key = { it.first }) { (key, profile) ->
                ListItem(
                    modifier = Modifier.tag("profile-filter-$key").clickable { onDismiss(); onPick(profile) },
                    colors = sheetItemColors(),
                    headlineContent = { Text(profileLabel(profile)) },
                    trailingContent = if (profile == current) {
                        { Icon(Icons.Filled.Check, "Selected", tint = MaterialTheme.colorScheme.primary) }
                    } else {
                        null
                    },
                )
            }
            item { Spacer(Modifier.height(16.dp)) }
        }
    }
}

/** How the profile filter names [profile]: null is every profile, '' the default. */
fun profileLabel(profile: String?): String = when (profile) {
    null -> "All profiles"
    "" -> "default"
    else -> profile
}

/**
 * The computer's app windows in its list's order, each headed by its app and number ("kitty window
 * 2") over the projects in it, then its tabs, one row each whatever panes are split in it. A tab
 * running a live session shows that session. [onPick]: the tab picked, its session's key if one
 * runs there, and its pane to show otherwise.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LayoutSheet(remote: TerminalRemote, onPick: (session: String?, window: String) -> Unit, onDismiss: () -> Unit) {
    remote.observe()
    val layout = macLayout(remote.windows, remote.terminals)
    ModalBottomSheet(onDismissRequest = onDismiss) {
        // Above the navigation bar: a row half scrolled in isn't left under the gesture area, where a tap goes home.
        Column(Modifier.navigationBarsPadding().tag("layout-sheet")) {
            SheetTitle("Windows and tabs", "${layoutCount(layout)} on ${remote.desktopName ?: "the computer"}")
            LazyColumn(Modifier.fillMaxWidth()) {
                for (w in layout) {
                    item(key = "w-${w.id}") {
                        val projects = w.tabs.flatMap { t -> t.panes.filter { it.cwd.isNotEmpty() }.map { projectName(remote, it.cwd) } }
                            .distinct()
                        Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = 16.dp, bottom = 4.dp).tag("layout-window-${w.id}")) {
                            Text(
                                "${w.app} window ${w.number}",
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (projects.isNotEmpty()) {
                                Text(
                                    projects.joinToString(", "),
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                    items(w.tabs, key = { "t-${w.id}-${it.id}" }) { t -> LayoutTab(remote, t, onPick, onDismiss) }
                }
                item { Spacer(Modifier.height(16.dp)) }
            }
        }
    }
}

/** One tab's row: its live session when one runs there, else its pane as the window rows show one. */
@Composable
private fun LayoutTab(remote: TerminalRemote, t: MacTab, onPick: (String?, String) -> Unit, onDismiss: () -> Unit) {
    val lead = tabLead(t)
    val s = tabSession(remote, t)
    val cwd = shortPath(remote, s?.cwd ?: lead.cwd)
    val title = if (s != null) s.title.ifEmpty { s.agent.label } else lead.tab.ifEmpty { lead.title.ifEmpty { lead.program } }
    val detail = if (s != null) sessionState(s) else lead.program
    val status = LocalStatus.current
    ListItem(
        // One label, as the iPhone's: its title, then how it stands and where (tests find it by both).
        modifier = Modifier.clickable { onDismiss(); onPick(s?.key, lead.key) }
            .tag("layout-tab-${t.id}", label = "$title\n${listOf(detail, cwd).filter { it.isNotEmpty() }.joinToString(" · ")}"),
        colors = sheetItemColors(),
        leadingContent = {
            if (s != null) {
                val c = if (s.ask != null) status.needs else if (s.busy) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
                Icon(Icons.Outlined.AutoAwesome, null, tint = c)
            } else {
                Icon(
                    if (lead.agent != null) Icons.Outlined.AutoAwesome else Icons.Outlined.Terminal,
                    null,
                    tint = if (lead.focused) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                )
            }
        },
        headlineContent = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Text(listOf(detail, cwd).filter { it.isNotEmpty() }.joinToString(" · "), maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
    )
}
