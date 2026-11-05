package com.danyzmaj.pocketterm.ui.common

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.danyzmaj.pocketterm.ActivityHost
import com.danyzmaj.pocketterm.core.Backend
import com.danyzmaj.pocketterm.core.ChangeNotifier
import com.danyzmaj.pocketterm.core.Desktop
import com.danyzmaj.pocketterm.core.TerminalLink
import com.danyzmaj.pocketterm.core.TerminalRemote
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlin.time.Duration

/**
 * Recomposes the caller whenever [this] notifies (core [ChangeNotifier]s: the session, a remote,
 * the computers…); read the holder's properties after calling it.
 */
@Composable
fun <T : ChangeNotifier> T.observe(): T {
    revision.collectAsState().value
    return this
}

/** The same, as a state to read where it's needed (a lambda, a derived value). */
@Composable
fun ChangeNotifier.revisionState(): State<Long> = revision.collectAsState()

/**
 * A stable test id (`Modifier.testTag`), exposed as the view's resource id so Maestro and UI Automator
 * find the control by it. Set per node, not only at the root: dialogs, sheets and menus are windows of
 * their own, which the root's `testTagsAsResourceId` doesn't reach.
 */
@OptIn(ExperimentalComposeUiApi::class)
fun Modifier.tag(id: String): Modifier = semantics { testTagsAsResourceId = true }.testTag(id)

/**
 * [tag] with [label] as the node's description, on the same node: a row read as one line (TalkBack),
 * and found by tests by its id and its words together, as on the iPhone.
 */
@OptIn(ExperimentalComposeUiApi::class)
fun Modifier.tag(id: String, label: String): Modifier = semantics {
    testTagsAsResourceId = true
    testTag = id
    contentDescription = label
}

// ---------------------------------------------------------------------- messages

/**
 * The app's one snackbar host (MainActivity's scaffold-free root shows it above everything):
 * short messages after an action, as the Flutter app's SnackBars.
 */
class Toaster(val host: SnackbarHostState, private val scope: CoroutineScope) {
    /** Shows [message]; [action] with [onAction] when given. Replaces one showing. */
    fun show(message: String, action: String? = null, long: Boolean = false, onAction: (() -> Unit)? = null) {
        scope.launch {
            host.currentSnackbarData?.dismiss()
            val result = host.showSnackbar(
                message,
                actionLabel = action,
                withDismissAction = action == null && long,
                duration = if (long || action != null) SnackbarDuration.Long else SnackbarDuration.Short,
            )
            if (result == SnackbarResult.ActionPerformed) onAction?.invoke()
        }
    }
}

val LocalToaster = staticCompositionLocalOf<Toaster> { error("No Toaster") }

// ---------------------------------------------------------------------- haptics

/** Haptics with a meaning, as the Flutter app's: [done] an action went, [picked] one of several was picked. */
class Haptics(private val h: HapticFeedback) {
    fun done() = h.performHapticFeedback(HapticFeedbackType.Confirm)
    fun picked() = h.performHapticFeedback(HapticFeedbackType.SegmentTick)
    fun longPress() = h.performHapticFeedback(HapticFeedbackType.LongPress)
}

@Composable
fun rememberHaptics(): Haptics = Haptics(LocalHapticFeedback.current)

// ---------------------------------------------------------------------- avatar

