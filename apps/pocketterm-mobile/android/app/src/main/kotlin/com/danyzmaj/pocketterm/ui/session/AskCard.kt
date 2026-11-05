package com.danyzmaj.pocketterm.ui.session

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Button
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.danyzmaj.pocketterm.core.LiveAnswer
import com.danyzmaj.pocketterm.core.LiveAsk
import com.danyzmaj.pocketterm.core.LiveQuestion
import com.danyzmaj.pocketterm.core.MenuItem
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.ui.common.LocalToaster
import com.danyzmaj.pocketterm.ui.common.observe
import com.danyzmaj.pocketterm.ui.common.rememberHaptics
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import com.danyzmaj.pocketterm.ui.theme.MonoFont
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * What the agent asks, answered from the phone: the `ask` tool's questions, an approval, or the plan
 * review at the end of plan mode (its options as the computer read them off the agent's screen; the
 * plan itself is read there). [onScreen] opens the session's screen; null when it has none. Keyed by
 * the ask's id by the caller, so a new ask starts afresh.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AskCard(remote: TerminalRemote, session: String, ask: LiveAsk, onScreen: (() -> Unit)?, maxHeight: Dp, modifier: Modifier = Modifier) {
    remote.observe()
    val toaster = LocalToaster.current
    val haptics = rememberHaptics()
    val scope = rememberCoroutineScope()
    val questions = ask.questions ?: emptyList()
    val picks = remember(ask.id) { questions.map { mutableStateListOf<Int>() } }
    val other = remember(ask.id) { questions.map { mutableStateOf("") } }
    var sending by remember(ask.id) { mutableStateOf(false) }
    // Sent: the card stays until the agent moves on.
    var sent by remember(ask.id) { mutableStateOf(false) }
    // The plan review option being sent.
    var planPick by remember(ask.id) { mutableStateOf<Int?>(null) }
    val agent = (remote.session(session)?.agent ?: remote.agent).label
    val busy = sending || sent
    val online = remote.online
    val needs = LocalStatus.current.needs

    val complete = questions.indices.all { i ->
        val custom = if (other[i].value.trim().isNotEmpty()) 1 else 0
        if (questions[i].multi) picks[i].size + custom > 0 else picks[i].size + custom == 1
    }

    fun answer(approve: Boolean = false, plan: Int? = null) {
        sending = true
        planPick = plan
        scope.launch {
            attempt {
                remote.answer(
                    session,
                    ask,
                    approve = approve,
                    answers = when {
                        plan != null -> listOf(LiveAnswer(picks = listOf(plan)))
                        ask.isApproval -> emptyList()
                        else -> questions.indices.map { i ->
                            LiveAnswer(picks = picks[i].sorted(), custom = other[i].value.trim().ifEmpty { null })
                        }
                    },
                )
            }.onSuccess {
                sent = true
                haptics.done()
            }.onFailure { toaster.show(problemText(it)) }
            sending = false
        }
    }

    val mono = MaterialTheme.typography.bodySmall.copy(fontFamily = MonoFont, fontSize = 12.sp)
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    OutlinedCard(
        modifier = modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp).tag("ask-${ask.id}"),
        colors = CardDefaults.outlinedCardColors(containerColor = needs.copy(alpha = .08f).compositeOver(MaterialTheme.colorScheme.surface)),
        border = BorderStroke(1.dp, needs.copy(alpha = .4f)),
    ) {
        // Of what the keyboard leaves: the composer below stays on screen.
        Column(Modifier.heightIn(max = maxHeight).verticalScroll(rememberScrollState()).padding(start = 16.dp, top = 12.dp, end = 16.dp, bottom = 10.dp)) {
            Text("$agent needs you", style = MaterialTheme.typography.labelMedium, color = needs, modifier = Modifier.padding(bottom = 8.dp))
            when {
                ask.isPlan -> {
                    Text("Plan ready", style = MaterialTheme.typography.titleSmall)
                    if (ask.title.isNotEmpty()) Text(ask.title, style = mono, color = dim, modifier = Modifier.padding(top = 4.dp))
                    if (ask.options.isEmpty()) {
                        Text(
                            if (onScreen == null) "Answer it on the computer: PocketTerm can’t read this terminal." else "$agent is waiting on its screen",
                            style = MaterialTheme.typography.bodyMedium,
                            color = dim,
                            modifier = Modifier.padding(top = 8.dp).tag("plan-waiting"),
                        )
                    }
                    ask.options.forEachIndexed { i, label ->
                        OutlinedButton(
                            onClick = { answer(plan = i) },
                            enabled = !busy && online,
                            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp).tag("plan-$i"),
                        ) {
                            Text(label, modifier = Modifier.weight(1f))
                            if (sending && planPick == i) {
                                Spacer(Modifier.width(8.dp))
                                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                            }
                        }
                    }
                }
                ask.isApproval -> {
                    Text("Approve ${ask.tool}?", style = MaterialTheme.typography.titleSmall)
                    if (ask.summary.isNotEmpty()) Text(ask.summary, style = mono, color = dim, modifier = Modifier.padding(top = 6.dp))
                }
                else -> questions.forEachIndexed { i, q ->
                    if (i > 0) Spacer(Modifier.height(16.dp))
                    Question(i, q, picks[i], other[i].value, enabled = !busy, onOther = { t ->
                        other[i].value = t
                        if (!q.multi && t.trim().isNotEmpty()) picks[i].clear()
                    }, onPick = { o, on ->
                        haptics.picked()
                        if (!q.multi) {
                            picks[i].clear()
                            other[i].value = ""
                        }
                        if (on) picks[i].add(o) else picks[i].remove(o)
                    })
                }
            }
            Spacer(Modifier.height(10.dp))
            // Large text: the buttons go on two lines rather than past the edge.
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val spinner: @Composable () -> Unit = { CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary) }
                when {
                    ask.isPlan -> if (onScreen != null) {
                        TextButton(onClick = onScreen, modifier = Modifier.tag(if (ask.options.isEmpty()) "plan-screen" else "view-plan")) {
                            Icon(Icons.Filled.Terminal, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(if (ask.options.isEmpty()) "Screen" else "View plan")
                        }
                    }
                    ask.isApproval -> {
                        OutlinedButton(onClick = { answer() }, enabled = !busy && online, modifier = Modifier.tag("deny")) { Text("Deny") }
                        Button(onClick = { answer(approve = true) }, enabled = !busy && online, modifier = Modifier.tag("approve")) {
                            if (sending) spinner() else Text("Approve")
                        }
                    }
                    else -> Button(onClick = { answer() }, enabled = !busy && online && complete, modifier = Modifier.tag("answer")) {
                        if (sending) spinner() else Text(if (sent) "Answered" else "Answer")
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Question(
    i: Int,
    q: LiveQuestion,
    picked: List<Int>,
    other: String,
    enabled: Boolean,
    onOther: (String) -> Unit,
    onPick: (Int, Boolean) -> Unit,
) {
    Column {
        if (q.header.isNotEmpty()) {
            Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = RoundedCornerShape(6.dp), modifier = Modifier.padding(bottom = 6.dp)) {
                Text(q.header, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSecondaryContainer, modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp))
            }
        }
        Text(q.question, style = MaterialTheme.typography.bodyLarge)
        if (q.multi) Text("Pick any", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline, modifier = Modifier.padding(top = 2.dp))
        FlowRow(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(0.dp)) {
            q.options.forEachIndexed { o, label ->
                val selected = o in picked
                // A long answer wraps within the row instead of being cut off.
                FilterChip(
                    selected = selected,
                    onClick = { onPick(o, !selected) },
                    enabled = enabled,
                    label = { Text(if (q.recommended == o) "$label ★" else label, modifier = Modifier.padding(vertical = 6.dp)) },
                    leadingIcon = if (q.multi && selected) {
                        { Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(FilterChipDefaults.IconSize)) }
                    } else {
                        null
                    },
                    modifier = Modifier.tag("ask-$i-$o"),
                )
            }
        }
        OutlinedTextField(
            value = other,
            onValueChange = onOther,
            enabled = enabled,
            placeholder = { Text("Other…") },
            textStyle = MaterialTheme.typography.bodyMedium,
            singleLine = false,
            maxLines = 4,
            modifier = Modifier.fillMaxWidth().padding(top = 6.dp).tag("ask-$i-other"),
        )
    }
}

