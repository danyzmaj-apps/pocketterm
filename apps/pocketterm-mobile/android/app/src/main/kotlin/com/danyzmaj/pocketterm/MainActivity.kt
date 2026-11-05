package com.danyzmaj.pocketterm

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.danyzmaj.pocketterm.ui.AppRoot

/**
 * The app's one activity: edge to edge, Compose all the way down ([AppRoot]). It hands what comes
 * in from outside to the app: `pocketterm://` links (setup links, followed sessions') and the session
 * of a tapped terminal push.
 */
class MainActivity : ComponentActivity() {
    private val graph: AppGraph get() = (application as PocketTermApp).graph

    override fun onCreate(savedInstanceState: Bundle?) {
        val splash = installSplashScreen()
        super.onCreate(savedInstanceState)
        // The system splash stays until the session has read what this phone kept: no flash of setup.
        splash.setKeepOnScreenCondition { graph.session.launching }
        enableEdgeToEdge()
        ActivityHost.attach(this)
        // A recreated activity has already handled its intent.
        if (savedInstanceState == null) handle(intent)
        PocketTermShared.forgetPushKey(this)
        setContent { AppRoot(graph) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    override fun onStop() {
        super.onStop()
        // Out of sight: the launcher can swap the icon without closing the app on the person.
        AppIcons.applyPending(this)
    }

    override fun onDestroy() {
        ActivityHost.detach(this)
        super.onDestroy()
    }

    /** A terminal push was tapped, or a pocketterm:// link opened. */
    private fun handle(intent: Intent?) {
        intent ?: return
        if (intent.hasExtra(Notifications.EXTRA_SESSION)) {
            val session = intent.getStringExtra(Notifications.EXTRA_SESSION)
            NativeEvents.tappedSession = session
            NativeEvents.emit("openTerminal", if (session == null) emptyMap() else mapOf("session" to session))
            intent.removeExtra(Notifications.EXTRA_SESSION)
        }
        val data = intent.data
        if (intent.action == Intent.ACTION_VIEW && data?.scheme == "pocketterm") {
            graph.openLink(data.toString())
            // Handled once, also across a configuration change.
            intent.data = null
        }
    }
}
