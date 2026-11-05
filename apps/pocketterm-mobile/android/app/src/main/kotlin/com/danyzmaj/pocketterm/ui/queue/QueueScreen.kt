package com.danyzmaj.pocketterm.ui.queue

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.VerticalAlignBottom
import androidx.compose.material.icons.filled.VerticalAlignTop
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.DeleteSweep
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.danyzmaj.pocketterm.core.LiveQueued
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.state.HomeController
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.QueueRoute
import com.danyzmaj.pocketterm.ui.common.Haptics
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.Toaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.session.attempt
import com.danyzmaj.pocketterm.ui.session.problemText
import com.danyzmaj.pocketterm.ui.session.rememberPageToaster
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** How long one that went shows as Sent. */
private const val SENT_FOR_MS = 1500L

/** Lines a long prompt shows until it's opened. */
private const val FOLDED_LINES = 6

/**
 * Every prompt waiting in a session's queue on the computer, whole: each can be edited in place, moved
 * (dragged, or to the top or bottom), sent now (an agent that steers), copied or deleted; the queue
 * paused or cleared, and a prompt added at its end. Follows the computer: one that goes to the agent
 * shows as Sent for a moment. Offline, it only shows.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QueueScreen(route: QueueRoute, home: HomeController) {
    val nav = LocalNav.current
    home.observe()
    // The page belongs to the computer it opened on: another one selected meanwhile takes it away.
    val remote = remember { home.remote }
    if (remote == null || home.remote !== remote) {
        LaunchedEffect(Unit) { nav.popToRoot() }
        return
    }
    remote.observe()
    val toaster = rememberPageToaster()
    val scope = rememberCoroutineScope()
    val haptics = rememberHaptics()
    val model = remember(remote, route.key) { QueueModel(remote, route.key, scope, toaster, haptics) }
    DisposableEffect(model) {
        remote.addListener(model.listener)
        onDispose { remote.removeListener(model.listener) }
    }
    val s = remote.session(route.key)
    val online = remote.online && s != null
    CompositionLocalProvider(LocalToaster provides toaster) {
        Scaffold(
            topBar = {
                TopAppBar(
                    navigationIcon = {
                        IconButton(onClick = { nav.back() }, modifier = Modifier.tag("queue-close")) {
                            Icon(Icons.Filled.Close, contentDescription = "Close")
                        }
                    },
                    title = {
                        Text(
                            s?.let(::sessionTitle) ?: "Queue",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.tag("queue-title"),
                        )
                    },
                )
            },
            bottomBar = { AddBar(model, s, online) },
            snackbarHost = { SnackbarHost(toaster.host) },
        ) { padding ->
            Box(Modifier.padding(padding).fillMaxSize()) {
                QueueBody(model, s, online)
            }
        }
    }
    model.confirming?.let { ask ->
        AlertDialog(
            onDismissRequest = { model.answer(false) },
            title = { Text(ask.title) },
            text = { Text(ask.body) },
            dismissButton = { TextButton(onClick = { model.answer(false) }, Modifier.tag("confirm-cancel")) { Text("Cancel") } },
            confirmButton = {
                TextButton(onClick = { model.answer(true) }, Modifier.tag("confirm-ok")) {
                    Text(ask.action, color = MaterialTheme.colorScheme.error)
                }
            },
        )
    }
}

/** A question the page asks before something that can't be undone. */
private class Ask(val title: String, val body: String, val action: String, val answer: CompletableDeferred<Boolean>)

/** One that just left the queue for the agent, shown as Sent for a moment. */
@Stable
private class Sent(val item: LiveQueued) {
    var leaving by mutableStateOf(false)
}

