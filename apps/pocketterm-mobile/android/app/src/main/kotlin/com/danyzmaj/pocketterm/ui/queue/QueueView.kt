package com.danyzmaj.pocketterm.ui.queue

import androidx.compose.runtime.mutableIntStateOf
import com.danyzmaj.pocketterm.core.LiveQueued
import com.danyzmaj.pocketterm.core.LiveSummary

/**
 * A session's queue as the phone shows it: the computer's, with the moves and deletes made here ahead
 * of it until the computer's queue says the same. Reading [items] in a composable recomposes it when
 * a move or a delete is made here.
 */
class QueueView {
    /** The order set here (ids), until the computer's queue has it. */
    private var order: List<String>? = null

    /** Deleted or sent from here, until the computer's queue no longer has them. */
    private val gone = mutableSetOf<String>()

    private val changed = mutableIntStateOf(0)

    /** The computer's [queue] in the order set here, and of those the ones that show. */
    fun items(queue: List<LiveQueued>): Pair<List<LiveQueued>, List<LiveQueued>> {
        changed.intValue
        val ids = queue.map { it.id }
        gone.retainAll(ids.toSet())
        val o = order
        if (o != null && ids.filter { it in o } == o.filter { it in ids }) order = null
        val now = order
        val byId = queue.associateBy { it.id }
        val all = if (now == null) queue else now.mapNotNull { byId[it] } + queue.filter { it.id !in now }
        return all to all.filter { it.id !in gone }
    }

    /** Takes [id] out of what shows, until the computer's queue drops it. */
    fun hide(id: String) {
        gone.add(id)
        changed.intValue++
    }

    /** Shows [id] again: what took it out failed. */
    fun unhide(id: String) {
        gone.remove(id)
        changed.intValue++
    }

    /** Shows [id] at place [to] among [all] from now on; its place. */
    fun put(all: List<LiveQueued>, id: String, to: Int): Int {
        order = all.map { it.id }.toMutableList().apply {
            remove(id)
            add(to, id)
        }
        changed.intValue++
        return to
    }

    /**
     * Shows the one shown at [from] at [to] (its place among [shown] once moved) from now on; its place
     * among [all], those going too: before the one it now sits above, else after the one below.
     */
    fun drop(all: List<LiveQueued>, shown: List<LiveQueued>, from: Int, to: Int): Int {
        val id = shown[from].id
        val seen = shown.map { it.id }.toMutableList().apply {
            removeAt(from)
            add(to, id)
        }
        val o = all.map { it.id }.toMutableList().apply { remove(id) }
        o.add(if (to + 1 < seen.size) o.indexOf(seen[to + 1]) else o.indexOf(seen[to - 1]) + 1, id)
        order = o
        changed.intValue++
        return o.indexOf(id)
    }

    /** The computer's order again: a move it refused. */
    fun forgetOrder() {
        order = null
        changed.intValue++
    }
}

/** A session's name, as its page's title. */
fun sessionTitle(s: LiveSummary): String = s.title.ifEmpty { baseName(s.cwd) }

/** A folder's last part: the project. A Windows computer's paths take `\`. */
private fun baseName(path: String): String = path.split('/', '\\').lastOrNull { it.isNotEmpty() } ?: path

/** What goes along with a queued prompt: "⊕ 2 images · notes.md". */
fun queuedExtras(q: LiveQueued): String =
    (listOfNotNull(if (q.images > 0) "⊕ ${q.images} image${if (q.images == 1) "" else "s"}" else null) + q.files).joinToString(" · ")
