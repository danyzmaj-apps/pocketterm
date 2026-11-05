package com.danyzmaj.pocketterm.demo

import com.danyzmaj.pocketterm.core.Backend
import com.danyzmaj.pocketterm.core.ChannelKey
import com.danyzmaj.pocketterm.core.Desktop
import com.danyzmaj.pocketterm.core.Desktops
import com.danyzmaj.pocketterm.core.ItemKind
import com.danyzmaj.pocketterm.core.LiveItem
import com.danyzmaj.pocketterm.core.MemoryDeviceTokens
import com.danyzmaj.pocketterm.core.PocketTermServerClient
import com.danyzmaj.pocketterm.core.TerminalRemote
import com.danyzmaj.pocketterm.core.ToolStatus
import com.danyzmaj.pocketterm.core.bool
import com.danyzmaj.pocketterm.core.debugPrint
import com.danyzmaj.pocketterm.core.num
import com.danyzmaj.pocketterm.core.str
import com.danyzmaj.pocketterm.core.toJsonElement
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.time.Instant

// "Try the demo": the real app on a made-up computer, answered right here on
// the phone. Two projects with coding sessions (one finished, one waiting for
// an approval, one at work), their conversations and plain terminal windows.
// Nothing goes over the network. The docs' screenshots draw the same data.

const val demoHome = "/Users/demo"
const val demoGarden = "$demoHome/Dev/garden-api"
const val demoSite = "$demoHome/Dev/pocketterm-site"

/** The pretend computer's id and name. */
const val demoDesktopId = "demo0000"
const val demoDesktopName = "MacBook Pro"

/** A window that shows only its screen (omp at work in it, not reporting). */
const val demoScreenOnly = "kitty-1/7"

/** What every op the demo can't pretend says. */
const val demoNoComputer =
    "This is the demo, so there's no computer to do that. Scan your computer's code to use PocketTerm for real."

/** What a plain prompt gets back. */
private const val demoReply =
    "This is the demo: there's no computer behind it, so nothing ran. Scan your computer's code to send prompts for real."

private typealias Fields = Map<String, Any?>

/** The sessions, as the computer sends them in its state; [overrides] by session key. */
private fun demoSessions(now: Long, overrides: Map<String, Fields>): List<Fields> {
    fun ago(minutes: Int): Long = now - minutes * 60_000L
    return listOf(
        linkedMapOf(
            "key" to "kitty-1/3",
            "id" to "s1",
            "agent" to "omp",
            "window" to "kitty-1/3",
            "title" to "Add a soil moisture endpoint",
            "cwd" to demoGarden,
            "model" to "Sonnet 4.5",
            "ctx" to 23,
            "cost" to 1.86,
            "at" to ago(4),
            "epoch" to "e1",
            "seq" to 7,
        ),
        linkedMapOf(
            "key" to "wezterm-2",
            "id" to "s2",
            "agent" to "claude",
            "window" to "wezterm-2",
            "title" to "Fix the pricing table on small screens",
            "cwd" to demoSite,
            "model" to "Opus 4.5",
            "ctx" to 61,
            "cost" to 12.4,
            "ask" to linkedMapOf("kind" to "approval", "id" to "a1", "tool" to "Bash", "summary" to "npm run build"),
            "at" to ago(1),
            "epoch" to "e1",
            "seq" to 4,
        ),
        linkedMapOf(
            "key" to "tmux-%4",
            "id" to "s3",
            "agent" to "omp",
            "window" to "tmux-%4",
            "title" to "Rate-limit the plant search",
            "cwd" to demoGarden,
            "model" to "GPT-5.5",
            "busy" to true,
            "ctx" to 84,
            "cost" to 43.34,
            "at" to ago(0),
            "epoch" to "e1",
            "seq" to 5,
        ),
    ).map { s -> LinkedHashMap<String, Any?>(s).apply { overrides[s["key"] as String]?.let { putAll(it) } } }
}

private fun demoWindow(
    key: String,
    title: String,
    cwd: String,
    program: String,
    app: String,
    osWindow: String,
    tabId: String,
    via: String? = null,
    focused: Boolean = false,
): Fields = linkedMapOf<String, Any?>("key" to key, "title" to title, "cwd" to cwd, "program" to program, "app" to app).apply {
    if (via != null) put("via", via)
    if (focused) put("focused", true)
    put("osWindow", osWindow)
    put("tabId", tabId)
}

/**
 * The computer's state: three coding sessions (finished, needing you, working), a window showing
 * only its screen and three plain terminal windows, in two projects. They sit in three app
 * windows: kitty's with a tab each for garden-api's session, its shell and the screen-only omp;
 * WezTerm's with the site's session; and Ghostty's showing tmux, a tab for garden-api's session at
 * work and one for the site's editor.
 */