/** The queue page's state and what it does: kept per page, on the page's [scope]. */
@Stable
private class QueueModel(
    val remote: TerminalRemote,
    val session: String,
    val scope: CoroutineScope,
    val toaster: Toaster,
    val haptics: Haptics,
) {
    val view = QueueView()
    var pausing by mutableStateOf(false)

    /** The one being edited in place, and its text. */
    var editing by mutableStateOf<String?>(null)
    var editText by mutableStateOf("")

    /** Text saved here, by id, until the computer's queue has it. */
    val edited = mutableStateMapOf<String, String>()

    /** Long ones shown whole. */
    val open = mutableStateMapOf<String, Boolean>()

    /** Deleted from here: they leave, but weren't sent. */
    private val deleted = mutableSetOf<String>()

    /** Sent now from here. */
    private val sentNow = mutableSetOf<String>()
    val sent = mutableStateListOf<Sent>()
    private var last: List<LiveQueued> = summary?.queue ?: emptyList()

    var addText by mutableStateOf("")
    var adding by mutableStateOf(false)

    /** The prompt just added, until the list has scrolled to it (it goes at the end, as the computer lists it). */
    var added by mutableStateOf<String?>(null)

    var confirming by mutableStateOf<Ask?>(null)
        private set

    val summary: LiveSummary? get() = remote.session(session)

    /**
     * The computer's queue changed: the next one leaving it from the front went to the agent (so did one
     * sent now from here); one deleted here just goes.
     */
    val listener: () -> Unit = {
        val queue = summary?.queue ?: emptyList()
        val ids = queue.map { it.id }.toSet()
        last.forEachIndexed { i, q ->
            if (q.id !in ids && q.id !in deleted && (i == 0 || q.id in sentNow)) showSent(q)
        }
        deleted.retainAll(ids)
        sentNow.retainAll(ids)
        val byId = queue.associateBy { it.id }
        edited.keys.toList().forEach { id -> if (byId[id] == null || byId[id]!!.text == edited[id]) edited.remove(id) }
        if (editing != null && editing !in ids) editing = null
        last = queue
    }

    private fun showSent(q: LiveQueued) {
        val s = Sent(q)
        sent.add(s)
        scope.launch {
            delay(SENT_FOR_MS)
            s.leaving = true
            delay(400)
            sent.remove(s)
        }
    }

    fun say(text: String, action: String? = null, onAction: (() -> Unit)? = null) = toaster.show(text, action, onAction = onAction)

    suspend fun confirm(title: String, body: String, action: String): Boolean {
        val wait = CompletableDeferred<Boolean>()
        confirming = Ask(title, body, action, wait)
        return wait.await()
    }

    fun answer(yes: Boolean) {
        val ask = confirming ?: return
        confirming = null
        ask.answer.complete(yes)
    }

    /** Takes [id] out of the list at once, back if [request] fails; whether it went. */
    suspend fun drop(id: String, request: suspend () -> Unit): Boolean {
        view.hide(id)
        return attempt { request() }.fold(
            onSuccess = { true },
            onFailure = {
                view.unhide(id)
                say(problemText(it))
                false
            },
        )
    }

    suspend fun move(id: String, to: Int) {
        attempt { remote.moveQueued(session, id, to) }.onFailure {
            view.forgetOrder()
            say(problemText(it))
        }
    }

    /**
     * Whether [q] can go into the queue again from here (a copy, an undo): only its text can be sent
     * again, it isn't a command (those are typed into the agent at once), and only a working agent queues it.
     */
    fun requeueable(q: LiveQueued): Boolean {
        val s = summary
        val text = q.text.trim()
        return q.images == 0 && q.files.isEmpty() && !q.cut && text.isNotEmpty() && !text.startsWith("/") &&
            s != null && (s.busy || s.ask != null)
    }

    /** Queues [text] again, at place [at]: a copy, or one deleted coming back. */
    suspend fun requeue(text: String, at: Int) {
        val s = summary
        if (s == null || !(s.busy || s.ask != null)) {
            return say("The run has ended, so it can't wait in the queue. Send it from the chat.")
        }
        attempt {
            val id = remote.prompt(session, text, followUp = true)
            if (id == null) say("The run had ended: it went to the agent.") else remote.moveQueued(session, id, at)
        }.onFailure { say(problemText(it)) }
    }

    /** Asks first when [q] can't come back: its images and files went to the computer once. */
    suspend fun sureToDelete(q: LiveQueued): Boolean =
        requeueable(q) || confirm("Delete this prompt?", "It never goes to the agent, and it can’t be undone.", "Delete")

    suspend fun delete(q: LiveQueued, at: Int, asked: Boolean = false) {
        if (!asked && !sureToDelete(q)) return
        val undo = requeueable(q)
        deleted.add(q.id)
        if (!drop(q.id) { remote.removeQueued(session, q.id) }) {
            deleted.remove(q.id)
            return
        }
        if (undo) say("Deleted", "Undo") { scope.launch { requeue(q.text, at) } }
    }

    suspend fun clear(shown: List<LiveQueued>) {
        val n = shown.size
        val sure = confirm(
            "Clear the queue?",
            if (n == 1) "The prompt never goes to the agent." else "All $n prompts are deleted; none of them go.",
            "Clear all",
        )
        if (!sure) return
        deleted.addAll(shown.map { it.id })
        coroutineScope { shown.map { q -> async { drop(q.id) { remote.removeQueued(session, q.id) } } }.awaitAll() }
    }

    suspend fun pause(paused: Boolean) {
        pausing = true
        attempt { remote.pauseQueue(session, paused) }.onFailure { say(problemText(it)) }
        pausing = false
    }

    fun startEdit(q: LiveQueued) {
        editing = q.id
        editText = edited[q.id] ?: q.text
    }

    suspend fun save(q: LiveQueued) {
        val text = editText.trim()
        editing = null
        if (text == (edited[q.id] ?: q.text)) return
        edited[q.id] = text
        attempt { remote.editQueued(session, q.id, text) }.onFailure {
            edited.remove(q.id)
            say(problemText(it))
        }
    }

    suspend fun addPrompt() {
        val text = addText.trim()
        if (text.isEmpty()) return
        if (text.startsWith("/")) return say("Commands can’t wait in the queue. Send them from the chat.")
        adding = true
        attempt { remote.prompt(session, text, followUp = true) }
            .onSuccess { id ->
                // Typed on meanwhile (the field stays open): that's the next one, kept.
                if (addText.trim() == text) addText = ""
                if (id != null) added = id
                if (id == null) say("The run had ended: it went to the agent.")
            }
            .onFailure { say(problemText(it)) }
        adding = false
    }

    fun act(what: String, q: LiveQueued, all: List<LiveQueued>) {
        val at = all.indexOf(q)
        when (what) {
            "edit" -> startEdit(q)
            "send" -> {
                sentNow.add(q.id)
                scope.launch { drop(q.id) { remote.sendQueuedNow(session, q.id) } }
            }
            "top" -> {
                view.put(all, q.id, 0)
                scope.launch { move(q.id, 0) }
            }
            "bottom" -> {
                view.put(all, q.id, all.size - 1)
                scope.launch { move(q.id, all.size - 1) }
            }
            "copy" -> scope.launch { requeue(q.text, at + 1) }
            "delete" -> scope.launch { delete(q, at) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun QueueBody(model: QueueModel, s: LiveSummary?, online: Boolean) {
    val remote = model.remote
    val (all, shown) = model.view.items(s?.queue ?: emptyList())
    val paused = s?.paused ?: false
    val steers = s?.agent?.steers ?: false
    val status = LocalStatus.current
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val (state, stateColor) = when {
        s == null -> "Ended" to dim
        paused -> "Paused" to status.needs
        s.busy -> "Working" to status.working
        s.ask != null -> "Waiting for you" to status.needs
        else -> "Idle" to dim
    }
    val note = when {
        s == null -> "The session has ended."
        !remote.online -> "Offline: you can look, but not change it."
        paused && !s.busy -> "Nothing goes until you resume."
        else -> null
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            FlowRow(
                Modifier.weight(1f),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                itemVerticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Queued · ${shown.size}",
                    style = MaterialTheme.typography.labelLarge,
                    color = dim,
                    modifier = Modifier.tag("queue-count"),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(7.dp).background(stateColor, CircleShape))
                    Spacer(Modifier.width(6.dp))
                    Text(state, style = MaterialTheme.typography.labelLarge, color = stateColor, modifier = Modifier.tag("queue-state"))
                }
            }
            if (shown.isNotEmpty()) {
                IconButton(
                    onClick = { model.scope.launch { model.clear(shown) } },
                    enabled = online,
                    modifier = Modifier.tag("queue-clear"),
                ) {
                    Icon(
                        Icons.Outlined.DeleteSweep,
                        contentDescription = "Clear all",
                        tint = if (online) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.outline,
                    )
                }
            }
            if (shown.isNotEmpty() || paused) {
                TextButton(
                    onClick = { model.scope.launch { model.pause(!paused) } },
                    enabled = online && !model.pausing,
                    modifier = Modifier.tag(if (paused) "queue-screen-resume" else "queue-screen-pause"),
                ) { Text(if (paused) "Resume" else "Pause") }
            }
        }
        AnimatedVisibility(note != null, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
            Row(Modifier.padding(start = 20.dp, end = 20.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                if (!remote.online) {
                    Icon(Icons.Outlined.CloudOff, contentDescription = null, tint = dim, modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(6.dp))
                }
                Text(note ?: "", style = MaterialTheme.typography.bodySmall, color = dim)
            }
        }
        HorizontalDivider()
        if (shown.isEmpty() && model.sent.isEmpty()) {
            Empty()
        } else {
            QueueList(model, all, shown, online = online, steers = steers)
        }
    }
}

@Composable
private fun Empty() {
    Box(Modifier.fillMaxSize().tag("queue-empty"), contentAlignment = Alignment.Center) {
        Column(Modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Outlined.Inbox, contentDescription = null, tint = MaterialTheme.colorScheme.outline, modifier = Modifier.size(40.dp))
            Spacer(Modifier.padding(top = 12.dp))
            Text("Nothing queued", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.padding(top = 4.dp))
            Text(
                "Prompts you queue while the agent works wait here.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun QueueList(model: QueueModel, all: List<LiveQueued>, shown: List<LiveQueued>, online: Boolean, steers: Boolean) {
    val listState = rememberLazyListState()
    val reorder = remember(listState) { Reorder(listState) }
    // A prompt added goes at the end: shown there once the computer lists it.
    LaunchedEffect(model.added, shown) {
        val at = shown.indexOfFirst { it.id == model.added }
        if (at < 0) return@LaunchedEffect
        // After the Sent rows above the queue. Cleared only once there: clearing restarts this effect.
        listState.animateScrollToItem(model.sent.size + at)
        model.added = null
    }
    reorder.ids = shown.map { it.id }
    reorder.onLift = { model.haptics.picked() }
    reorder.onMove = { from, to ->
        val id = shown[from].id
        val at = model.view.drop(all, shown, from, to)
        model.scope.launch { model.move(id, at) }
    }
    val rows = reorder.arrange(shown) { it.id }
    LazyColumn(
        Modifier.fillMaxSize().tag("queue-list"),
        state = listState,
        contentPadding = PaddingValues(bottom = 12.dp),
    ) {
        items(model.sent, key = { "sent-${it.item.id}" }) { sent ->
            AnimatedVisibility(!sent.leaving, enter = fadeIn(), exit = shrinkVertically() + fadeOut()) {
                SentRow(sent.item)
            }
        }
        items(rows, key = { it.id }) { q ->
            val index = rows.indexOf(q)
            QueueRow(
                model,
                q,
                index,
                all,
                online = online,
                steers = steers,
                last = index == rows.size - 1,
                reorder = reorder,
                modifier = Modifier
                    .reorderable(reorder, q.id)
                    .animateItem(placementSpec = if (reorder.dragged == q.id) null else androidx.compose.animation.core.spring()),
            )
        }
    }
}

@Composable
private fun SentRow(q: LiveQueued) {
    val ok = LocalStatus.current.done
    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp).tag("queue-sent-${q.id}"), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.Check, contentDescription = null, tint = ok, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text("Sent", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = ok)
        Spacer(Modifier.width(10.dp))
        Text(q.text, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QueueRow(
    model: QueueModel,
    q: LiveQueued,
    index: Int,
    all: List<LiveQueued>,
    online: Boolean,
    steers: Boolean,
    last: Boolean,
    reorder: Reorder,
    modifier: Modifier,
) {
    val editing = model.editing == q.id
    val extras = queuedExtras(q)
    val at = all.indexOf(q)
    val dismiss = rememberSwipeToDismissBoxState()
    val rowScope = rememberCoroutineScope()
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val off = MaterialTheme.colorScheme.outline
    SwipeToDismissBox(
        state = dismiss,
        modifier = modifier.tag("queue-item-${q.id}"),
        enableDismissFromStartToEnd = false,
        gesturesEnabled = online && !editing,
        onDismiss = { value ->
            rowScope.launch {
                if (value != SwipeToDismissBoxValue.EndToStart || !model.sureToDelete(q)) {
                    dismiss.reset()
                } else {
                    // On the page's scope: the row leaves the list as it goes.
                    model.scope.launch { model.delete(q, at, asked = true) }
                }
            }
        },
        backgroundContent = {
            Box(
                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.errorContainer).padding(end = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) { Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer) }
        },
    ) {
        Surface(
            color = if (editing) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surface,
            modifier = Modifier
                .fillMaxWidth()
                .longPressDrag(reorder, q.id, online && !editing)
                .clickable(enabled = online && !editing && !q.cut) { model.startEdit(q) },
        ) {
            Column {
                Row(Modifier.padding(start = 16.dp, top = 10.dp, end = 4.dp, bottom = 10.dp)) {
                    Text(
                        "${index + 1}",
                        style = MaterialTheme.typography.labelLarge.copy(fontFeatureSettings = "tnum"),
                        color = dim,
                        modifier = Modifier.width(28.dp).padding(top = 1.dp),
                    )
                    Column(Modifier.weight(1f).animateContentSize()) {
                        if (editing) Editor(model, q) else QueuedText(model, q)
                        if (extras.isNotEmpty()) {
                            Text(extras, style = MaterialTheme.typography.bodySmall, color = dim, modifier = Modifier.padding(top = 4.dp))
                        }
                        if (q.cut) {
                            Text("Too long to show whole here.", style = MaterialTheme.typography.bodySmall, color = off, modifier = Modifier.padding(top = 4.dp))
                        }
                    }
                    if (!editing) {
                        RowMenu(model, q, all, at, online = online, steers = steers)
                        Box(
                            Modifier.size(40.dp).dragHandle(reorder, q.id, online),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Filled.DragHandle, contentDescription = "Drag to reorder", tint = if (online) dim else off, modifier = Modifier.size(20.dp))
                        }
                    }
                }
                if (!last) HorizontalDivider(thickness = 0.5.dp)
            }
        }
    }
}

@Composable
private fun RowMenu(model: QueueModel, q: LiveQueued, all: List<LiveQueued>, at: Int, online: Boolean, steers: Boolean) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }, enabled = online, modifier = Modifier.tag("queue-menu-${q.id}")) {
            Icon(Icons.Filled.MoreVert, contentDescription = "More")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val pick: (String) -> Unit = { what ->
                open = false
                model.act(what, q, all)
            }
            if (!q.cut) MenuRow("Edit", Icons.Outlined.Edit) { pick("edit") }
            if (steers) MenuRow("Send now", Icons.AutoMirrored.Filled.ArrowForward) { pick("send") }
            if (at > 0) MenuRow("Move to top", Icons.Filled.VerticalAlignTop) { pick("top") }
            if (at < all.size - 1) MenuRow("Move to bottom", Icons.Filled.VerticalAlignBottom) { pick("bottom") }
            if (model.requeueable(q)) MenuRow("Duplicate", Icons.Filled.ContentCopy) { pick("copy") }
            MenuRow("Delete", Icons.Outlined.Delete, MaterialTheme.colorScheme.error) { pick("delete") }
        }
    }
}