/** The server's initial in a circle, the accent's gradient; TalkBack reads it as nothing (the button says "Account"). */
@Composable
fun Avatar(name: String, size: Dp = 30.dp, modifier: Modifier = Modifier) {
    val c = MaterialTheme.colorScheme
    Box(
        modifier
            .size(size)
            .background(Brush.linearGradient(listOf(c.primary, lerp(c.primary, c.error, .5f))), CircleShape)
            .clearAndSetSemantics {},
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (name.isEmpty()) "?" else name.take(1).uppercase(),
            color = c.onPrimary,
            fontSize = (size.value * .45f).sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

// ---------------------------------------------------------------------- words

/** PocketTerm's home: the source, the docs and the desktop downloads. */
const val repoUrl = "https://github.com/danyzmaj-apps/pocketterm"

/** The desktop app's latest release (Mac DMG, Windows installer). */
const val desktopDownloadsUrl = "$repoUrl/releases/latest"

/** Opens [url] in the browser, outside the app. */
fun openExternal(url: String) {
    ActivityHost.start(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
}

/** How long ago [ms] (since epoch) was: "just now", "5 min ago", "3 h ago", "2 d ago". */
fun ago(ms: Long, now: Long = System.currentTimeMillis()): String {
    val d = (now - ms) / 60_000
    return when {
        d < 1 -> "just now"
        d < 60 -> "$d min ago"
        d < 24 * 60 -> "${d / 60} h ago"
        else -> "${d / (24 * 60)} d ago"
    }
}

/**
 * Why the phone gets no answer from [server], and what to do: a server on a tailnet runs on one of
 * the person's computers, which has to be awake, and its address changes when that computer is
 * renamed (the phone then needs that computer's new code); a tailnet with device approval on holds a
 * new phone back until its admin approves it.
 */
fun serverUnreachable(server: Backend): String = if (server.onTailnet) {
    "${server.unreachable} The computer running it has to be awake. If it was renamed in Tailscale, leave this " +
        "server (Settings) and scan its new code. If Tailscale says Awaiting Approval, approve this phone in the " +
        "Tailscale admin console under Machines."
} else {
    server.unreachable
}

/** What's wrong with a remote's link, for the top of a screen ([linkNote]); [retry]: offer Retry ([TerminalRemote.reconnect]). */
data class LinkNote(val text: String, val busy: Boolean, val retry: Boolean)

/**
 * What's wrong with the link to [r]'s computer, if anything, as one line: with how old the shown
 * state is when it isn't live, and whether a Retry that connects again at once helps (it's stuck).
 */
fun linkNote(r: TerminalRemote, now: Long = System.currentTimeMillis()): LinkNote? {
    val at = r.stateAt
    val who = r.desktopName ?: "the computer"
    val seen = r.desktopSeenAt
    val clockOff = r.clockOff
    val (text, busy) = when (r.link) {
        TerminalLink.connecting -> "connecting…" to true
        TerminalLink.unreachable -> serverUnreachable(r.backend) to false
        TerminalLink.waiting -> "asking $who…" to true
        // Its messages come, but a clock this far off makes them look replayed: they're dropped.
        TerminalLink.offline if clockOff != null ->
            "This phone's clock and $who's differ by ${clockGap(clockOff)}, so nothing from it can be trusted. Turn on " +
                "Set time automatically (Date & time) on both." to false
        // Not reporting to the server either: not there, rather than not answering.
        TerminalLink.offline if seen != null && now - seen >= Desktop.onlineWithin.inWholeMilliseconds ->
            "$who was last seen ${ago(seen, now)}. It may be asleep or off, or PocketTerm isn't running there." to false
        TerminalLink.offline ->
            "$who isn't answering. It has to be awake, with PocketTerm running and Settings → Terminal from phone on." to false
        TerminalLink.online -> r.error to false
    }
    if (text == null) return null
    val line = when {
        r.link == TerminalLink.online -> text
        at != null -> "Updated ${ago(at, now)} · $text"
        else -> text.replaceFirstChar { it.uppercase() }
    }
    return LinkNote(line, busy, retry = !busy && r.link != TerminalLink.online && clockOff == null)
}

/** "1 minute", "45 minutes", "3 hours": how far two clocks are apart. */
private fun clockGap(d: Duration): String {
    val minutes = d.absoluteValue.inWholeMinutes
    if (minutes < 120) return if (minutes == 1L) "1 minute" else "$minutes minutes"
    return "${d.absoluteValue.inWholeHours} hours"
}
