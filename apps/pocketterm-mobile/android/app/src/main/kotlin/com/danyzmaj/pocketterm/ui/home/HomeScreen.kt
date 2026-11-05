package com.danyzmaj.pocketterm.ui.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ArrowDropDown
import androidx.compose.material.icons.rounded.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import kotlinx.coroutines.coroutineScope
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.state.HomeController
import com.danyzmaj.pocketterm.state.MobileSession
import com.danyzmaj.pocketterm.state.Tip
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.Nav
import com.danyzmaj.pocketterm.ui.common.Avatar
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.Toaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.tips.TipAnchor
import com.danyzmaj.pocketterm.ui.tips.TourDialog
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

/**
 * The home screen: the selected computer's sessions ([TerminalList]) under its name, which opens the
 * computer picker; Settings behind the avatar (Exit demo in the demo); + for a new session. Without
 * a remote it says why: the computer is locked until its code is scanned, it's being reached, there's
 * none, or the list didn't come.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(home: HomeController) {
    val graph = LocalGraph.current
    val session = graph.session.observe()
    val nav = LocalNav.current
    val toaster = LocalToaster.current
    val scope = rememberCoroutineScope()
    home.observe()
    val desktops = home.desktops.observe()
    val tips = session.tips.observe()
    val remote = home.remote
    val selected = desktops.selected

    var picking by remember { mutableStateOf(false) }
    var newSession by remember { mutableStateOf(false) }

    LaunchedEffect(home) { home.started() }

    // The app's scope: the scanner's page takes this one's place meanwhile.
    val scanComputer = { graph.scope.launch { scanComputer(nav, session, home, toaster) } }

    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior(rememberTopAppBarState())
    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = {
                    Row(
                        Modifier
                            .tag("computer-picker")
                            .clickable(onClickLabel = "Pick a computer", role = Role.Button) {
                                // The list fresh, as the picker opens.
                                if (!home.demo) scope.launch { desktops.refresh() }
                                picking = true
                            },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(selected?.name ?: "Terminal", maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        Icon(Icons.Rounded.ArrowDropDown, null)
                    }
                },
                actions = {
                    if (home.demo) {
                        TextButton(onClick = session::exitDemo, modifier = Modifier.tag("exit-demo")) { Text("Exit demo") }
                    } else {
                        IconButton(
                            onClick = {
                                // A token the server missed: tried now, so Settings shows how it stands, not how it stood.
                                graph.scope.launch { session.retryPush(force = true) }
                                nav.openSettings()
                            },
                            modifier = Modifier.tag("account").semantics { contentDescription = "Account" },
                        ) {
                            // Reads as Account, not as the avatar's letter too.
                            Avatar(session.userName, size = 30.dp)
                        }
                    }
                },
                scrollBehavior = scroll,
            )
        },
        floatingActionButton = {
            // Nothing to start a session on until a computer answers.
            if (remote != null) {
                TipAnchor(Tip.newSession) {
                    FloatingActionButton(onClick = { newSession = true }, modifier = Modifier.tag("add")) {
                        Icon(Icons.Rounded.Add, contentDescription = "New session")
                    }
                }
            }
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding())
                .consumeWindowInsets(WindowInsets.safeDrawing.only(WindowInsetsSides.Top)),
        ) {
            if (home.demo) DemoBanner()
            Box(Modifier.weight(1f)) {
                when {
                    // A new list for each computer: what it scrolled and folded is that computer's.
                    remote != null -> key(remote) { TerminalList(remote, computer = selected?.name) }
                    selected != null && session.computerKey(selected.id) == null -> Locked(selected.name) { scanComputer() }
                    else -> Waiting(
                        text = when {
                            selected != null -> "Reaching ${selected.name}…"
                            desktops.loaded -> noDesktop
                            else -> home.desktopsError ?: "Looking for your computers…"
                        },
                        // The list didn't come: asked again now, not at the next 30-second refresh.
                        retry = if (selected == null && desktops.error != null && !home.demo) home::retryDesktops else null,
                    )
                }
            }
        }
    }

    if (picking) {
        ComputerPickerSheet(
            desktops,
            session,
            home.desktopsError,
            onPick = { desktops.select(it.id) },
            onScan = { scanComputer() },
            onDismiss = { picking = false },
        )
    }
    if (newSession && remote != null) NewSessionSheet(remote, cwd = null, onDismiss = { newSession = false })
    // The first time on the list (also the demo's): whether to have the first-use tips.
    if (!tips.answered) TourDialog { tips.answer(it) }
}

/**
 * A computer's code, scanned while signed in: this phone gets that computer's key
 * ([MobileSession.connectLink]); a problem with the code shows as a notice (the home state shows
 * those). A code for another computer than the selected locked one says so.
 */
suspend fun scanComputer(nav: Nav, session: MobileSession, home: HomeController, toaster: Toaster) = coroutineScope {
    val link = nav.scan(signedIn = true) ?: return@coroutineScope
    var told = false
    // Listening before the link goes: a notice it brings is said already.
    val listening = launch(start = CoroutineStart.UNDISPATCHED) { session.notices.collect { told = true } }
    session.connectLink(link, scanned = true)
    // A notice just sent reaches the listener first.
    yield()
    listening.cancel()
    if (told) return@coroutineScope
    val selected = home.desktops.selected
    if (selected != null && session.computerKey(selected.id) == null) {
        toaster.show("That code is for another computer. Scan the one ${selected.name} shows.")
    }
}

/** Says the demo is one, under the computer's title. */
@Composable
private fun DemoBanner() {
    Card(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).tag("demo-banner"),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
    ) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                "DEMO",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.size(12.dp))
            Text(
                "Made-up sessions on a pretend computer. Nothing leaves this phone.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
        }
    }
}

/** The selected computer, while this phone has no key for it: nothing from it shows and nothing goes to it until its code is scanned. */
@Composable
private fun Locked(computer: String, onScan: () -> Unit) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.Lock, null, Modifier.size(36.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(14.dp))
        Text("Scan this computer’s code to connect", style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(
            "Its sessions are end-to-end encrypted with a key only its code holds. On $computer, open Settings → Phone → Add a phone…",
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(20.dp))
        Button(onClick = onScan, modifier = Modifier.tag("scan-locked-computer")) {
            Icon(Icons.Rounded.QrCodeScanner, null, Modifier.size(18.dp))
            Spacer(Modifier.size(8.dp))
            Text("Scan")
        }
    }
}

/** No list yet: why, and Retry when it didn't come. */
@Composable
private fun Waiting(text: String, retry: (() -> Unit)?) {
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(text, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (retry != null) TextButton(onClick = retry, modifier = Modifier.tag("computers-retry")) { Text("Retry") }
    }
}
