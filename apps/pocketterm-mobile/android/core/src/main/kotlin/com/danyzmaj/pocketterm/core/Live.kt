package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.SecureRandom

// Terminal from the phone, version 2 (port of pocketterm_core/lib/live.dart; the frame list and
// their fields are documented there and in packages/pocketterm_server/PROTOCOL.md). Coding
// sessions travel as structured transcript items the phone lays out itself; terminal windows as
// screens. Each payload goes sealed with the computer's channel key: the server sees only {v, n, c}.

/** A session [key] as pushes and links carry it: with the computer it's on, so a tap on the phone opens it there. */
fun routedKey(desktopId: String, key: String): String = "$desktopId/$key"

/** The computer and the session of a [routedKey]. */
data class RoutedKey(val desktop: String, val key: String)

private val DESKTOP_ID = Regex("^[a-z0-9]{8}\\z")

/** The computer and the session of a [routedKey]; null if [s] isn't one. */
fun splitRoutedKey(s: String): RoutedKey? {
    if (s.length < 10 || s[8] != '/') return null
    val desktop = s.substring(0, 8)
    if (!DESKTOP_ID.containsMatchIn(desktop)) return null
    return RoutedKey(desktop, s.substring(9))
}

/** What a transcript entry is. */
enum class ItemKind { user, assistant, tool, notice }

/** How a tool call went. */
enum class ToolStatus { running, ok, error }

/** One entry of a session's transcript, as the phone draws it. */
class LiveItem(
    val id: String,
    val kind: ItemKind,
    /** user, assistant (Markdown), notice: the text. */
    var text: String = "",
    /** user: how many images came with it. */
    var images: Int = 0,
    /** tool: its name (`bash`, `edit`), what it says it's doing, its arguments in brief, the end of its output, how it went. */
    var tool: String = "",
    var title: String = "",
    var args: String = "",
    var output: String = "",
    var status: ToolStatus = ToolStatus.running,
    /** Its place in the transcript, and the hub's seq of its last change. */
    var order: Long = 0,
    var seq: Long = 0,
) {
    fun toJson(): JsonObject = buildObj {
        put("id", id)
        put("k", kind.name)
        if (text.isNotEmpty()) put("t", text)
        if (images > 0) put("im", images)
        if (kind == ItemKind.tool) {
            put("tl", tool)
            if (title.isNotEmpty()) put("ti", title)
            if (args.isNotEmpty()) put("a", args)
            if (output.isNotEmpty()) put("out", output)
            put("st", status.name)
        }
        put("o", order)
        put("s", seq)
    }

    fun copy(): LiveItem = fromJson(toJson())

    companion object {
        /** Throws when `id` is missing, as Dart's does. */
        fun fromJson(j: JsonObject): LiveItem = LiveItem(
            id = j["id"].str ?: throw IllegalArgumentException("item without id"),
            kind = ItemKind.entries.firstOrNull { it.name == j["k"].str } ?: ItemKind.notice,
            text = j["t"].str ?: "",
            images = j["im"].int ?: 0,
            tool = j["tl"].str ?: "",
            title = j["ti"].str ?: "",
            args = j["a"].str ?: "",
            output = j["out"].str ?: "",
            status = ToolStatus.entries.firstOrNull { it.name == j["st"].str } ?: ToolStatus.ok,
            order = j["o"].long ?: 0,
            seq = j["s"].long ?: 0,
        )
    }
}

