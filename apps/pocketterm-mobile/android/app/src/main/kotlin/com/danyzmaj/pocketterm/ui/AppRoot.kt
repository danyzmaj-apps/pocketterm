package com.danyzmaj.pocketterm.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.danyzmaj.pocketterm.AppGraph
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.state.HomeController
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.Toaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.home.HomeScreen
import com.danyzmaj.pocketterm.ui.orchestrator.OrchestratorScreen
import com.danyzmaj.pocketterm.ui.queue.QueueScreen
import com.danyzmaj.pocketterm.ui.session.SessionScreen
import com.danyzmaj.pocketterm.ui.settings.SettingsScreen
import com.danyzmaj.pocketterm.ui.setup.PushConsentScreen
import com.danyzmaj.pocketterm.ui.setup.ScanScreen
import com.danyzmaj.pocketterm.ui.setup.SetupScreen
import com.danyzmaj.pocketterm.ui.terminal.TerminalScreen
import com.danyzmaj.pocketterm.ui.theme.PocketTermTheme
import com.danyzmaj.pocketterm.ui.tips.Coach
import com.danyzmaj.pocketterm.ui.tips.CoachHost
import com.danyzmaj.pocketterm.ui.tips.LocalCoach

/** What the root shows, by how the session stands; pages over it belong to it and go when it changes. */
private sealed interface Root {
    /** Still reading what this phone kept: nothing, not setup for a moment (the splash stays meanwhile). */
    data object Launching : Root

    data object Setup : Root

    /** Signed in, push not asked yet. */
    data object Consent : Root

    /** The home list: a sign-in ([id] its user) or the demo. */
    data class Home(val id: String) : Root
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun AppRoot(graph: AppGraph) {
    PocketTermTheme(graph.appearance) {
        val session = graph.session.observe()
        val user = session.user
        val demo = session.demo
        val root = when {
            user == null && session.launching -> Root.Launching
            user == null && demo != null -> Root.Home("demo")
            user == null -> Root.Setup
            session.pushEnabled == null -> Root.Consent
            else -> Root.Home(user.id)
        }
        val controller = rememberNavController()
        val nav = remember(controller) { Nav(controller) }
        val scope = rememberCoroutineScope()
        val toaster = remember { Toaster(SnackbarHostState(), scope) }
        val coach = remember { Coach(session.tips) }
        val context = androidx.compose.ui.platform.LocalContext.current

        // One home state per sign-in (or the demo): a new one comes when that changes.
        val home: HomeController? = remember(root) {
            if (root !is Root.Home) {
                null
            } else {
                HomeController(
                    session,
                    graph.native,
                    graph.scope,
                    supportDir = context.filesDir,
                    demoDesktops = if (root.id == "demo") demo?.desktops else null,
                    demoRemote = if (root.id == "demo") demo?.remote else null,
                )
            }
        }
        DisposableEffect(home) {
            home?.ui = object : HomeController.Ui {
                override fun openSession(remote: TerminalRemote, key: String) = nav.openSession(key)
                override fun showingSession(key: String) = nav.showingSession(key)
                override fun closeSession(key: String) {
                    if (nav.showingSession(key)) nav.back()
                }
                override fun popToHome() = nav.popToRoot()
                override val atHome: Boolean get() = nav.atRoot
                override fun toast(message: String) = toaster.show(message)
            }
            onDispose { home?.dispose() }
        }
        // Pages and sheets over one root go with it (signed out here or by the computer, the demo left).
        LaunchedEffect(root) { nav.popToRoot() }

        val lifecycle = LocalLifecycleOwner.current.lifecycle
        DisposableEffect(lifecycle, home) {
            val observer = LifecycleEventObserver { _, e ->
                when (e) {
                    Lifecycle.Event.ON_RESUME -> home?.onResume()
                    Lifecycle.Event.ON_PAUSE -> home?.onPause()
                    else -> {}
                }
            }
            lifecycle.addObserver(observer)
            onDispose { lifecycle.removeObserver(observer) }
        }

        CompositionLocalProvider(
            LocalGraph provides graph,
            LocalNav provides nav,
            LocalHome provides home,
            LocalToaster provides toaster,
            LocalCoach provides coach,
        ) {
            CoachHost(coach)
            Box(
                Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surface)
                    // Test tags are resource ids, so Maestro and UI Automator find controls by them.
                    .semantics { testTagsAsResourceId = true },
            ) {
                NavHost(controller, startDestination = RootRoute) {
                    composable<RootRoute> {
                        when (root) {
                            Root.Launching -> Box(Modifier.fillMaxSize())
                            Root.Setup -> SetupScreen()
                            Root.Consent -> PushConsentScreen()
                            is Root.Home -> home?.let { HomeScreen(it) }
                        }
                    }
                    composable<SessionRoute> { entry -> withHome(home, nav) { SessionScreen(entry.toRoute(), it) } }
                    composable<TerminalRoute> { entry -> withHome(home, nav) { TerminalScreen(entry.toRoute(), it) } }
                    composable<QueueRoute> { entry -> withHome(home, nav) { QueueScreen(entry.toRoute(), it) } }
                    composable<OrchestratorRoute> { withHome(home, nav) { OrchestratorScreen(it) } }
                    composable<SettingsRoute> { SettingsScreen() }
                    composable<ScanRoute> { entry -> ScanScreen(entry.toRoute<ScanRoute>().signedIn) }
                }
                SnackbarHost(
                    toaster.host,
                    Modifier
                        .align(Alignment.BottomCenter)
                        .navigationBarsPadding()
                        .imePadding(),
                )
            }
        }
    }
}

/** A page on the home screen's computer: [content] with its state, or back to the root when there's none (signed out meanwhile). */
@Composable
private fun withHome(home: HomeController?, nav: Nav, content: @Composable (HomeController) -> Unit) {
    if (home == null) {
        LaunchedEffect(Unit) { nav.popToRoot() }
        return
    }
    content(home)
}
