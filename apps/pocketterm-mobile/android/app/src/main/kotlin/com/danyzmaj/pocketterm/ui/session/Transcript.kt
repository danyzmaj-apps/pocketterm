package com.danyzmaj.pocketterm.ui.session

import androidx.compose.animation.Crossfade
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.danyzmaj.pocketterm.core.ChatAttachment
import com.danyzmaj.pocketterm.core.ItemKind
import com.danyzmaj.pocketterm.core.LiveItem
import com.danyzmaj.pocketterm.core.LiveView
import com.danyzmaj.pocketterm.core.ToolStatus
import com.danyzmaj.pocketterm.ui.common.tag
import com.danyzmaj.pocketterm.ui.theme.LocalStatus
import com.danyzmaj.pocketterm.ui.theme.MonoFont

/** A transcript item as it's drawn: a copy, so a change to the live item (an answer streaming in) redraws it. */
@Immutable
data class ItemRow(
    val id: String,
    val kind: ItemKind,
    val text: String,
    val images: Int,
    val tool: String,
    val title: String,
    val args: String,
    val output: String,
    val status: ToolStatus,
)

fun LiveItem.row() = ItemRow(id, kind, text, images, tool, title, args, output, status)

private var outgoingSerial = 0L

/** A prompt sent from the page: shown as the person's message until its item comes back in the transcript, and sent again as it is. */
@Stable
class Outgoing(val text: String, val attachments: List<ChatAttachment>, val followUp: Boolean, transcript: LiveView?) {
    /** Its key in the list. */
    val serial = ++outgoingSerial

    /** On its way to the computer. */
    var sending by mutableStateOf(true)

    /** Why it wasn't sent, when it wasn't. */
    var problem by mutableStateOf<String?>(null)

    /** The id it waits under in the session's queue on the computer, when it went there. */
    var queued by mutableStateOf<String?>(null)

    /** The transcript when it went: the person's items there already aren't this one coming back. */
    val epoch: String? = transcript?.epoch
    val last: Long = transcript?.items?.lastOrNull()?.order ?: -1
    private val seen: Set<String> = transcript?.items?.filter { it.kind == ItemKind.user }?.map { it.id }?.toSet() ?: emptySet()

    /** Whether user item [i] of a transcript in [epoch] came after this went. */
    fun sentBefore(i: LiveItem, epoch: String): Boolean = i.id !in seen && (epoch != this.epoch || i.order > last)
}

/** [s] with its runs of whitespace as single spaces, trimmed: how a prompt and the agent's copy of it compare. */
private fun plain(s: String): String = s.replace(Regex("\\s+"), " ").trim()

/**
 * Which of [outgoing] (oldest first) have come back in transcript [v]: each is the first of the person's
 * items since it went, in order, whose text holds its own (the computer may add to it: files named as @path).
 */
fun cameBack(outgoing: List<Outgoing>, v: LiveView): Set<Outgoing> {
    val items = v.items
    // From just after the oldest went; from the start once the transcript started over.
    var start = 0
    if (outgoing.all { it.epoch == v.epoch }) {
        val last = outgoing.minOf { it.last }
        start = items.size
        while (start > 0 && items[start - 1].order > last) start--
    }
    val back = mutableSetOf<Outgoing>()
    var next = start
    for (o in outgoing) {
        val want = plain(o.text)
        for (j in next until items.size) {
            val i = items[j]
            if (i.kind != ItemKind.user || !o.sentBefore(i, v.epoch) || !plain(i.text).contains(want)) continue
            back.add(o)
            next = j + 1
            break
        }
    }
    return back
}

/**
 * The transcript, newest at the bottom by the composer: laid out from the bottom up, so a short one
 * sits by the composer and what arrives while reading further up doesn't move what's being read.
 */