/** A prompt waiting in a session's queue on the computer (LiveHub), for a run to end. */
data class LiveQueued(
    val id: String,
    /** What the person typed, without the files' `@path`s. */
    val text: String,
    /** How many images go with it, and the names of its files. */
    val images: Int = 0,
    val files: List<String> = emptyList(),
    /** [text] is only its start: the state was too big for it whole (a session no phone shows). Not to edit. */
    val cut: Boolean = false,
) {
    fun toJson(): JsonObject = buildObj {
        put("id", id)
        if (text.isNotEmpty()) put("t", text)
        if (images > 0) put("im", images)
        if (files.isNotEmpty()) put("f", files)
        if (cut) put("c", true)
    }

    companion object {
        fun fromJson(j: JsonObject): LiveQueued = LiveQueued(
            id = j["id"].str ?: throw IllegalArgumentException("queued prompt without id"),
            text = j["t"].str ?: "",
            images = j["im"].int ?: 0,
            files = j["f"].arr?.mapNotNull { it.str } ?: emptyList(),
            cut = j["c"].bool == true,
        )
    }
}

/** A change to a session's transcript: [item] whole, or [append] added to item [id]'s text. */
class LiveOp private constructor(val seq: Long, val item: LiveItem?, val id: String?, val append: String?) {
    fun toJson(): JsonObject =
        if (item != null) jsonOf("s" to seq, "item" to item.toJson()) else jsonOf("s" to seq, "id" to id, "a" to append)

    companion object {
        fun item(seq: Long, item: LiveItem) = LiveOp(seq, item, null, null)
        fun append(seq: Long, id: String, append: String) = LiveOp(seq, null, id, append)

        fun fromJson(j: JsonObject): LiveOp {
            val seq = j["s"].long ?: throw IllegalArgumentException("op without seq")
            val item = j["item"].obj
            return if (item != null) item(seq, LiveItem.fromJson(item))
            else append(seq, j["id"].str ?: throw IllegalArgumentException("append without id"), j["a"].str ?: throw IllegalArgumentException("append without text"))
        }
    }
}

private val random = SecureRandom()

private fun newEpoch(): String = (0 until 8).joinToString("") { random.nextInt(36).toString(36) }

/**
 * The character of [s] starting at code unit [i]: how many bytes it takes inside a JSON string,
 * UTF-8 encoded (quotes, backslashes and control characters escaped as jsonEncode does), and how
 * many code units it is; packed as bytes * 4 + units.
 */
private fun jsonChar(s: String, i: Int): Int {
    val c = s[i].code
    fun r(bytes: Int, units: Int) = bytes * 4 + units
    if (c == 0x22 || c == 0x5c) return r(2, 1)
    if (c < 0x20) return r(if (c == 0x08 || c == 0x09 || c == 0x0a || c == 0x0c || c == 0x0d) 2 else 6, 1)
    if (c < 0x80) return r(1, 1)
    if (c < 0x800) return r(2, 1)
    if ((c and 0xfc00) == 0xd800 && i + 1 < s.length && (s[i + 1].code and 0xfc00) == 0xdc00) return r(4, 2)
    // A lone surrogate is escaped.
    if ((c and 0xf800) == 0xd800) return r(6, 1)
    return r(3, 1)
}

/** How many bytes [s] takes inside a JSON string, UTF-8 encoded. */
fun jsonBytes(s: String): Int {
    var n = 0
    var i = 0
    while (i < s.length) {
        val c = jsonChar(s, i)
        n += c shr 2
        i += c and 3
    }
    return n
}

/** The start of [s] that takes at most [max] bytes as JSON ([jsonBytes]), never splitting a character. */
private fun headBytes(s: String, max: Int): String {
    var n = 0
    var i = 0
    while (i < s.length) {
        val c = jsonChar(s, i)
        n += c shr 2
        if (n > max) return s.substring(0, i)
        i += c and 3
    }
    return s
}

/** The end of [s] that takes at most [max] bytes as JSON, never splitting a character. */
private fun tailBytes(s: String, max: Int): String {
    var n = 0
    var end = s.length
    while (end > 0) {
        val pair = end >= 2 && (s[end - 1].code and 0xfc00) == 0xdc00 && (s[end - 2].code and 0xfc00) == 0xd800
        val start = if (pair) end - 2 else end - 1
        n += jsonChar(s, start) shr 2
        if (n > max) return s.substring(end)
        end = start
    }
    return s
}

