package com.danyzmaj.pocketterm.ui.queue

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.lazy.LazyListItemInfo
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.zIndex

/**
 * Drag to reorder in a [LazyColumn] whose rows are keyed by their ids: the row lifted follows the
 * finger, the others make room as it passes them, and the move is handed over once, on the drop
 * ([onMove], from its place to where it landed among [ids]). Set [ids], [onMove] and [onLift] each
 * composition.
 */
@Stable
class Reorder(private val list: LazyListState) {
    /** The ids of the rows that move, in the order they show. */
    var ids: List<String> = emptyList()

    var onMove: (from: Int, to: Int) -> Unit = { _, _ -> }

    /** Lifted or dropped: felt as a click. */
    var onLift: () -> Unit = {}

    /** The row being dragged. */
    var dragged: String? by mutableStateOf(null)
        private set

    /** [ids] as they show while one is dragged. */
    private var order: List<String>? by mutableStateOf(null)
    private var from = -1
    private var startTop = 0
    private var delta by mutableFloatStateOf(0f)

    /** [items] in the order they show now (as dragged so far). */
    fun <T> arrange(items: List<T>, id: (T) -> String): List<T> {
        val o = order ?: return items
        val byId = items.associateBy(id)
        return o.mapNotNull { byId[it] } + items.filter { id(it) !in o }
    }

    private fun info(id: String): LazyListItemInfo? = list.layoutInfo.visibleItemsInfo.firstOrNull { it.key == id }

    fun start(id: String) {
        val info = info(id) ?: return
        from = ids.indexOf(id)
        if (from < 0) return
        startTop = info.offset
        delta = 0f
        order = ids
        dragged = id
        onLift()
    }

    fun drag(dy: Float) {
        val id = dragged ?: return
        val o = order ?: return
        delta += dy
        val info = info(id) ?: return
        val top = startTop + delta
        val middle = (top + info.size / 2).toInt()
        val target = list.layoutInfo.visibleItemsInfo.firstOrNull {
            it.key != id && it.key in o && middle in it.offset until it.offset + it.size
        }
        if (target != null) {
            val at = o.indexOf(target.key as String)
            order = o.toMutableList().apply {
                remove(id)
                add(at, id)
            }
        }
        // Held past an edge: the list scrolls on under it.
        val layout = list.layoutInfo
        val end = layout.viewportEndOffset - layout.afterContentPadding
        when {
            top < layout.viewportStartOffset -> list.dispatchRawDelta((top - layout.viewportStartOffset).coerceAtLeast(-24f))
            top + info.size > end -> list.dispatchRawDelta((top + info.size - end).coerceAtMost(24f))
        }
    }

    fun end() {
        val id = dragged ?: return
        val to = order?.indexOf(id) ?: -1
        val was = from
        reset()
        onLift()
        if (was >= 0 && to >= 0 && was != to) onMove(was, to)
    }

    fun cancel() = reset()

    private fun reset() {
        dragged = null
        order = null
        from = -1
        delta = 0f
    }

    /** How far row [id] is drawn from its place: the dragged one sits under the finger. */
    fun offset(id: String): Float {
        if (id != dragged) return 0f
        val info = info(id) ?: return 0f
        return startTop + delta - info.offset
    }
}

/** A row of a [Reorder] list: drawn where it's dragged to, above the others. */
fun Modifier.reorderable(r: Reorder, id: String): Modifier =
    zIndex(if (r.dragged == id) 1f else 0f).graphicsLayer { translationY = r.offset(id) }

/** Dragging this (a handle) moves row [id] at once. */
fun Modifier.dragHandle(r: Reorder, id: String, enabled: Boolean): Modifier = if (!enabled) this else pointerInput(r, id) {
    detectDragGestures(
        onDragStart = { r.start(id) },
        onDrag = { change, d ->
            change.consume()
            r.drag(d.y)
        },
        onDragEnd = { r.end() },
        onDragCancel = { r.cancel() },
    )
}

/** Holding this (the whole row) lifts row [id], then dragging moves it. */
fun Modifier.longPressDrag(r: Reorder, id: String, enabled: Boolean): Modifier = if (!enabled) this else pointerInput(r, id) {
    detectDragGesturesAfterLongPress(
        onDragStart = { r.start(id) },
        onDrag = { change, d ->
            change.consume()
            r.drag(d.y)
        },
        onDragEnd = { r.end() },
        onDragCancel = { r.cancel() },
    )
}
