package com.danyzmaj.pocketterm.ui.terminal

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.SwapHoriz
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.Agent
import com.danyzmaj.pocketterm.core.AgentIntegration
import com.danyzmaj.pocketterm.core.TermCap
import com.danyzmaj.pocketterm.core.TermWindow
import com.danyzmaj.pocketterm.core.TerminalException
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.state.Tip
import com.danyzmaj.pocketterm.ui.LocalGraph
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.tips.TipAnchor
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.seconds

/**
 * Whether [window] is a coding agent's window that shows only as a screen and the phone can switch
 * it to the conversation view: no live session claims it, PocketTerm is installed in its agent on
 * the computer (so a restarted or reloaded agent reports), and its terminal presses keys and types.
 */
fun canSwitch(remote: TerminalRemote, window: TermWindow): Boolean {
    val agent = window.agent ?: return false
    return remote.agents[agent] == AgentIntegration.installed &&
        window.can(TermCap.keys) &&
        window.can(TermCap.type) &&
        remote.sessions.none { it.window == window.key }
}

/** How long the phone waits for the switched agent to report as a session. */
private val switchWait = 25.seconds

private enum class Phase { idle, switching, failed }

/**
 * What the session page does once a switched agent reports: an omp that was at work when its
 * restart stopped it is prompted `continue` right away ([send]), or offers a Continue chip ([offer]).
 */
enum class AfterSwitch { nothing, offer, send }

/**
 * The top of a screen-only agent window's page ([canSwitch]): a banner offering the switch to the
 * conversation view, then "Switching…" until the agent reports as a live session in this window,
 * whose page then replaces this one; or, after [switchWait], that it didn't come back.
 */
@Composable
fun SwitchBanner(remote: TerminalRemote, window: String) {
    remote.observe()
    val nav = LocalNav.current
    val toaster = LocalToaster.current
    val tips = LocalGraph.current.session.tips
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf(Phase.idle) }
    var agent by remember { mutableStateOf<Agent?>(null) }
    var after by remember { mutableStateOf(AfterSwitch.nothing) }
    var asking by remember { mutableStateOf<Agent?>(null) }
    // Bumped per attempt, so a late failure or timeout of an earlier one changes nothing.
    var attempt by remember { mutableStateOf(0) }

    fun start(a: Agent, then: AfterSwitch) {
        agent = a
        after = then
        phase = Phase.switching
        val mine = ++attempt
        scope.launch {
            try {
                remote.switchToConversation(window, a)
            } catch (e: Exception) {
                if (attempt != mine || phase != Phase.switching) return@launch
                phase = Phase.idle
                toaster.show(if (e is TerminalException) e.message else e.toString())
            }
        }
    }

    // Waiting for the agent to report from this window: its session's page takes this one's place.
    if (phase == Phase.switching) {
        val s = remote.sessions.firstOrNull { it.window == window }
        val currentAfter by rememberUpdatedState(after)
        LaunchedEffect(s?.key) {
            if (s == null) return@LaunchedEffect
            tips.switched(window)
            phase = Phase.idle
            nav.replaceWithSession(
                s.key,
                offerContinue = currentAfter == AfterSwitch.offer,
                autoContinue = currentAfter == AfterSwitch.send,
            )
        }
        LaunchedEffect(attempt) {
            delay(switchWait)
            if (phase == Phase.switching) phase = Phase.failed
        }
    }

    val w = remote.window(window)
    val online = remote.online
    val shown = when (phase) {
        Phase.idle -> if (w != null && canSwitch(remote, w)) Phase.idle else null
        else -> phase
    }
    AnimatedContent(
        targetState = shown,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        contentKey = { it },
        label = "switch-banner",
    ) { p ->
        when (p) {
            null -> Box(Modifier.fillMaxWidth())
            Phase.idle -> {
                val win = w ?: return@AnimatedContent
                val a = win.agent ?: return@AnimatedContent
                Banner("switch-offer", "This ${a.labelIn(win.profile)} session shows only its screen") {
                    TipAnchor(Tip.switchButton) {
                        FilledTonalButton(
                            onClick = { asking = a },
                            enabled = online,
                            modifier = Modifier.tag("switch-open"),
                        ) {
                            Icon(Icons.Rounded.SwapHoriz, null, Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Switch to conversation")
                        }
                    }
                }
            }
            Phase.switching -> Banner("switching", "Switching…") {
                CircularProgressIndicator(Modifier.padding(12.dp).size(20.dp), strokeWidth = 2.dp)
            }
            Phase.failed -> Banner("switch-failed", "It didn’t come back as a conversation.") {
                TextButton(
                    onClick = { agent?.let { asking = it } },
                    enabled = online,
                    modifier = Modifier.tag("switch-retry"),
                ) { Text("Try again") }
            }
        }
    }

    asking?.let { a ->
        SwitchSheet(
            remote = remote,
            window = window,
            agent = a,
            onDismiss = { asking = null },
            onConfirm = { then ->
                asking = null
                start(a, then)
            },
        )
    }
}