fun demoState(now: Long = System.currentTimeMillis(), overrides: Map<String, Fields> = emptyMap()): JsonObject =
    linkedMapOf(
        "windows" to listOf(
            demoWindow("kitty-1/3", "omp", demoGarden, "omp", "kitty", "kitty-1/os1", "kitty-1/t1"),
            demoWindow("wezterm-2", "claude", demoSite, "claude", "wezterm", "wezterm-os1", "wezterm-t1"),
            demoWindow("tmux-%4", "omp", demoGarden, "omp", "tmux", "ghostty-os1", "ghostty-t1", via = "Ghostty"),
            demoWindow("kitty-1/1", "zsh", demoGarden, "zsh", "kitty", "kitty-1/os1", "kitty-1/t2", focused = true),
            demoWindow("tmux-%2", "nvim README.md", demoSite, "nvim", "tmux", "ghostty-os1", "ghostty-t2", via = "Ghostty"),
            demoWindow(demoScreenOnly, "omp", demoGarden, "omp", "kitty", "kitty-1/os1", "kitty-1/t3"),
        ),
        "sessions" to demoSessions(now, overrides),
        "projects" to listOf(demoGarden, demoSite),
        "home" to demoHome,
        "agent" to "omp",
        "agents" to linkedMapOf("omp" to "installed", "claude" to "installed"),
        "opensIn" to "kitty",
        "placement" to "projectWindow",
    ).toJsonElement() as JsonObject

private fun item(order: Int, kind: ItemKind, text: String = "", tool: String = "", title: String = "", output: String = "") =
    LiveItem(
        id = "it$order",
        kind = kind,
        text = text,
        tool = tool,
        title = title,
        output = output,
        status = ToolStatus.ok,
        order = order.toLong(),
        seq = order.toLong(),
    )

/** Each session's conversation, oldest first. */
fun demoTranscripts(): Map<String, List<LiveItem>> = mapOf(
    "kitty-1/3" to listOf(
        item(
            1,
            ItemKind.user,
            text = "Add GET /plants/:id/moisture: the last 24 hours of soil readings, newest first. " +
                "Reuse the sensor repo, and add tests.",
        ),
        item(2, ItemKind.assistant, text = "Let me look at how the readings are stored first."),
        item(3, ItemKind.tool, tool = "read", title = "src/sensors/repo.ts"),
        item(4, ItemKind.tool, tool = "read", title = "src/routes/plants.ts"),
        item(5, ItemKind.tool, tool = "edit", title = "src/routes/plants.ts"),
        item(
            6,
            ItemKind.tool,
            tool = "bash",
            title = "npm test -- moisture",
            output = " PASS  test/moisture.test.ts\n" +
                "  ✓ last 24 h, newest first (18 ms)\n" +
                "  ✓ 404 for an unknown plant (4 ms)\n" +
                "\n" +
                "Tests:  2 passed, 2 total",
        ),
        item(
            7,
            ItemKind.assistant,
            text = "Done. `GET /plants/:id/moisture` now returns the last 24 h of readings:\n\n" +
                "- `SensorRepo.readingsSince()` runs the query, on the `(plant_id, taken_at)` index\n" +
                "- an unknown plant gets a **404**\n" +
                "- `test/moisture.test.ts` covers both\n\n" +
                "Want a `?hours=` parameter as well?",
        ),
    ),
    "wezterm-2" to listOf(
        item(
            1,
            ItemKind.user,
            text = "The pricing table overflows on phones. Stack the plans under 640 px and keep the Pro column highlighted.",
        ),
        item(2, ItemKind.tool, tool = "Read", title = "src/components/Pricing.tsx"),
        item(3, ItemKind.tool, tool = "Edit", title = "src/components/Pricing.tsx"),
        item(
            4,
            ItemKind.assistant,
            text = "The plans now stack below 640 px, Pro first and still highlighted. I want to build the site to check it.",
        ),
    ),
    "tmux-%4" to listOf(
        item(
            1,
            ItemKind.user,
            text = "Rate-limit GET /plants/search to 30 requests a minute per API key, with a Retry-After header.",
        ),
        item(2, ItemKind.tool, tool = "read", title = "src/middleware/auth.ts"),
        item(3, ItemKind.tool, tool = "write", title = "src/middleware/rateLimit.ts"),
        item(4, ItemKind.tool, tool = "edit", title = "src/routes/search.ts"),
        item(5, ItemKind.assistant, text = "The limiter is in place. Running the integration tests now."),
    ),
)