/** How an item's text that was too long for the phone ends. */
const val cutNote = "\n\n… (too long to show here: the rest is on the computer)"

/**
 * The most JSON bytes an item's text takes on the way to the phone, with [cutNote]; its tool
 * output, arguments and title take less. An item then always fits in one message: the server
 * closes a socket on a frame over 256 KiB, and sealing grows a message by a third.
 */
const val maxItemTextBytes = 64 * 1024
internal const val maxOutputBytes = 16 * 1024
internal const val maxArgsBytes = 4 * 1024
internal const val maxTitleBytes = 1024

/** [s] cut to its first [max] bytes, ending with [cutNote]. */
private fun clipText(s: String, max: Int): String =
    if (jsonBytes(s) <= max) s else headBytes(s, max - jsonBytes(cutNote)) + cutNote

/**
 * The Mac's copy of one session's transcript. Every change gets the next [seq]; a phone that has
 * seen up to some seq catches up with [since]. [epoch] changes when the transcript starts over
 * (another session in that omp, the extension reconnected), and a phone then drops what it has.
 * An item too big for one message is cut ([maxItemTextBytes]): its text keeps its start, a
 * tool's output its end.
 */
class LiveLog(snapshot: List<LiveItem>, older: Boolean, val cap: Int = 3000, epoch: String? = null) {
    val epoch: String = epoch ?: newEpoch()
    var seq: Long = 0

    /** The extension has items older than the oldest here. */
    var older: Boolean = older

    private val byId = LinkedHashMap<String, LiveItem>()

    /** Each item's text size as JSON ([jsonBytes]), kept up as text streams in. */
    private val textBytes = HashMap<String, Int>()
    private var next = 0L
    private var min = 0L

    init {
        snapshot.forEach { add(it) }
        trim()
    }

    /** Oldest first. */
    val items: List<LiveItem> get() = byId.values.sortedBy { it.order }

    /** A copy of [item] cut to what fits in a message. */
    private fun fit(item: LiveItem): LiveItem {
        val copy = item.copy().apply {
            text = clipText(item.text, maxItemTextBytes)
            title = clipText(item.title, maxTitleBytes)
            args = clipText(item.args, maxArgsBytes)
        }
        if (jsonBytes(copy.output) > maxOutputBytes) copy.output = "…" + tailBytes(copy.output, maxOutputBytes - 3)
        textBytes[copy.id] = jsonBytes(copy.text)
        return copy
    }

    private fun add(item: LiveItem): LiveItem {
        val old = byId[item.id]
        val copy = fit(item).apply {
            order = old?.order ?: next++
            seq = ++this@LiveLog.seq
        }
        byId[item.id] = copy
        return copy
    }

    /** [item], new or changed. The op carries a snapshot: later appends go in ops of their own. */
    fun upsert(item: LiveItem): LiveOp {
        val copy = add(item)
        trim()
        return LiveOp.item(copy.seq, copy.copy())
    }

    /** Streamed [text] added to [id]; null if there's no such item, or its text was already cut. Text past [maxItemTextBytes] is cut. */
    fun append(id: String, text: String): LiveOp? {
        val item = byId[id]
        val had = textBytes[id] ?: 0
        if (item == null || text.isEmpty() || item.text.endsWith(cutNote)) return null
        var add = text
        var bytes = jsonBytes(text)
        if (had + bytes > maxItemTextBytes) {
            add = headBytes(text, maxOf(0, maxItemTextBytes - had - jsonBytes(cutNote))) + cutNote
            bytes = jsonBytes(add)
        }
        textBytes[id] = had + bytes
        item.text += add
        item.seq = ++seq
        return LiveOp.append(seq, id, add)
    }