@Composable
fun TranscriptList(
    list: LazyListState,
    rows: List<ItemRow>,
    outgoing: List<Outgoing>,
    working: Boolean,
    earlier: Boolean,
    loadingOlder: Boolean,
    online: Boolean,
    expanded: Map<String, Boolean>,
    onToggle: (String) -> Unit,
    onOlder: () -> Unit,
    onRetry: (Outgoing) -> Unit,
    modifier: Modifier = Modifier,
) {
    LazyColumn(modifier.fillMaxSize(), state = list, reverseLayout = true) {
        item(key = "end") { Spacer(Modifier.height(12.dp)) }
        if (working) {
            item(key = "working") {
                Row(
                    Modifier.padding(start = 16.dp, top = 8.dp, end = 16.dp, bottom = 4.dp).tag("working").animateItem(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(10.dp))
                    Text("Working…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        // Sent from here, until each comes back in the transcript.
        items(outgoing.asReversed(), key = { "out-${it.serial}" }) { o ->
            OutgoingBubble(o, onRetry = { onRetry(o) }, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp).animateItem())
        }
        items(rows.asReversed(), key = { "item-${it.id}" }, contentType = { it.kind }) { r ->
            Box(Modifier.padding(horizontal = 16.dp, vertical = 6.dp).animateItem()) {
                Item(r, open = expanded[r.id] == true, onToggle = { onToggle(r.id) })
            }
        }
        if (earlier) {
            item(key = "earlier") {
                Box(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 6.dp), contentAlignment = Alignment.Center) {
                    if (loadingOlder) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        TextButton(onClick = onOlder, enabled = online, modifier = Modifier.tag("earlier")) { Text("Earlier messages") }
                    }
                }
            }
        }
    }
}

@Composable
private fun Item(r: ItemRow, open: Boolean, onToggle: () -> Unit) {
    when (r.kind) {
        ItemKind.user -> SelectionContainer { UserBubble(r.text, r.images) }
        ItemKind.assistant -> SelectionContainer { MarkdownText(r.text) }
        ItemKind.tool -> ToolCard(r, open, onToggle)
        ItemKind.notice -> Notice(r.text, open, onToggle)
    }
}

/** A bubble on the right, as the person's own messages are. */
@Composable
private fun Bubble(border: BorderStroke? = null, content: @Composable () -> Unit) {
    val width = with(LocalDensity.current) { LocalWindowInfo.current.containerSize.width.toDp() }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Surface(
            color = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
            shape = RoundedCornerShape(18.dp, 18.dp, 4.dp, 18.dp),
            border = border,
            modifier = Modifier.widthIn(max = width * .82f),
        ) {
            Box(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) { content() }
        }
    }
}

/** The person's prompt in a transcript, with how many images came with it. */
@Composable
fun UserBubble(text: String, images: Int) {
    Bubble {
        Column(horizontalAlignment = Alignment.End) {
            if (text.isNotEmpty()) Text(text, style = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 1.4.em))
            if (images > 0) {
                Text(
                    "⊕ $images image${if (images == 1) "" else "s"}",
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.padding(top = if (text.isEmpty()) 0.dp else 4.dp).alpha(.75f),
                )
            }
        }
    }
}

/**
 * A prompt sent from the page, shown as the person's own until its item comes back: dimmed while it goes
 * or waits in the queue; one that didn't go says why, and a tap sends it again.
 */
@Composable
private fun OutgoingBubble(o: Outgoing, onRetry: () -> Unit, modifier: Modifier) {
    val problem = if (o.sending) null else o.problem
    // Accepted, but waiting for the run to end: stays dimmed until the queue strip or the agent shows it.
    val queued = !o.sending && problem == null && (o.followUp || o.queued != null)
    val dim by animateFloatAsState(if (o.sending || queued) .6f else 1f, label = "outgoing")
    val note = MaterialTheme.typography.labelMedium
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val error = MaterialTheme.colorScheme.error
    Column(
        modifier
            .fillMaxWidth()
            .tag("outgoing")
            .then(if (problem != null) Modifier.clickable(onClick = onRetry) else Modifier),
        horizontalAlignment = Alignment.End,
    ) {
        Box(Modifier.alpha(dim)) {
            Bubble(if (problem != null) BorderStroke(1.dp, error.copy(alpha = .6f)) else null) {
                Column(horizontalAlignment = Alignment.End) {
                    if (o.attachments.isNotEmpty()) AttachmentThumbs(o.attachments, size = 48.dp, end = true)
                    if (o.text.isNotEmpty()) {
                        Text(
                            o.text,
                            style = MaterialTheme.typography.bodyLarge.copy(fontSize = 15.sp, lineHeight = 1.4.em),
                            modifier = Modifier.padding(top = if (o.attachments.isEmpty()) 0.dp else 6.dp),
                        )
                    }
                }
            }
        }
        when {
            o.sending -> Row(Modifier.padding(top = 4.dp, end = 4.dp).tag("outgoing-sending"), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp)
                Spacer(Modifier.width(6.dp))
                Text("Sending…", style = note, color = muted)
            }
            queued -> Text("Queued: goes when the run ends", style = note, color = muted, modifier = Modifier.padding(top = 4.dp, end = 4.dp).tag("outgoing-queued"))
            problem != null -> Column(Modifier.padding(top = 4.dp, end = 4.dp).tag("outgoing-failed"), horizontalAlignment = Alignment.End) {
                Text(problem, style = note, color = muted, textAlign = TextAlign.End, maxLines = 3, overflow = TextOverflow.Ellipsis)
                Text("Not sent. Tap to retry", style = note, color = error)
            }
        }
    }
}

