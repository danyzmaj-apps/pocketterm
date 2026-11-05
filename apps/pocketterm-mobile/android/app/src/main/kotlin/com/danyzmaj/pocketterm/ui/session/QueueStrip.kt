package com.danyzmaj.pocketterm.ui.session

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.danyzmaj.pocketterm.core.LiveQueued
import com.danyzmaj.pocketterm.core.LiveSummary
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.ui.LocalNav
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.queue.MenuRow
import com.danyzmaj.pocketterm.ui.queue.QueueView
import com.danyzmaj.pocketterm.ui.queue.Reorder
import com.danyzmaj.pocketterm.ui.queue.dragHandle
import com.danyzmaj.pocketterm.ui.queue.longPressDrag
import com.danyzmaj.pocketterm.ui.queue.queuedExtras
import com.danyzmaj.pocketterm.ui.queue.reorderable
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import kotlinx.coroutines.launch

/** About one row's height: the list shows three and a half, and scrolls for more. */
private val ROW = 56.dp

/**
 * The prompts waiting on the computer for the run to end, next first, above the composer: each can be
 * edited, moved (held and dragged, or by its handle), sent now (an agent that steers) or deleted (a
 * swipe), and the whole queue paused. A move or a delete shows at once, until the computer's queue
 * says the same. Its header opens the whole queue.
 */