    /** Items from before the oldest one here (oldest first), placed above it. The ops come in seq order, newest item first. */
    fun addOlder(items: List<LiveItem>, more: Boolean): List<LiveOp> {
        older = more
        val ops = mutableListOf<LiveOp>()
        for (item in items.asReversed()) {
            if (byId.containsKey(item.id)) continue
            val copy = fit(item).apply {
                order = --min
                seq = ++this@LiveLog.seq
            }
            byId[copy.id] = copy
            ops.add(LiveOp.item(seq, copy.copy()))
        }
        return ops
    }

    /** Items changed after [since], oldest first. */
    fun since(since: Long): List<LiveItem> = items.filter { it.seq > since }

    private fun trim() {
        if (byId.size <= cap) return
        for (i in items.take(byId.size - cap)) {
            byId.remove(i.id)
            textBytes.remove(i.id)
        }
        min = items.first().order
        older = true
    }
}

/**
 * The phone's copy of one session's transcript, kept up with [LiveLog]'s ops and catch-ups, and
 * cached on disk between launches. Like [LiveLog], it keeps at most [cap] items: the oldest go as
 * newer ones come (and [older] turns true, the Mac may still have them).
 */
class LiveView(
    var epoch: String,
    var seq: Long = 0,
    var older: Boolean = false,
    val cap: Int = 3000,
    items: Iterable<LiveItem> = emptyList(),
) {
    private val byId = LinkedHashMap<String, LiveItem>()
    private var sorted: MutableList<LiveItem>? = null

    /** The newest item's order: one past it grows the transcript, one before it is an earlier message paged in (kept, though past [cap]). */
    private var newest: Long? = null

    init {
        items.forEach { put(it) }
        trim()
    }

    private fun put(i: LiveItem) {
        byId[i.id] = i
        val n = newest
        if (n != null && n >= i.order) return
        newest = i.order
    }

    /** Past [cap]: the oldest go. */
    private fun trim() {
        if (byId.size <= cap) return
        val all = items
        for (i in all.take(all.size - cap)) byId.remove(i.id)
        sorted = null
        older = true
    }

    /** Oldest first. */
    val items: List<LiveItem>
        get() = sorted ?: byId.values.sortedBy { it.order }.toMutableList().also { sorted = it }

    /**
     * Applies live ops; false if one is missing or the epoch moved on (catch up with a sync
     * then). Ops already seen are skipped.
     */
    fun apply(epoch: String, ops: List<LiveOp>): Boolean {
        if (epoch != this.epoch) return false
        var grew = false
        for (op in ops) {
            if (op.seq <= seq) continue
            if (op.seq != seq + 1) return false
            val item = op.item
            if (item != null) {
                val old = byId[item.id]
                val n = newest
                if (old == null && (n == null || item.order > n)) grew = true
                put(item)
                // The sorted list holds the old object: swap it in place, or sort again.
                val s = sorted
                val at = if (old == null || old.order != item.order) -1 else s?.indexOfFirst { it === old } ?: -1
                if (at >= 0) s!![at] = item else sorted = null
            } else {
                val target = byId[op.id] ?: return false
                target.text += op.append!!
            }
            seq = op.seq
        }
        if (grew) trim()
        return true
    }

    /** A catch-up from the Mac: [items] changed up to [seq] ([reset]: all of them, in a new [epoch]). [last] is the final chunk of the answer. */
    fun catchUp(epoch: String, seq: Long, reset: Boolean, items: List<LiveItem>, last: Boolean, older: Boolean? = null) {
        if (reset && this.epoch != epoch) {
            this.epoch = epoch
            this.seq = 0
            byId.clear()
            newest = null
        } else if (epoch != this.epoch) {
            return
        }
        items.forEach { put(it) }
        sorted = null
        if (older != null) this.older = older
        trim()
        if (last && seq > this.seq) this.seq = seq
    }

    /** The newest [keep] items, for the disk cache. Dropping older ones makes [older] true: the Mac has them. */
    fun toJson(keep: Int = 600): JsonObject {
        val all = items
        val kept = if (all.size > keep) all.subList(all.size - keep, all.size) else all
        return jsonOf(
            "epoch" to epoch,
            "seq" to seq,
            "older" to (older || kept.size < all.size),
            "items" to kept.map { it.toJson() },
        )
    }

    companion object {
        fun fromJson(j: JsonObject): LiveView = LiveView(
            epoch = j["epoch"].str ?: throw IllegalArgumentException("view without epoch"),
            seq = j["seq"].long ?: throw IllegalArgumentException("view without seq"),
            older = j["older"].bool == true,
            items = (j["items"].arr ?: throw IllegalArgumentException("view without items")).map {
                LiveItem.fromJson(it.obj ?: throw IllegalArgumentException("item not an object"))
            },
        )
    }
}