/**
 * A picker a slash command opened in the agent's terminal UI (/resume, /model, /tree …), as the computer
 * read it off the screen: its items to pick from, a search when it has one, Cancel (Esc) and the screen.
 * [window]: the agent's window, for Esc; null when it can't press keys there.
 */
@Composable
fun MenuCard(remote: TerminalRemote, session: String, window: String?, ask: LiveAsk, onScreen: (() -> Unit)?, maxHeight: Dp, modifier: Modifier = Modifier) {
    remote.observe()
    val toaster = LocalToaster.current
    val scope = rememberCoroutineScope()
    var search by remember(ask.id) { mutableStateOf("") }
    var searchSoon by remember { mutableStateOf<Job?>(null) }
    // The item being picked, or -1 for Cancel.
    var busy by remember(ask.id) { mutableStateOf<Int?>(null) }
    // Put away here (no keys to press Esc with); a new picker shows again.
    var hidden by remember(ask.id) { mutableStateOf(false) }
    if (hidden) return
    val enabled = busy == null && remote.online
    // Picking presses keys in the agent's window: with none, only the screen and Hide.
    val picks = enabled && window != null

    fun run(what: Int, action: suspend () -> Unit) {
        busy = what
        scope.launch {
            attempt { action() }.onFailure { toaster.show(problemText(it)) }
            busy = null
        }
    }

    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp),
        modifier = modifier.fillMaxWidth().tag("ask-${ask.id}"),
    ) {
        Column(Modifier.heightIn(max = maxHeight)) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, top = 10.dp, end = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    ask.title.ifEmpty { (remote.session(session)?.agent ?: remote.agent).label },
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f),
                )
                if (onScreen != null) TextButton(onClick = onScreen, modifier = Modifier.tag("menu-screen")) { Text("Screen") }
                if (window != null) {
                    TextButton(onClick = { run(-1) { remote.press(window, "esc") } }, enabled = enabled, modifier = Modifier.tag("menu-cancel")) {
                        if (busy == -1) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp) else Text("Cancel")
                    }
                } else {
                    TextButton(onClick = { hidden = true }, modifier = Modifier.tag("menu-hide")) { Text("Hide") }
                }
            }
            if (window == null) {
                Text(
                    "PocketTerm can’t press keys in this terminal. Pick on the computer.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = dim,
                    modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 6.dp),
                )
            }
            if (ask.filter && window != null) {
                OutlinedTextField(
                    value = search,
                    onValueChange = { text ->
                        search = text
                        // What's typed goes to the picker's search once typing pauses.
                        searchSoon?.cancel()
                        searchSoon = scope.launch {
                            delay(300)
                            attempt { remote.answer(session, ask, answers = listOf(LiveAnswer(custom = text))) }
                                .onFailure { toaster.show(problemText(it)) }
                        }
                    },
                    enabled = remote.online,
                    placeholder = { Text("Search…") },
                    leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
                    modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 6.dp).tag("menu-search"),
                )
            }
            if (ask.items.isEmpty()) {
                Text("Nothing matches.", style = MaterialTheme.typography.bodyMedium, color = dim, modifier = Modifier.padding(start = 16.dp, top = 4.dp, end = 16.dp, bottom = 12.dp))
            } else {
                LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), contentPadding = PaddingValues(start = 8.dp, end = 8.dp, bottom = 8.dp)) {
                    itemsIndexed(ask.items) { i, item ->
                        MenuRowItem(i, item, current = i == ask.selected, busy = busy == i, enabled = picks) {
                            run(i) { remote.answer(session, ask, answers = listOf(LiveAnswer(picks = listOf(i)))) }
                        }
                    }
                }
            }
        }
    }
}

/** One of a picker's rows; the one its cursor is on is tinted and outlined in the accent, so it reads in every theme. */
@Composable
private fun MenuRowItem(i: Int, item: MenuItem, current: Boolean, busy: Boolean, enabled: Boolean, onPick: () -> Unit) {
    val primary = MaterialTheme.colorScheme.primary
    Surface(
        color = if (current) primary.copy(alpha = .16f) else androidx.compose.ui.graphics.Color.Transparent,
        shape = RoundedCornerShape(8.dp),
        border = if (current) BorderStroke(1.dp, primary) else null,
        modifier = Modifier.fillMaxWidth().tag("menu-$i"),
    ) {
        Row(
            Modifier.clickable(enabled = enabled, onClick = onPick).padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(item.label, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                if (item.detail.isNotEmpty()) {
                    Text(item.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            if (busy) {
                Spacer(Modifier.width(8.dp))
                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            }
        }
    }
}