@Composable
fun QueueStrip(remote: TerminalRemote, session: String, summary: LiveSummary?, online: Boolean, steers: Boolean) {
    val view = remember { QueueView() }
    val scope = rememberCoroutineScope()
    val toaster = LocalToaster.current
    val nav = LocalNav.current
    val haptics = rememberHaptics()
    var folded by remember { mutableStateOf(false) }
    var pausing by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<LiveQueued?>(null) }
    val (all, shown) = view.items(summary?.queue ?: emptyList())
    val paused = summary?.paused ?: false
    val listState = rememberLazyListState()
    val reorder = remember(listState) { Reorder(listState) }

    /** Takes [id] out of the list at once, back if [request] fails. */
    fun drop(id: String, request: suspend () -> Unit) {
        view.hide(id)
        scope.launch {
            attempt { request() }.onFailure {
                view.unhide(id)
                toaster.show(problemText(it))
            }
        }
    }

    fun act(what: String, q: LiveQueued) {
        when (what) {
            "edit" -> editing = q
            "send" -> drop(q.id) { remote.sendQueuedNow(session, q.id) }
            "delete" -> drop(q.id) { remote.removeQueued(session, q.id) }
        }
    }

    reorder.ids = shown.map { it.id }
    reorder.onLift = { haptics.picked() }
    reorder.onMove = { from, to ->
        val id = shown[from].id
        val at = view.drop(all, shown, from, to)
        scope.launch {
            attempt { remote.moveQueued(session, id, at) }.onFailure {
                view.forgetOrder()
                toaster.show(problemText(it))
            }
        }
    }

    AnimatedVisibility(shown.isNotEmpty(), enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
        Column(Modifier.fillMaxWidth().padding(start = 4.dp, bottom = 4.dp)) {
            Row(Modifier.fillMaxWidth().tag("queue-strip"), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { folded = !folded }, modifier = Modifier.tag("queue-fold")) {
                    Icon(
                        if (folded) Icons.Filled.ChevronRight else Icons.Filled.ExpandMore,
                        contentDescription = if (folded) "Show the queue" else "Fold the queue",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Row(
                    Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { nav.openQueue(session) }
                        .padding(vertical = 10.dp)
                        .tag("queue-open-header"),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "${if (paused) "Queue paused" else "Queued"} · ${shown.size}",
                        style = MaterialTheme.typography.labelLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = if (paused) LocalStatus.current.needs else MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        Icons.Filled.OpenInFull,
                        contentDescription = "Open the queue",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(14.dp).tag("queue-open"),
                    )
                }
                TextButton(
                    onClick = {
                        pausing = true
                        scope.launch {
                            attempt { remote.pauseQueue(session, !paused) }.onFailure { toaster.show(problemText(it)) }
                            pausing = false
                        }
                    },
                    enabled = online && !pausing,
                    modifier = Modifier.tag(if (paused) "queue-resume" else "queue-pause"),
                ) { Text(if (paused) "Resume" else "Pause") }
            }
            if (paused && !summary.busy) {
                Text(
                    "Nothing goes until you resume.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(start = 22.dp, end = 8.dp, bottom = 4.dp),
                )
            }
            if (!folded) {
                val rows = reorder.arrange(shown) { it.id }
                LazyColumn(Modifier.fillMaxWidth().heightIn(max = ROW * 3.5f), state = listState) {
                    items(rows, key = { it.id }) { q ->
                        StripRow(
                            q,
                            online = online,
                            steers = steers,
                            reorder = reorder,
                            onAct = { act(it, q) },
                            modifier = Modifier
                                .reorderable(reorder, q.id)
                                .animateItem(placementSpec = if (reorder.dragged == q.id) null else androidx.compose.animation.core.spring()),
                        )
                    }
                }
            }
        }
    }

    editing?.let { q ->
        EditQueuedSheet(q, onDismiss = { editing = null }) { text ->
            editing = null
            scope.launch { attempt { remote.editQueued(session, q.id, text) }.onFailure { toaster.show(problemText(it)) } }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StripRow(q: LiveQueued, online: Boolean, steers: Boolean, reorder: Reorder, onAct: (String) -> Unit, modifier: Modifier) {
    val dismiss = rememberSwipeToDismissBoxState()
    val extras = queuedExtras(q)
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val off = MaterialTheme.colorScheme.outline
    var menu by remember { mutableStateOf(false) }
    SwipeToDismissBox(
        state = dismiss,
        modifier = modifier.tag("queued-${q.id}"),
        enableDismissFromStartToEnd = false,
        gesturesEnabled = online,
        onDismiss = { if (it == SwipeToDismissBoxValue.EndToStart) onAct("delete") },
        backgroundContent = {
            Box(
                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.errorContainer).padding(end = 16.dp),
                contentAlignment = Alignment.CenterEnd,
            ) { Icon(Icons.Outlined.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer) }
        },
    ) {
        Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth().longPressDrag(reorder, q.id, online)) {
            Row(Modifier.heightIn(min = ROW - 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(40.dp).dragHandle(reorder, q.id, online), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.DragHandle, contentDescription = "Drag to reorder", tint = if (online) dim else off, modifier = Modifier.size(20.dp))
                }
                Column(Modifier.weight(1f)) {
                    if (q.text.isEmpty()) {
                        Text("(no text)", style = MaterialTheme.typography.bodyMedium, fontStyle = FontStyle.Italic, color = dim)
                    } else {
                        Text(q.text, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    if (extras.isNotEmpty()) {
                        Text(extras, style = MaterialTheme.typography.bodySmall, color = dim, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Box {
                    IconButton(onClick = { menu = true }, enabled = online, modifier = Modifier.tag("queued-menu-${q.id}")) {
                        Icon(Icons.Filled.MoreVert, contentDescription = "More")
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        val pick: (String) -> Unit = {
                            menu = false
                            onAct(it)
                        }
                        if (!q.cut) MenuRow("Edit", Icons.Outlined.Edit) { pick("edit") }
                        if (steers) MenuRow("Send now", Icons.AutoMirrored.Filled.ArrowForward) { pick("send") }
                        MenuRow("Delete", Icons.Outlined.Delete, MaterialTheme.colorScheme.error) { pick("delete") }
                    }
                }
            }
        }
    }
}

/** A queued prompt's text to change. [onSave] gets the new text; empty only when images or files go with it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun EditQueuedSheet(q: LiveQueued, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    // The cursor starts at the end, ready to add to the prompt.
    var value by remember(q.id) { mutableStateOf(TextFieldValue(q.text, TextRange(q.text.length))) }
    val text = value.text
    val canSave = text.trim().isNotEmpty() || q.images > 0 || q.files.isNotEmpty()
    val focus = remember { FocusRequester() }
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    LaunchedEffect(Unit) { focus.requestFocus() }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 8.dp).imePadding()) {
            Text("Edit queued prompt", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text("Prompt") },
                minLines = 3,
                maxLines = 10,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp).focusRequester(focus).tag("queued-edit-field"),
            )
            Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss, modifier = Modifier.tag("queued-edit-cancel")) { Text("Cancel") }
                Spacer(Modifier.width(8.dp))
                Button(onClick = { onSave(text.trim()) }, enabled = canSave, modifier = Modifier.tag("queued-edit-save")) { Text("Save") }
            }
        }
    }
}
