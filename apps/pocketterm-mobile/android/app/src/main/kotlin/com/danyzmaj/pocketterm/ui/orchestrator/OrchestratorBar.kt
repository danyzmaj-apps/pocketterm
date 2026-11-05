package com.danyzmaj.pocketterm.ui.orchestrator

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.Agent
import com.danyzmaj.pocketterm.core.AgentIntegration
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus

// The computer's orchestrator (LiveSummary.orchestrator): an omp session the computer starts in
// PocketTerm's own folder, with tools to see and steer its other sessions. The home list shows it as
// a bar, not as a project; the bar opens it as a chat.

private const val ASK = "Ask about your sessions…"

/**
 * The bar at the bottom of the home list: what the orchestrator is up to; a tap opens it. Shown once
 * the computer's omp can run one (PocketTerm installed in it), or one runs; nothing otherwise.
 */
@Composable
fun OrchestratorBar(remote: TerminalRemote, modifier: Modifier = Modifier) {
    remote.observe()
    val o = remote.orchestrator
    if (o == null && remote.agents[Agent.omp] != AgentIntegration.installed) return
    val nav = LocalNav.current
    val c = MaterialTheme.colorScheme
    val ask = o?.ask
    val (text, color) = when {
        o == null -> ASK to c.onSurfaceVariant
        ask != null -> "Needs you: ${ask.text}" to LocalStatus.current.needs
        o.busy -> "Working…" to c.primary
        o.preview.isNotEmpty() -> o.preview to c.onSurface
        else -> ASK to c.onSurfaceVariant
    }
    val working = o != null && ask == null && o.busy
    Surface(
        onClick = { nav.openOrchestrator() },
        shape = RoundedCornerShape(28.dp),
        color = c.surfaceContainerHigh,
        shadowElevation = 3.dp,
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .tag("orchestrator-bar")
            // Read as the iPhone's: Orchestrator, then what it says (tests find it by both).
            .semantics(mergeDescendants = true) { contentDescription = "Orchestrator\n$text" },
    ) {
        Row(Modifier.padding(horizontal = 18.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.AutoAwesome, contentDescription = null, tint = c.primary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(12.dp))
            if (working) {
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = c.primary)
                Spacer(Modifier.width(8.dp))
            }
            Text(
                text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                color = color,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f),
            )
        }
    }
}