/** What each terminal window shows. */
fun demoScreen(window: String): List<String> = when (window) {
    demoScreenOnly -> listOf(
        " Import the 2026 seed list from suppliers.csv",
        "",
        " I will read the CSV, match each row to a catalog entry and",
        " add the new varieties with their sowing months.",
        "",
        " ╭──────────────────────────────────────────────╮",
        " │ \$ python scripts/import_seeds.py suppliers.csv │",
        " ├─── Output ───────────────────────────────────┤",
        " │ 412 rows read                                │",
        " │ 388 matched, 24 new                          │",
        " ╰──────────────────────────────────────────────╯",
        "",
        " ⠼ 41s > Opus > garden-api",
        "╰─",
    )
    "tmux-%2" -> listOf(
        "# PocketTerm site",
        "",
        "The marketing site, built with Astro.",
        "",
        "## Develop",
        "",
        "    npm install",
        "    npm run dev",
        "~",
        "~",
        "\"README.md\" 9L, 112B",
    )
    else -> listOf(
        "demo@MacBook-Pro garden-api % git status",
        "On branch main",
        "Your branch is up to date with 'origin/main'.",
        "",
        "nothing to commit, working tree clean",
        "demo@MacBook-Pro garden-api % ",
    )
}

/**
 * The demo's computer: its list (one computer) and its remote, answering the app's messages
 * itself. [dispose] when the demo ends. [dir] is its cache, deleted then. Confined to [scope]'s
 * (main) thread, as the remote is.
 */
class DemoComputer(private val dir: File, private val scope: CoroutineScope) {
    private var timer: Job? = null
    private val transcripts: MutableMap<String, MutableList<LiveItem>> =
        demoTranscripts().mapValuesTo(LinkedHashMap()) { it.value.toMutableList() }

    // Prompts waiting for the run at work to end, to look at, change and move in the queue.
    private val overrides: MutableMap<String, Fields> = linkedMapOf(
        "tmux-%4" to linkedMapOf(
            "queue" to listOf(
                linkedMapOf("id" to "dq1", "t" to "Add a test for the 429 answer and its Retry-After header."),
                linkedMapOf(
                    "id" to "dq2",
                    "t" to "Then make the limit configurable per API key, 60 requests a minute by default. Read it from " +
                        "config/limits.yaml, fall back to the default when a key has no entry, and log once at startup " +
                        "which keys have a limit of their own. Keep the middleware small: the lookup goes in a function of " +
                        "its own, so it can be tested without a server running.",
                ),
                linkedMapOf("id" to "dq3", "t" to "This trace is from production: is it the same bug?", "im" to 1),
                linkedMapOf("id" to "dq4", "t" to "Update the limits section of the docs.", "f" to listOf("limits.md")),
            ),
        ),
    )
    private var queued = 4

    /** Never asked anything: the list and the remote are fed here. */
    private val nowhere = PocketTermServerClient(Backend("http://localhost:1"), MemoryDeviceTokens())

    val desktops: Desktops = Desktops(
        nowhere,
        cached = listOf(Desktop(id = demoDesktopId, name = demoDesktopName, platform = "macos", seenAt = Instant.now())),
        saved = demoDesktopId,
    )

    val remote: TerminalRemote = TerminalRemote(
        nowhere,
        dir,
        desktopId = demoDesktopId,
        key = ChannelKey(ByteArray(32) { 7 }),
        scope = scope,
        // Answered after the call that sent it returns, as a computer's answer would come.
        send = { event, payload ->
            scope.launch {
                yield()
                receive(event, payload)
            }
        },
        // Images go nowhere either.
        upload = { _, _ -> },
        from = "demo-phone",
    )

    init {
        sendState()
        // As a computer does: its state keeps coming, so it reads as online.
        timer = scope.launch {
            while (true) {
                delay(4_000)
                sendState()
            }
        }
    }

    private fun sendState() = remote.handle("state", demoState(overrides = overrides))

    private fun sendItems(session: String) {
        val items = transcripts[session] ?: return
        remote.handle(
            "items",
            linkedMapOf(
                "to" to remote.from,
                "session" to session,
                "epoch" to "e1",
                "seq" to items.size,
                "reset" to true,
                "last" to true,
                "older" to false,
                "items" to items.map { it.toJson() },
            ).toJsonElement() as JsonObject,
        )
    }

