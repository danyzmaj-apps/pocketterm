package com.danyzmaj.pocketterm.ui.common

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.home.shortPath
import com.danyzmaj.pocketterm.ui.home.termError
import kotlinx.coroutines.launch

/**
 * Asks before [window] closes on the computer: its agent's session ends (or the window closes), and
 * what runs in it with it. Confirmed, the close goes ([TerminalRemote.close]) and the dialog stays,
 * spinning (`close-sent`), until the computer answers: [onClosed] once it closed, else what went
 * wrong shows and the dialog goes ([onDismiss]). [session]: the window's session, when it has one
 * (its agent names it while the computer hasn't listed the window).
 */
@Composable
fun CloseConfirm(remote: TerminalRemote, window: String, session: String?, onDismiss: () -> Unit, onClosed: () -> Unit) {
    val graph = LocalGraph.current
    val toaster = LocalToaster.current
    remote.observe()
    var closing by remember { mutableStateOf(false) }
    val w = remote.window(window)
    val agent = w?.agent ?: session?.let { remote.session(it)?.agent }
    val who = remote.desktopName ?: "the computer"
    val cwd = w?.cwd ?: session?.let { remote.session(it)?.cwd } ?: ""
    val where = if (cwd.isEmpty()) "" else " in ${shortPath(remote, cwd)}"
    val title: String
    val detail: String
    val action: String
    if (agent != null) {
        title = "End this ${agent.label} session on $who?"
        detail = "Its window$where closes with it."
        action = "End session"
    } else {
        title = "Close this window on $who?"
        detail = "${w?.program?.ifEmpty { null } ?: "Whatever runs in it"}$where stops with it."
        action = "Close window"
    }
    AlertDialog(
        onDismissRequest = { if (!closing) onDismiss() },
        properties = DialogProperties(dismissOnBackPress = !closing, dismissOnClickOutside = !closing),
        modifier = Modifier.tag("close-dialog"),
        title = { Text(title) },
        text = { Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant) },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !closing, modifier = Modifier.tag("close-cancel")) { Text("Keep") }
        },
        confirmButton = {
            if (closing) {
                Box(Modifier.size(48.dp, 40.dp).tag("close-sent"), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.error)
                }
            } else {
                TextButton(
                    onClick = {
                        closing = true
                        // The app's scope: the close is the computer's to answer even if this page goes meanwhile.
                        graph.scope.launch {
                            val ok = try {
                                remote.close(window)
                                true
                            } catch (e: Exception) {
                                if (e is CancellationException) throw e
                                toaster.show(termError(e))
                                false
                            }
                            closing = false
                            if (ok) onClosed() else onDismiss()
                        }
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                    modifier = Modifier.tag("close-confirm"),
                ) { Text(action) }
            }
        },
    )
}