/** A tonal strip under the app bar: [text], and [action] beside it, or under it when narrow (large text, split screen). */
@Composable
private fun Banner(id: String, text: String, action: @Composable () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, modifier = Modifier.fillMaxWidth().tag(id)) {
        FlowRow(
            Modifier.padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp).animateContentSize(),
            horizontalArrangement = Arrangement.SpaceBetween,
            itemVerticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
                modifier = Modifier.padding(vertical = 8.dp).weight(1f, fill = true),
            )
            Box(Modifier.padding(start = 8.dp)) { action() }
        }
    }
}

/**
 * What switching [agent] in [window] does, asked before it's done. omp restarts, so the sheet first
 * asks the computer whether it's at work, warns that restarting stops it and offers to have it carry
 * on. [onConfirm] gets what the session page does about the stopped run.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwitchSheet(
    remote: TerminalRemote,
    window: String,
    agent: Agent,
    onDismiss: () -> Unit,
    onConfirm: (AfterSwitch) -> Unit,
) {
    val omp = agent == Agent.omp
    // omp: whether it's at work; null while the computer is asked. Claude Code isn't asked: nothing restarts.
    var busy by remember { mutableStateOf(if (omp) null else false) }
    if (omp) {
        LaunchedEffect(window) {
            busy = try {
                remote.probe(window)
            } catch (_: Exception) {
                // Unknown: offered without the warning.
                false
            }
        }
    }
    val haptics = rememberHaptics()
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    fun close(then: () -> Unit) {
        scope.launch { sheet.hide() }.invokeOnCompletion { then() }
    }
    fun pick(after: AfterSwitch) {
        haptics.done()
        close { onConfirm(after) }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 16.dp)
                .navigationBarsPadding()
                .animateContentSize(),
        ) {
            Text("Switch to conversation", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(12.dp))
            Text(
                if (omp) {
                    "PocketTerm restarts omp in this window and picks the same conversation back up " +
                        "(${Agent.omp.resumeIn(remote.window(window)?.profile ?: "")}). Nothing is lost."
                } else {
                    "PocketTerm types ${Agent.claude.pickUp} in it. Nothing restarts."
                },
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            val b = busy
            if (b == true) {
                Row(Modifier.padding(top = 16.dp).tag("switch-busy")) {
                    Icon(
                        Icons.Rounded.WarningAmber,
                        null,
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        "It’s working right now, and restarting stops it. Restart and continue has it carry on; " +
                            "Just restart leaves it stopped.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
            Spacer(Modifier.height(20.dp))
            when (b) {
                null -> Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).tag("switch-probing"), Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                }
                // omp at work: restart and have it carry on, or just restart, stacked so both read in full.
                true -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = { pick(AfterSwitch.send) },
                        modifier = Modifier.fillMaxWidth().tag("switch-continue"),
                    ) { Text("Restart and continue") }
                    OutlinedButton(
                        onClick = { pick(AfterSwitch.offer) },
                        modifier = Modifier.fillMaxWidth().tag("switch-confirm"),
                    ) { Text("Just restart") }
                    TextButton(
                        onClick = { close(onDismiss) },
                        modifier = Modifier.fillMaxWidth().tag("switch-cancel"),
                    ) { Text("Not now") }
                }
                false -> FlowRow(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                ) {
                    TextButton(onClick = { close(onDismiss) }, modifier = Modifier.tag("switch-cancel")) { Text("Not now") }
                    Button(
                        onClick = { pick(AfterSwitch.nothing) },
                        modifier = Modifier.tag("switch-confirm"),
                    ) { Text(if (omp) "Restart now" else "Switch") }
                }
            }
        }
    }
}