/** One question the agent asks (omp's `ask` tool, Claude Code's AskUserQuestion). */
data class LiveQuestion(
    val id: String,
    val question: String,
    val options: List<String>,
    val header: String = "",
    val multi: Boolean = false,
    val recommended: Int? = null,
) {
    fun toJson(): JsonObject = buildObj {
        put("id", id)
        put("question", question)
        if (header.isNotEmpty()) put("header", header)
        put("options", options)
        if (multi) put("multi", true)
        if (recommended != null) put("recommended", recommended)
    }

    companion object {
        fun fromJson(j: JsonObject): LiveQuestion = LiveQuestion(
            id = j["id"].str ?: "",
            question = j["question"].str ?: "",
            header = j["header"].str ?: "",
            options = j["options"].arr?.map { dartString(if (it is JsonObject) it["label"] else it) } ?: emptyList(),
            multi = j["multi"].bool == true,
            recommended = j["recommended"].int,
        )
    }
}

/** What an agent waits on the person for. */
enum class AskKind { questions, approval, plan, menu }

/** One row of an agent's picker: its `label`, and what it shows under or beside it (`detail`). */
data class MenuItem(val label: String, val detail: String)

/**
 * The agent is waiting on the person: its questions, approval of [tool] ([summary]: what it
 * would do), its plan review (plan mode's last step) of the plan [title], or a picker a slash
 * command opened (/resume, /model …) titled [title]. A plan's [options], a picker's [items] and
 * the [selected] row of either are read off the agent's screen by the Mac (none when it couldn't
 * read them); a picker with [filter] narrows as you type.
 */