/** One action of a row's More menu; [color] for a destructive one. */
@Composable
fun MenuRow(label: String, icon: ImageVector, color: Color = Color.Unspecified, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label, color = color) },
        leadingIcon = {
            Icon(icon, contentDescription = null, tint = if (color == Color.Unspecified) MaterialTheme.colorScheme.onSurfaceVariant else color)
        },
        onClick = onClick,
    )
}

/** [q]'s text, whole once opened when it's long. */
@Composable
private fun QueuedText(model: QueueModel, q: LiveQueued) {
    val text = model.edited[q.id] ?: q.text
    if (text.isEmpty()) {
        Text("(no text)", style = MaterialTheme.typography.bodyLarge, fontStyle = FontStyle.Italic, color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    val open = model.open[q.id] == true
    var long by remember(text) { mutableStateOf(false) }
    Text(
        text,
        style = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp),
        maxLines = if (open) Int.MAX_VALUE else FOLDED_LINES,
        overflow = TextOverflow.Ellipsis,
        onTextLayout = { if (!open) long = it.hasVisualOverflow },
        modifier = Modifier.tag("queue-text-${q.id}"),
    )
    if (long) {
        Text(
            if (open) "Show less" else "Show more",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .tag("queue-more-${q.id}")
                .clickable { if (open) model.open.remove(q.id) else model.open[q.id] = true }
                .padding(top = 4.dp, bottom = 2.dp),
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Editor(model: QueueModel, q: LiveQueued) {
    val canSave = model.editText.trim().isNotEmpty() || q.images > 0 || q.files.isNotEmpty()
    val focus = remember { FocusRequester() }
    // The cursor starts at the end, ready to add to the prompt (a plain String field would start it at the front).
    var value by remember(q.id) { mutableStateOf(TextFieldValue(model.editText, TextRange(model.editText.length))) }
    val reveal = remember { BringIntoViewRequester() }
    // The keyboard came up or grew: the one being edited stays in view, Save and Cancel too.
    val ime = WindowInsets.ime.getBottom(LocalDensity.current)
    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(ime) {
        delay(50)
        reveal.bringIntoView()
    }
    Column(Modifier.bringIntoViewRequester(reveal)) {
        OutlinedTextField(
            value = value,
            onValueChange = {
                value = it
                model.editText = it.text
            },
            label = { Text("Prompt") },
            minLines = 2,
            maxLines = 12,
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            modifier = Modifier.fillMaxWidth().focusRequester(focus).tag("queue-edit-field"),
        )
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = { model.editing = null }, modifier = Modifier.tag("queue-edit-cancel")) { Text("Cancel") }
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = { model.scope.launch { model.save(q) } },
                enabled = canSave,
                modifier = Modifier.tag("queue-edit-save"),
            ) { Text("Save") }
        }
    }
}

/** A prompt to add at the end of the queue: only while the agent works, else it would go at once. */
@Composable
private fun AddBar(model: QueueModel, s: LiveSummary?, online: Boolean) {
    val open = online && s != null && (s.busy || s.ask != null)
    val ready = open && !model.adding && model.addText.trim().isNotEmpty()
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Row(
            Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime))
                .padding(start = 12.dp, top = 8.dp, end = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            OutlinedTextField(
                value = model.addText,
                onValueChange = { model.addText = it },
                // Not disabled while one is on its way: a disabled field drops focus, and the keyboard with it, so
                // the next prompt couldn't follow at once (only the button waits).
                enabled = open,
                placeholder = { Text(if (open) "Add to the queue" else "Adds while the agent works") },
                minLines = 1,
                maxLines = 5,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier.weight(1f).tag("queue-add-field"),
            )
            Spacer(Modifier.width(4.dp))
            FilledTonalIconButton(
                onClick = { model.scope.launch { model.addPrompt() } },
                enabled = ready,
                modifier = Modifier.padding(bottom = 4.dp).tag("queue-add"),
            ) { Icon(Icons.Filled.ArrowUpward, contentDescription = "Add") }
        }
    }
}