/**
 * The agent's own lines in the transcript ("Interrupted", a finished background job). A short one sits
 * centred; a long one is left-aligned and folded to three lines until tapped.
 */
@Composable
private fun Notice(text: String, open: Boolean, onToggle: () -> Unit) {
    val style = MaterialTheme.typography.bodySmall.copy(lineHeight = 1.4.em)
    val color = MaterialTheme.colorScheme.outline
    if (text.length <= 80 && '\n' !in text) {
        Text(text, style = style, color = color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        return
    }
    val line = MaterialTheme.colorScheme.outlineVariant
    Text(
        text,
        style = style,
        color = color,
        maxLines = if (open) Int.MAX_VALUE else 3,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .drawBehind { drawLine(line, Offset(1.dp.toPx(), 0f), Offset(1.dp.toPx(), size.height), 2.dp.toPx()) }
            .padding(start = 10.dp)
            .animateContentSize(),
    )
}

/** A tool call: its name and what it did, how it went, and (opened) its output. */
@Composable
private fun ToolCard(r: ItemRow, open: Boolean, onToggle: () -> Unit) {
    val what = r.title.ifEmpty { r.args }
    val mono = MaterialTheme.typography.bodySmall.copy(fontFamily = MonoFont, fontSize = 12.sp, lineHeight = 1.35.em)
    val dim = MaterialTheme.colorScheme.onSurfaceVariant
    val turn by animateFloatAsState(if (open) 180f else 0f, label = "chevron")
    ElevatedCard(
        shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.elevatedCardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        modifier = Modifier.fillMaxWidth().animateContentSize(),
    ) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The spinner becomes the check (or the cross) as the tool finishes.
            Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) {
                Crossfade(r.status, label = "tool") { status ->
                    when (status) {
                        ToolStatus.running -> CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp)
                        ToolStatus.ok -> Icon(Icons.Filled.Check, contentDescription = "Done", tint = LocalStatus.current.done, modifier = Modifier.size(14.dp))
                        ToolStatus.error -> Icon(Icons.Filled.Close, contentDescription = "Failed", tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(14.dp))
                    }
                }
            }
            Spacer(Modifier.width(8.dp))
            Text(r.tool, style = mono, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.width(8.dp))
            Text(what, style = mono, color = dim, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ExpandMore, contentDescription = if (open) "Hide output" else "Show output", tint = dim, modifier = Modifier.size(18.dp).rotate(turn))
        }
        if (open) {
            HorizontalDivider()
            if (r.title.isNotEmpty() && r.args.isNotEmpty()) {
                SelectionContainer { Text(r.args, style = mono, color = dim, modifier = Modifier.padding(start = 12.dp, top = 8.dp, end = 12.dp)) }
            }
            SelectionContainer {
                Text(
                    r.output.ifEmpty { if (r.status == ToolStatus.running) "…" else "No output." },
                    style = mono,
                    softWrap = false,
                    modifier = Modifier.horizontalScroll(rememberScrollState()).padding(start = 12.dp, top = 8.dp, end = 12.dp, bottom = 12.dp),
                )
            }
        }
    }
}

/** What the page says while there's no transcript to show, and the screen to open while an agent starts. */
@Composable
fun TranscriptEmpty(text: String, onScreen: (() -> Unit)?) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        // Scrolls when the room is short (keyboard up, landscape, large text).
        Column(Modifier.verticalScroll(rememberScrollState()).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Text(text, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyLarge.copy(lineHeight = 1.5.em))
            if (onScreen != null) {
                Spacer(Modifier.height(12.dp))
                TextButton(onClick = onScreen, modifier = Modifier.tag("open-its-screen")) {
                    Icon(Icons.Filled.Terminal, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Open its screen")
                }
            }
        }
    }
}