class LiveAsk private constructor(
    /** The tool call it belongs to. */
    val id: String,
    val kind: AskKind,
    val questions: List<LiveQuestion>?,
    val tool: String,
    val summary: String,
    val title: String,
    val options: List<String>,
    val items: List<MenuItem>,
    val selected: Int,
    val filter: Boolean,
) {
    val isApproval: Boolean get() = kind == AskKind.approval
    val isPlan: Boolean get() = kind == AskKind.plan
    val isMenu: Boolean get() = kind == AskKind.menu

    /** What a notification says. */
    val text: String
        get() = when (kind) {
            AskKind.approval -> "Approve $tool${if (summary.isEmpty()) "" else ": $summary"}?"
            AskKind.plan -> "Plan ready: $title"
            AskKind.menu -> title
            AskKind.questions -> questions!!.joinToString("\n") { it.question }
        }

    fun toJson(): JsonObject = when (kind) {
        AskKind.approval -> buildObj {
            put("kind", "approval"); put("id", id); put("tool", tool)
            if (summary.isNotEmpty()) put("summary", summary)
        }
        AskKind.plan -> buildObj {
            put("kind", "plan"); put("id", id); put("title", title)
            if (options.isNotEmpty()) put("options", options)
            if (options.isNotEmpty()) put("selected", selected)
        }
        AskKind.menu -> buildObj {
            put("kind", "menu"); put("id", id); put("title", title)
            put("items", items.map { i -> buildObj { put("label", i.label); if (i.detail.isNotEmpty()) put("detail", i.detail) } })
            put("selected", selected)
            if (filter) put("filter", true)
        }
        AskKind.questions -> jsonOf("kind" to "ask", "id" to id, "questions" to questions!!.map { it.toJson() })
    }

    companion object {
        fun questions(id: String, questions: List<LiveQuestion>) =
            LiveAsk(id, AskKind.questions, questions, "", "", "", emptyList(), emptyList(), 0, false)

        fun approval(id: String, tool: String, summary: String = "") =
            LiveAsk(id, AskKind.approval, null, tool, summary, "", emptyList(), emptyList(), 0, false)

        fun plan(id: String, title: String = "Plan", options: List<String> = emptyList(), selected: Int = 0) =
            LiveAsk(id, AskKind.plan, null, "", "", title, options, emptyList(), selected, false)

        fun menu(id: String, title: String, items: List<MenuItem>, selected: Int = 0, filter: Boolean = false) =
            LiveAsk(id, AskKind.menu, null, "", "", title, emptyList(), items, selected, filter)

        /** Throws when `id` is missing, as Dart's does. */
        fun fromJson(j: JsonObject): LiveAsk {
            val id = j["id"].str ?: throw IllegalArgumentException("ask without id")
            return when (j["kind"].str) {
                "approval" -> approval(id, tool = j["tool"].str ?: "", summary = j["summary"].str ?: "")
                "plan" -> plan(
                    id,
                    title = j["title"].str ?: "Plan",
                    options = j["options"].arr?.map { dartString(it) } ?: emptyList(),
                    selected = j["selected"].int ?: 0,
                )
                "menu" -> menu(
                    id,
                    title = j["title"].str ?: "",
                    items = j["items"].arr?.mapNotNull { it.obj }?.map { i ->
                        MenuItem(label = i["label"]?.takeIf { it !is JsonNull }?.let { dartString(it) } ?: "", detail = i["detail"].str ?: "")
                    } ?: emptyList(),
                    selected = j["selected"].int ?: 0,
                    filter = j["filter"].bool == true,
                )
                else -> questions(id, j["questions"].arr?.mapNotNull { it.obj }?.map { LiveQuestion.fromJson(it) } ?: emptyList())
            }
        }
    }
}

/** The person's answer to one [LiveQuestion]: the options picked (indexes) and/or their own text. */
data class LiveAnswer(val picks: List<Int> = emptyList(), val custom: String? = null) {
    fun toJson(): JsonObject = buildObj {
        put("picks", picks)
        if (custom != null) put("custom", custom)
    }

    companion object {
        fun fromJson(j: JsonObject): LiveAnswer =
            LiveAnswer(picks = j["picks"].arr?.mapNotNull { it.int } ?: emptyList(), custom = j["custom"].str)
    }
}

/** One of an agent's slash commands, without its `/`. */
data class LiveCommand(val name: String, val description: String = "")

/** The extension's `commands` ([{name, description?}]). */
fun liveCommands(json: JsonElement?): List<LiveCommand> =
    json.arr?.mapNotNull { c ->
        val name = c.obj?.get("name").str ?: return@mapNotNull null
        LiveCommand(name, c.obj!!["description"].str ?: "")
    } ?: emptyList()

/**
 * The [commands] the composer offers for [text] (`/` and the start of a name), at most [max]:
 * names that start with what was typed, then names that contain it, each in omp's order. None
 * once there's a space.
 */
fun matchCommands(commands: List<LiveCommand>, text: String, max: Int = 6): List<LiveCommand> {
    if (!text.startsWith("/") || text.any { isDartWhitespace(it) }) return emptyList()
    val q = text.substring(1).lowercase()
    val names = commands.map { it.name.lowercase() }
    val starts = commands.filterIndexed { i, _ -> names[i].startsWith(q) }
    val contains = commands.filterIndexed { i, _ -> !names[i].startsWith(q) && names[i].contains(q) }
    return (starts + contains).take(max)
}

