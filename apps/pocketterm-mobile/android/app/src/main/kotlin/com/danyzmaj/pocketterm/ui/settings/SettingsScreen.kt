package com.danyzmaj.pocketterm.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.NotificationsOff
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.BuildConfig
import com.danyzmaj.pocketterm.core.ThemeChoice
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalHome
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.Avatar
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.openExternal
import com.danyzmaj.pocketterm.ui.common.pushBlocked
import com.danyzmaj.pocketterm.ui.common.pushNotSent
import com.danyzmaj.pocketterm.ui.common.repoUrl
import com.danyzmaj.pocketterm.ui.common.showPushNotAllowed
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.home.ComputerRows
import com.danyzmaj.pocketterm.ui.home.SheetTitle
import com.danyzmaj.pocketterm.ui.home.scanComputer
import com.danyzmaj.pocketterm.ui.home.sheetItemColors
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import com.danyzmaj.pocketterm.ui.theme.argb
import com.danyzmaj.pocketterm.ui.voice.VoiceLanguagePicker
import kotlinx.coroutines.launch

/**
 * Settings (the Flutter app's account sheet), a page of its own: who this phone is signed in as,
 * the account's computers, notifications, the theme and voice language, leaving the server, the
 * tips again and where the source is. The demo has none (Exit demo instead).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen() {
    val graph = LocalGraph.current
    val nav = LocalNav.current
    val home = LocalHome.current
    val toaster = LocalToaster.current
    val session = graph.session.observe()
    // Read here, not in the list's items: an item's content captures only what it's given, and the same
    // VoiceLanguage object doesn't make it compose again when its choice changes.
    val voiceLabel = graph.voiceLanguage.observe().choice?.label ?: "Auto"
    val theme by graph.appearance.choice.collectAsState()
    var pickingTheme by remember { mutableStateOf(false) }
    var pickingVoice by remember { mutableStateOf(false) }
    var leaving by remember { mutableStateOf(false) }

    // Signed out meanwhile (here or by the computer), or the demo: nothing to show.
    if (session.user == null || home == null || home.demo) {
        LaunchedEffect(Unit) { nav.popToRoot() }
        return
    }

    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior(rememberTopAppBarState())
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text("Settings") },
                navigationIcon = {
                    IconButton(onClick = nav::back, modifier = Modifier.tag("settings-back")) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back")
                    }
                },
                scrollBehavior = scroll,
            )
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().tag("settings"),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 24.dp,
            ),
        ) {
            item(key = "who") {
                ListItem(
                    leadingContent = { Avatar(session.userName, size = 40.dp) },
                    headlineContent = { Text(session.userName, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium) },
                    supportingContent = { Text("Signed in with your computer’s code") },
                )
            }
            item(key = "computers") { Column {
                Section("Computers")
                ComputerRows(
                    home.desktops,
                    session,
                    home.desktopsError,
                    // Back to the list, showing that computer's sessions.
                    onPick = {
                        home.desktops.select(it.id)
                        nav.popToRoot()
                    },
                    // The app's scope: the scanner's page comes over this one.
                    onScan = { graph.scope.launch { scanComputer(nav, session, home, toaster) } },
                )
            } }
            item(key = "notifications") { Column {
                Section("Notifications")
                PushSetting()
            } }
            item(key = "appearance") { Column {
                Section("Appearance")
                ListItem(
                    // Rows read as one line, "title\nvalue", as the iPhone's.
                    modifier = Modifier.clickable { pickingTheme = true }.tag("theme", "Theme\n${theme.label}"),
                    leadingContent = { ThemeSwatch(theme) },
                    headlineContent = { Text("Theme") },
                    supportingContent = { Text(theme.label) },
                    trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
                )
                ListItem(
                    modifier = Modifier.clickable { pickingVoice = true }
                        .tag("voice-language-setting", "Voice prompt language\n$voiceLabel"),
                    leadingContent = { Icon(Icons.Rounded.Translate, null) },
                    headlineContent = { Text("Voice prompt language") },
                    supportingContent = { Text(voiceLabel) },
                    trailingContent = { Icon(Icons.Rounded.ChevronRight, null) },
                )
            } }
            item(key = "more") { Column {
                HorizontalDivider(Modifier.padding(vertical = 8.dp))
                ListItem(
                    modifier = Modifier.tag("show-tips").clickable {
                        session.tips.reset()
                        // Back on the list, where the first tips are.
                        nav.popToRoot()
                    },
                    leadingContent = { Icon(Icons.Outlined.Lightbulb, null) },
                    headlineContent = { Text("Show tips again") },
                )
                ListItem(
                    modifier = Modifier.tag("source-code").clickable { openExternal(repoUrl) },
                    leadingContent = { Icon(Icons.Outlined.Code, null) },
                    headlineContent = { Text("PocketTerm is open source: GitHub") },
                )
                ListItem(
                    modifier = Modifier.tag("leave-server").clickable { leaving = true },
                    leadingContent = { Icon(Icons.AutoMirrored.Rounded.Logout, null, tint = MaterialTheme.colorScheme.error) },
                    headlineContent = { Text("Leave this server", color = MaterialTheme.colorScheme.error) },
                )
                ListItem(
                    modifier = Modifier.tag("app-version"),
                    leadingContent = { Icon(Icons.Outlined.Info, null) },
                    headlineContent = { Text("Version") },
                    supportingContent = { Text("PocketTerm ${BuildConfig.VERSION_NAME}") },
                )
            } }
        }
    }

    if (pickingTheme) ThemeSheet(onDismiss = { pickingTheme = false })
    if (pickingVoice) {
        ModalBottomSheet(onDismissRequest = { pickingVoice = false }) {
            SheetTitle("Voice prompt language")
            VoiceLanguagePicker()
            Spacer(Modifier.height(16.dp))
        }
    }
    if (leaving) {
        AlertDialog(
            onDismissRequest = { leaving = false },
            modifier = Modifier.tag("leave-dialog"),
            title = { Text("Leave this server?") },
            text = {
                Text(
                    "This phone signs out of ${session.userName} and forgets its computers’ keys. To come back, scan a " +
                        "computer’s code again.",
                )
            },
            dismissButton = { TextButton(onClick = { leaving = false }, Modifier.tag("leave-cancel")) { Text("Cancel") } },
            confirmButton = {
                TextButton(
                    onClick = {
                        leaving = false
                        graph.scope.launch { session.signOut() }
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                    modifier = Modifier.tag("leave-confirm"),
                ) { Text("Leave") }
            },
        )
    }
}

/** A group's title, in the accent. */
@Composable
private fun Section(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { heading() }
            .padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 4.dp),
    )
}

