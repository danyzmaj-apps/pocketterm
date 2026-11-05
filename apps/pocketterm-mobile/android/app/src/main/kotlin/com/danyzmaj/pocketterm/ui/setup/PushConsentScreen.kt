package com.danyzmaj.pocketterm.ui.setup

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material.icons.outlined.ToggleOn
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.showPushNotAllowed
import com.danyzmaj.pocketterm.ui.common.tag
import kotlinx.coroutines.launch

/**
 * After the first sign-in on a server, before anything registers for push: what notifications go
 * through and who runs it, then the person's choice (MobileSession.setPushEnabled). Settings'
 * Notifications switch changes it later.
 */
@Composable
fun PushConsentScreen() {
    val graph = LocalGraph.current
    val session = graph.session
    val toaster = LocalToaster.current
    var busy by remember { mutableStateOf(false) }

    // On the app's scope: the choice takes the screen away (the root changes) while it may still be
    // registering, and that mustn't cancel it.
    fun choose(on: Boolean) {
        busy = true
        graph.scope.launch {
            val allowed = session.setPushEnabled(on)
            if (on && !allowed) toaster.showPushNotAllowed(session.notificationsAllowed, graph.native, graph.scope)
            busy = false
        }
    }

    Scaffold(
        // The choice stays in reach; what it's about scrolls above it.
        bottomBar = {
            Column(
                Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 24.dp, vertical = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Column(Modifier.widthIn(max = 460.dp)) {
                    Button(
                        onClick = { choose(on = true) },
                        enabled = !busy,
                        modifier = Modifier.fillMaxWidth().height(56.dp).tag("push-accept"),
                    ) {
                        if (busy) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Text("Turn on notifications")
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    TextButton(
                        // Never waits on anything: the way out while Turn on still waits on the phone.
                        onClick = { choose(on = false) },
                        modifier = Modifier.fillMaxWidth().tag("push-not-now"),
                    ) { Text("Not now") }
                }
            }
        },
    ) { padding ->
        Box(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.TopCenter,
        ) {
            Column(
                Modifier
                    .widthIn(max = 460.dp)
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    Icons.Outlined.NotificationsActive,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    "Know when a session needs you",
                    style = MaterialTheme.typography.headlineSmall,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.semantics { heading() },
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "Your computer tells this phone when a coding session finishes or asks something, even while " +
                        "PocketTerm is closed.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                PushExplainer()
            }
        }
    }
}

/** Where notifications go and what each one on the way can see. */
@Composable
fun PushExplainer(modifier: Modifier = Modifier) {
    ElevatedCard(modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Point(
                Icons.Outlined.Dns,
                "Notifications go through PocketTerm’s push relay, run by Danijel Lovric on his server in Germany " +
                    "(push.danyzmaj.com). It passes encrypted notifications to Apple or Google. It can’t read them and " +
                    "keeps nothing.",
            )
            Point(
                Icons.Outlined.Lock,
                "The relay and Google see an encrypted message, this phone’s push token and when it was sent, never " +
                    "which computer or session it is about. Your computer encrypts each notification with the key from its " +
                    "code, and only your phones open it.",
            )
            Point(Icons.Outlined.Notifications, "Sessions you follow in your notifications are encrypted the same way.")
            Point(Icons.Outlined.ToggleOn, "Change your mind any time: Account → Notifications.")
        }
    }
}

@Composable
private fun Point(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(12.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium)
    }
}