/** A live session in the phone's list. */
data class LiveSummary(
    /**
     * Stable for the agent's process: its terminal window's key (`kitty-<pid>/<id>`,
     * `tmux:default/3` …), or `pid:<pid>` when its window can't be told. What the phone opens
     * and notifications point at.
     */
    val key: String,
    /** The agent's session id (changes on /new, /resume, /clear). */
    val id: String,
    val title: String,
    val cwd: String,
    val epoch: String,
    val seq: Long,
    /** Which coding agent this is. */
    val agent: Agent = Agent.omp,
    /** The omp profile it runs in (`omp --profile`); '' for the default and for Claude Code. */
    val profile: String = "",
    val window: String? = null,
    val model: String = "",
    val busy: Boolean = false,
    val ask: LiveAsk? = null,
    /** How full the context window is, in percent. */
    val ctx: Long? = null,
    /** What the session has spent so far, in US dollars, as its agent tallies it. */
    val cost: Double? = null,
    /** The last answer's first line. */
    val preview: String = "",
    /** The last change, in milliseconds since the epoch. */
    val at: Long? = null,
    val older: Boolean = false,
    /** The agent's slash commands, for the composer. */
    val commands: List<LiveCommand> = emptyList(),
    /** Prompts waiting on the computer for the run to end, next first; [paused] holds them (a stopped run, Pause). */
    val queue: List<LiveQueued> = emptyList(),
    val paused: Boolean = false,
    /** The last run ended in an error (not a stop, and no retry got past it). The next run clears it. */
    val failed: Boolean = false,
    /** Started by PocketTerm as this computer's orchestrator: the phone shows it in its own bar, not in the list. */
    val orchestrator: Boolean = false,
) {
    fun toJson(): JsonObject = buildObj {
        put("key", key)
        put("id", id)
        put("agent", agent.name)
        if (profile.isNotEmpty()) put("profile", profile)
        if (window != null) put("window", window)
        put("title", title)
        put("cwd", cwd)
        if (model.isNotEmpty()) put("model", model)
        if (busy) put("busy", true)
        if (ask != null) put("ask", ask.toJson())
        if (ctx != null) put("ctx", ctx)
        if (cost != null) put("cost", cost)
        if (preview.isNotEmpty()) put("preview", preview)
        if (at != null) put("at", at)
        put("epoch", epoch)
        put("seq", seq)
        if (older) put("older", true)
        if (commands.isNotEmpty()) put("cmds", commands.map { c -> if (c.description.isNotEmpty()) listOf(c.name, c.description) else listOf(c.name) })
        if (queue.isNotEmpty()) put("queue", queue.map { it.toJson() })
        if (paused) put("paused", true)
        if (failed) put("failed", true)
        if (orchestrator) put("orch", true)
    }

    companion object {
        fun fromJson(j: JsonObject): LiveSummary = LiveSummary(
            key = j["key"].str ?: throw IllegalArgumentException("summary without key"),
            id = j["id"].str ?: "",
            agent = Agent.parse(j["agent"]),
            profile = j["profile"].str ?: "",
            window = j["window"].str,
            title = j["title"].str ?: "",
            cwd = j["cwd"].str ?: "",
            model = j["model"].str ?: "",
            busy = j["busy"].bool == true,
            ask = j["ask"].obj?.let { LiveAsk.fromJson(it) },
            // Dart's num.toInt() truncates toward zero.
            ctx = j["ctx"].num?.toLong(),
            cost = j["cost"].num,
            preview = j["preview"].str ?: "",
            at = j["at"].long,
            epoch = j["epoch"].str ?: "",
            seq = j["seq"].long ?: 0,
            older = j["older"].bool == true,
            commands = j["cmds"].arr?.mapNotNull { c ->
                val a = c.arr ?: return@mapNotNull null
                val name = a.firstOrNull().str ?: return@mapNotNull null
                LiveCommand(name, if (a.size > 1) a[1].str ?: "" else "")
            } ?: emptyList(),
            queue = j["queue"].arr?.mapNotNull { q -> q.obj?.takeIf { it["id"].str != null }?.let { LiveQueued.fromJson(it) } } ?: emptyList(),
            paused = j["paused"].bool == true,
            failed = j["failed"].bool == true,
            orchestrator = j["orch"].bool == true,
        )
    }
}