/**
 * Notifications on or off for this phone on this server, and how they stand: registering, blocked in
 * the phone's Settings (with a way there), not sent to the server yet, on, off. Turned on but not
 * allowed, a message says why.
 */
@Composable
private fun PushSetting() {
    val graph = LocalGraph.current
    val home = LocalHome.current
    val toaster = LocalToaster.current
    val session = graph.session.observe()
    val status = LocalStatus.current
    val on = session.pushEnabled ?: false
    // On here, off in the phone's Settings (changed there after saying yes): nothing shows.
    val blocked = on && session.notificationsAllowed == false
    val registering = on && !blocked && session.pushRegistering
    val unsent = on && !blocked && !registering && session.pushUnsent
    fun set(value: Boolean) {
        graph.scope.launch {
            if (!session.setPushEnabled(value) && value) {
                toaster.showPushNotAllowed(session.notificationsAllowed, graph.native, graph.scope)
            }
            // Following sessions needs push: Follow comes or goes with it.
            home?.syncFollow()
        }
    }
    ListItem(
        modifier = Modifier.tag("push-toggle").clickable(role = Role.Switch) { set(!on) },
        leadingContent = { Icon(if (on) Icons.Outlined.Notifications else Icons.Outlined.NotificationsOff, null) },
        headlineContent = { Text("Notifications") },
        supportingContent = {
            if (registering) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.tag("push-registering")) {
                    CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp)
                    Spacer(Modifier.size(8.dp))
                    Text("Registering this phone with your server…")
                }
            } else {
                Text(
                    when {
                        blocked -> pushBlocked
                        unsent -> pushNotSent
                        on -> "Encrypted, through the push relay at push.danyzmaj.com."
                        else -> "Off: no notifications and no followed sessions."
                    },
                    color = if (blocked || unsent) status.needs else Color.Unspecified,
                )
            }
        },
        trailingContent = { Switch(checked = on, onCheckedChange = null) },
    )
    if (blocked) {
        TextButton(
            onClick = { graph.scope.launch { graph.native.openSettings(notifications = true) } },
            modifier = Modifier.padding(start = 56.dp).tag("push-settings"),
        ) { Text("Open Settings") }
    }
}

/**
 * The themes, each with its swatch; a tap shows one at once and keeps it for this phone, and the
 * sheet stays to try another. The launcher icon follows the theme.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ThemeSheet(onDismiss: () -> Unit) {
    val appearance = LocalGraph.current.appearance
    val choice by appearance.choice.collectAsState()
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        SheetTitle("Theme", "Colours terminal screens and code. The app icon follows it.")
        LazyColumn {
            items(ThemeChoice.entries, key = { it.name }) { c ->
                ListItem(
                    modifier = Modifier.tag("theme-${c.name}").clickable { appearance.choose(c) },
                    colors = sheetItemColors(),
                    leadingContent = { ThemeSwatch(c) },
                    headlineContent = { Text(c.label) },
                    trailingContent = if (choice == c) {
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

/**
 * A theme in miniature: its light half beside its dark half, each its background, the accent's
 * bar (Material's own for System) and the ok/warn/error dots.
 */
@Composable
fun ThemeSwatch(choice: ThemeChoice, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(6.dp)
    Row(
        modifier
            .size(72.dp, 30.dp)
            .clip(shape)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant, shape),
    ) {
        for (t in listOf(choice.light, choice.dark)) {
            val accent = if (t.platformAccent) MaterialTheme.colorScheme.primary else argb(t.accent)
            Column(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .background(argb(t.win))
                    .padding(horizontal = 5.dp, vertical = 6.dp),
                verticalArrangement = Arrangement.SpaceBetween,
            ) {
                Box(Modifier.fillMaxWidth().height(5.dp).background(accent, RoundedCornerShape(2.dp)))
                Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    for (c in listOf(t.ok, t.warn, t.error)) Box(Modifier.size(6.dp).background(argb(c), CircleShape))
                }
            }
        }
    }
}
