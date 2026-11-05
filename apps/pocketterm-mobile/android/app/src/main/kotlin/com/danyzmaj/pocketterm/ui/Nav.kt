package com.danyzmaj.pocketterm.ui

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.navigation.NavHostController
import androidx.navigation.toRoute
import com.danyzmaj.pocketterm.AppGraph
import com.danyzmaj.pocketterm.state.HomeController
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.Serializable

// The app's destinations (Navigation Compose, type-safe routes). The root shows setup, the push
// question or the home list as the session stands; everything else is pushed over it.

@Serializable
data object RootRoute

/**
 * A coding session's conversation. [starting]: just launched, its agent may not have reported yet.
 * [offerContinue]/[autoContinue]: it just came back from a switch to the conversation view (switch
 * sheet: the agent was busy; Continue offered, or sent at once).
 */
@Serializable
data class SessionRoute(
    val key: String,
    val starting: Boolean = false,
    val offerContinue: Boolean = false,
    val autoContinue: Boolean = false,
)

/** A terminal window's raw screen. [starting]: just launched (a shell), it may not have a screen yet. */
@Serializable
data class TerminalRoute(val window: String, val starting: Boolean = false)

/** A session's full queue. */
@Serializable
data class QueueRoute(val key: String)

/** The orchestrator's conversation, full screen. */
@Serializable
data object OrchestratorRoute

/** Settings (the Flutter app's account sheet). */
@Serializable
data object SettingsRoute

/** The QR scanner; [signedIn]: scanning another computer's code (it must carry a key), else a sign-in code. */
@Serializable
data class ScanRoute(val signedIn: Boolean)

/** Where screens go: one per activity, [LocalNav]. */
class Nav(val controller: NavHostController) {
    fun openSession(key: String, starting: Boolean = false, offerContinue: Boolean = false, autoContinue: Boolean = false) =
        controller.navigate(SessionRoute(key, starting, offerContinue, autoContinue))

    /** The session's page in place of the one in front (a window switched to its conversation). */
    fun replaceWithSession(key: String, offerContinue: Boolean, autoContinue: Boolean) {
        controller.popBackStack()
        openSession(key, offerContinue = offerContinue, autoContinue = autoContinue)
    }

    fun openTerminal(window: String, starting: Boolean = false) = controller.navigate(TerminalRoute(window, starting))

    fun openQueue(key: String) = controller.navigate(QueueRoute(key))

    fun openOrchestrator() = controller.navigate(OrchestratorRoute)

    fun openSettings() = controller.navigate(SettingsRoute)

    fun back() {
        controller.popBackStack()
    }

    /** Every page over the root goes. */
    fun popToRoot() {
        controller.popBackStack(RootRoute, inclusive = false)
    }

    /** Whether the root is in front. */
    val atRoot: Boolean get() = controller.currentBackStackEntry?.destination?.route == RootRoute::class.qualifiedName

    /** Whether session [key]'s page is the one in front. */
    fun showingSession(key: String): Boolean {
        val e = controller.currentBackStackEntry ?: return false
        if (e.destination.route?.startsWith(SessionRoute::class.qualifiedName!!) != true) return false
        return e.toRoute<SessionRoute>().key == key
    }

    private var scanning: CompletableDeferred<String?>? = null

    /** Opens the scanner and waits for its code: the link read (or pasted), null when it closed without one. */
    suspend fun scan(signedIn: Boolean): String? {
        scanning?.complete(null)
        val wait = CompletableDeferred<String?>()
        scanning = wait
        controller.navigate(ScanRoute(signedIn))
        return wait.await()
    }

    /** The scanner's answer ([scan]); it closes. Null: cancelled. */
    fun scanned(link: String?) {
        val wait = scanning
        scanning = null
        if (controller.currentBackStackEntry?.destination?.route?.startsWith(ScanRoute::class.qualifiedName!!) == true) {
            controller.popBackStack()
        }
        wait?.complete(link)
    }
}

val LocalNav = staticCompositionLocalOf<Nav> { error("No Nav") }
val LocalGraph = staticCompositionLocalOf<AppGraph> { error("No AppGraph") }

/** The home screen's state for the root showing it (a sign-in or the demo); null at setup and the push question. */
val LocalHome = staticCompositionLocalOf<HomeController?> { null }