    private fun receive(event: String, p: JsonObject) {
        if (timer == null) return
        when {
            event == "hello" -> sendState()
            event == "sync" && p["session"].str != null -> sendItems(p["session"].str!!)
            event == "sync" && p["window"].str != null -> {
                val window = p["window"].str!!
                remote.handle("screen", linkedMapOf("window" to window, "v" to 1, "lines" to demoScreen(window)).toJsonElement() as JsonObject)
            }
            event == "run" -> {
                val answer = run(p)
                remote.handle("ran", (linkedMapOf<String, Any?>("id" to p["id"]) + answer).toJsonElement() as JsonObject)
            }
        }
    }

    /** A conversation goes on: [items] added to [session], its summary [summary]. */
    private fun add(session: String, items: List<Pair<ItemKind, String>>, summary: Fields) {
        val list = transcripts.getOrPut(session) { mutableListOf() }
        for ((kind, text) in items) list.add(item(list.size + 1, kind, text = text))
        overrides[session] = LinkedHashMap<String, Any?>().apply {
            overrides[session]?.let { putAll(it) }
            putAll(summary)
            put("seq", list.size)
            put("at", System.currentTimeMillis())
        }
        sendState()
        sendItems(session)
    }

    /** What the computer answers to a `run`: nothing is done, the conversation just goes on as if. */
    private fun run(p: JsonObject): Fields {
        val session = p["session"].str
        val op = p["op"].str
        return when {
            op == "prompt" && session != null && p["deliver"].str == "followUp" && busy(session) -> {
                val id = "dq${++queued}"
                setQueue(session, queue(session) + linkedMapOf<String, Any?>("id" to id, "t" to (p["text"].str ?: "")))
                mapOf("queued" to id)
            }
            op == "queue" && session != null -> changeQueue(session, p)
            op == "prompt" && session != null -> {
                add(session, listOf(ItemKind.user to (p["text"].str ?: ""), ItemKind.assistant to demoReply), mapOf("busy" to false))
                emptyMap()
            }
            op == "answer" && session != null -> {
                val approved = p["approve"].bool == true
                val reply = if (approved) {
                    "Built in 6.2 s. The pricing table stacks on small screens and the Pro plan stays highlighted."
                } else {
                    "Okay, I won't build it. The change is in src/components/Pricing.tsx when you want to check it."
                }
                add(session, listOf(ItemKind.assistant to reply), mapOf("ask" to null, "busy" to false))
                emptyMap()
            }
            op == "probe" -> mapOf("busy" to (p["window"].str == demoScreenOnly))
            op == "older" -> emptyMap()
            else -> mapOf("error" to demoNoComputer)
        }
    }

    private fun busy(session: String): Boolean =
        demoSessions(System.currentTimeMillis(), overrides).any { it["key"] == session && it["busy"] == true }

    @Suppress("UNCHECKED_CAST")
    private fun queue(session: String): MutableList<MutableMap<String, Any?>> =
        ((overrides[session]?.get("queue") as? List<Fields>) ?: emptyList()).mapTo(mutableListOf()) { LinkedHashMap(it) }

    private fun setQueue(session: String, queue: List<Fields>, paused: Boolean? = null) {
        overrides[session] = LinkedHashMap<String, Any?>().apply {
            overrides[session]?.let { putAll(it) }
            put("queue", queue)
            put("paused", queue.isNotEmpty() && (paused ?: (overrides[session]?.get("paused") == true)))
        }
        sendState()
    }

    /** The phone's change to [session]'s queue, as the computer makes it (LiveHub on the desktop). */
    private fun changeQueue(session: String, p: JsonObject): Fields {
        val queue = queue(session)
        val at = queue.indexOfFirst { it["id"] == p["item"].str }
        val what = p["do"].str
        if (at < 0 && what != "pause" && what != "resume") return mapOf("error" to "That prompt has gone to the agent already.")
        when (what) {
            "edit" -> queue[at]["t"] = p["text"].str ?: ""
            "remove" -> queue.removeAt(at)
            "move" -> {
                val q = queue.removeAt(at)
                queue.add((p["to"].num?.toInt() ?: 0).coerceIn(0, queue.size), q)
            }
            "send" -> {
                val q = queue.removeAt(at)
                setQueue(session, queue)
                add(session, listOf(ItemKind.user to (q["t"] as? String ?: "")), emptyMap())
                return emptyMap()
            }
            "pause", "resume" -> {
                setQueue(session, queue, paused = what == "pause")
                return emptyMap()
            }
        }
        setQueue(session, queue)
        return emptyMap()
    }

    fun dispose() {
        timer?.cancel()
        timer = null
        remote.dispose()
        desktops.dispose()
        if (!dir.deleteRecursively()) debugPrint("PocketTerm: demo cache: $dir not deleted")
    }
}
