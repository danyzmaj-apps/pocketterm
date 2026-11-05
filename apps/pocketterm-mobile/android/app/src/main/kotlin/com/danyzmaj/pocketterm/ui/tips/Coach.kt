package com.danyzmaj.pocketterm.ui.tips

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RichTooltip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TooltipAnchorPosition
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.rememberTooltipState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.danyzmaj.pocketterm.state.Tip
import com.danyzmaj.pocketterm.state.Tips
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

/**
 * The first-use tips, one at a time: of the [TipAnchor]s that sit in view on a page that has settled
 * (in front, no sheet or dialog over it, no keyboard up), the first unseen tip in tour order shows as
 * a Material rich tooltip with "Got it". One per activity ([LocalCoach]).
 */
class Coach(val tips: Tips) {
    /** The tips whose anchors may show now, with how many anchors each has. */
    private val ready = mutableStateMapOf<Tip, Int>()

    /** The tip showing; null: none. */
    var showing: Tip? by mutableStateOf(null)
        private set

    internal fun enter(tip: Tip) {
        ready[tip] = (ready[tip] ?: 0) + 1
    }

    internal fun leave(tip: Tip) {
        val n = (ready[tip] ?: 0) - 1
        if (n <= 0) ready.remove(tip) else ready[tip] = n
        if (showing == tip && n <= 0) showing = null
    }

    /** Switch tour steps due on the page in front whose anchors may be out of view ([TourStep]). */
    private val due = mutableStateMapOf<Tip, Int>()

    internal fun due(tip: Tip) {
        due[tip] = (due[tip] ?: 0) + 1
    }

    internal fun undue(tip: Tip) {
        val n = (due[tip] ?: 0) - 1
        if (n <= 0) due.remove(tip) else due[tip] = n
    }

    /** Picks the tip to show, once what's in view has sat still a moment. */
    internal suspend fun run() {
        snapshotFlow { ready.keys.toSet() to due.keys.toSet() }.collectLatest { (candidates, steps) ->
            delay(SETTLE_MS)
            // A tour step due here but scrolled out of view holds back every later tip, so the tour comes first.
            val hold = steps.filter { it !in candidates && !tips.seen(it) }.minOfOrNull { it.ordinal }
            val open = if (hold == null) candidates else candidates.filter { it.ordinal < hold }.toSet()
            val keep = showing?.takeIf { it in open && !tips.seen(it) }
            showing = keep ?: tips.next(open)
        }
    }

    /** "Got it" (or the bubble dismissed): seen for good on this phone. */
    fun dismiss(tip: Tip) {
        tips.markSeen(tip)
        ready.remove(tip)
        if (showing == tip) showing = null
    }

    private companion object {
        const val SETTLE_MS = 600L
    }
}

val LocalCoach = staticCompositionLocalOf<Coach?> { null }

/** Runs the coach for [content]; put once near the root. */
@Composable
fun CoachHost(coach: Coach) {
    coach.tips.observe()
    LaunchedEffect(coach) { coach.run() }
}

/**
 * Says that [tip], a switch tour step, is due on this page (its row is in the list, maybe out of view)
 * while [active]; until it has shown, no later tip shows here.
 */
@Composable
fun TourStep(tip: Tip, active: Boolean) {
    val coach = LocalCoach.current ?: return
    val tips = coach.tips.observe()
    val resumed = LocalLifecycleOwner.current.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val due = active && tip.tour && tips.answered && !tips.seen(tip) && resumed
    DisposableEffect(coach, tip, due) {
        if (due) coach.due(tip)
        onDispose { if (due) coach.undue(tip) }
    }
}

/**
 * [content] with [tip] pointed at it, when the coach shows that one. Its bubble is `tip-<id>`, its
 * button `tip-got-it`. [enabled]: whether this anchor may show it now (the first row only, say).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun TipAnchor(tip: Tip, modifier: Modifier = Modifier, enabled: Boolean = true, content: @Composable () -> Unit) {
    val coach = LocalCoach.current
    if (coach == null) {
        Box(modifier, propagateMinConstraints = true) { content() }
        return
    }
    val tips = coach.tips.observe()
    val focused = LocalWindowInfo.current.isWindowFocused
    val resumed = LocalLifecycleOwner.current.lifecycle.currentStateAsState().value.isAtLeast(Lifecycle.State.RESUMED)
    val ime = WindowInsets.isImeVisible
    var inView by remember { mutableStateOf(false) }
    // The bubble's own popup may take the window's focus: that isn't a sheet coming over the page.
    val eligible = enabled && tips.answered && !tips.seen(tip) && (focused || coach.showing == tip) && resumed && !ime && inView
    DisposableEffect(coach, tip, eligible) {
        if (eligible) coach.enter(tip)
        onDispose { if (eligible) coach.leave(tip) }
    }
    val state = rememberTooltipState(isPersistent = true)
    val show = eligible && coach.showing == tip
    val haptics = rememberHaptics()
    LaunchedEffect(show) {
        if (show) {
            haptics.picked()
            state.show()
        } else {
            state.dismiss()
        }
    }
    // Dismissed by a tap elsewhere: as good as Got it.
    LaunchedEffect(state, show) {
        if (!show) return@LaunchedEffect
        snapshotFlow { state.isVisible }.collectLatest { visible -> if (!visible && coach.showing == tip) coach.dismiss(tip) }
    }
    // The caller's modifier (a Row weight, padding) goes on a Box of its own: TooltipBox doesn't pass parent data on.
    Box(
        modifier.onGloballyPositioned { c ->
            val b = c.boundsInWindow()
            inView = b.width > 0f && b.height > 0f
        },
        propagateMinConstraints = true,
    ) {
        TooltipBox(
            positionProvider = TooltipDefaults.rememberTooltipPositionProvider(TooltipAnchorPosition.Above),
            tooltip = {
                RichTooltip(
                    modifier = Modifier.tag("tip-${tip.id}"),
                    action = {
                        TextButton(onClick = { coach.dismiss(tip) }, modifier = Modifier.tag("tip-got-it")) { Text("Got it") }
                    },
                ) { Text(tip.caption) }
            },
            state = state,
            enableUserInput = false,
        ) {
            content()
        }
    }
}

/**
 * The first time on the list (also the demo's): whether to have the first-use tips, as an Android
 * dialog. Only its two buttons answer it (true: Show me).
 */
@Composable
fun TourDialog(onAnswer: (Boolean) -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
        modifier = Modifier.tag("tour-ask"),
        title = { Text("New here?") },
        text = {
            Text(
                "Want a quick tour? A few tips point out what you can tap, one at a time.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        dismissButton = { TextButton(onClick = { onAnswer(false) }, Modifier.tag("tour-no")) { Text("No thanks") } },
        confirmButton = { TextButton(onClick = { onAnswer(true) }, Modifier.tag("tour-yes")) { Text("Show me") } },
    )
}