/**
 * How a screen's lines changed: [drop] from the top, the next [keep] unchanged, then [tail] new.
 * Scrolling and a redrawn bottom cost a few lines instead of the whole screen.
 */
data class ScreenDiff(val drop: Int, val keep: Int, val tail: List<String>) {
    /** [a] changed into what [between] was given; null if [a] isn't what this diff was made from (the phone missed a version). */
    fun apply(a: List<String>): List<String>? {
        if (drop + keep > a.size) return null
        return a.subList(drop, drop + keep) + tail
    }

    fun toJson(): JsonObject = jsonOf("drop" to drop, "keep" to keep, "tail" to tail)

    companion object {
        fun fromJson(j: JsonObject): ScreenDiff = ScreenDiff(
            drop = j["drop"].int ?: throw IllegalArgumentException("diff without drop"),
            keep = j["keep"].int ?: throw IllegalArgumentException("diff without keep"),
            tail = (j["tail"].arr ?: throw IllegalArgumentException("diff without tail")).map { it.str ?: throw IllegalArgumentException("tail line not a string") },
        )

        /** From [a] to [b]; null when sending [b] whole is about as cheap. */
        fun between(a: List<String>, b: List<String>): ScreenDiff? {
            if (a.isEmpty() || b.isEmpty()) return null
            var bestDrop = 0
            var bestKeep = 0
            // Where b's first line sits in a: 0 unless lines scrolled off the top.
            var tries = 0
            var d = 0
            while (d < a.size && tries < 8) {
                if (a[d] == b[0]) {
                    tries++
                    var k = 0
                    while (k < b.size && d + k < a.size && a[d + k] == b[k]) k++
                    if (k > bestKeep) {
                        bestKeep = k
                        bestDrop = d
                    }
                }
                d++
            }
            if (bestKeep < b.size / 4) return null
            return ScreenDiff(bestDrop, bestKeep, b.subList(bestKeep, b.size).toList())
        }
    }
}

/**
 * [items] split into lists whose JSON stays under [maxBytes] each: sealed and in base64 a message
 * grows by a third, and the server closes a socket on a frame over 256 KB.
 */
fun chunkJson(items: Iterable<JsonObject>, maxBytes: Int = 40000): List<List<JsonObject>> {
    val out = mutableListOf<List<JsonObject>>()
    var current = mutableListOf<JsonObject>()
    var size = 0
    for (i in items) {
        val n = jsonByteLength(i) + 1
        if (current.isNotEmpty() && size + n > maxBytes) {
            out.add(current)
            current = mutableListOf()
            size = 0
        }
        current.add(i)
        size += n
    }
    if (current.isNotEmpty() || out.isEmpty()) out.add(current)
    return out
}

/** A JSON object built in insertion order. */
private inline fun buildObj(block: LinkedHashMap<String, Any?>.() -> Unit): JsonObject =
    LinkedHashMap<String, Any?>().apply(block).toJsonElement() as JsonObject

/** A JSON value as Dart's string interpolation writes it (`'$o'`): `null`, numbers as decoded, lists and maps in Dart's `toString` form. */
internal fun dartString(e: JsonElement?): String = when (e) {
    null, JsonNull -> "null"
    is JsonPrimitive -> e.content
    is JsonArray -> e.joinToString(", ", "[", "]") { dartString(it) }
    is JsonObject -> e.entries.joinToString(", ", "{", "}") { (k, v) -> "$k: ${dartString(v)}" }
}
