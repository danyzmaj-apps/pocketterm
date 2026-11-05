package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

// The phone side of the terminal protocol (Live.kt): the Mac's coding sessions and terminal
// windows, what the phone watches, and a disk cache so the Terminal tab shows the last known
// state before the Mac answers.

/** How the phone's link to a computer stands. */
enum class TerminalLink {
    /** Joining the topic. */
    connecting,

    /** The server can't be reached (offline, Tailscale off, the server down): trying again. */
    unreachable,

    /** Joined; no answer from the Mac yet. */
    waiting,

    /** The Mac answers. */
    online,

    /** The Mac stopped answering, or never did. */
    offline,
}

/**
 * A terminal window's text as the phone has it: version [v] of its [lines] (ANSI), and how many
 * lines have scrolled off the top since the phone first saw it ([base]), so a view can keep its
 * place while it scrolls.
 */
class TermScreen(val v: Long, val lines: List<String>, val base: Int)

/** What goes out on the topic; tests pass their own. */
typealias TerminalSend = (event: String, payload: JsonObject) -> Unit

/** Where images and files go on their way to the computer (the server's blobs, sealed); tests pass their own. */
typealias ImageUpload = suspend (path: String, sealed: ByteArray) -> Unit

/** A file a prompt takes along, as it is: its name and type go inside the sealed request, its bytes sealed in a blob. */
class PromptFile(val name: String, val mime: String, val bytes: ByteArray)

private class Watch(val session: String? = null, val window: String? = null)

/** No answer from the computer in time: it may have done it all the same. */
private class NoAnswer : TerminalException("The computer did not answer.")

/**
 * The phone side for one computer ([desktopId]): its coding sessions (structured, per [LiveView])
 * and terminal windows (as screens). The channel and the hellos run between [attach] and [detach]:
 * while the app is in front. Everything goes sealed with that computer's [key] (E2e.kt). Its disk
 * cache is `terminal/<desktopId>` in [supportDir]. [send] and [upload], when handed in (tests and
 * the phone's demo, which answer locally), replace the channel and the image upload.
 *
 * Confined to [scope]: call it on the scope's (single-threaded) dispatcher, Main on Android.
 */
class TerminalRemote(
    private val server: Server,
    supportDir: File,
    /** The computer this talks to (Desktops.kt). */
    val desktopId: String,
    /** That computer's channel key, from its QR code. */
    val key: ChannelKey,
    private val scope: CoroutineScope,
    send: TerminalSend? = null,
    upload: ImageUpload? = null,
    from: String? = null,
    /** Milliseconds since epoch; tests run it on virtual time. */
    private val clock: () -> Long = System::currentTimeMillis,
) : ChangeNotifier() {
    private val cacheDir = File(supportDir, "terminal/$desktopId")
    private val transmit: TerminalSend? = send
    private val uploadImage: ImageUpload? = upload

    /** This phone, to the Mac. */
    val from: String = from ?: UUID.randomUUID().toString()

    /** What the phone calls that computer (its name in the list), for "asking MacBook Pro…"; null while not known. */
    var desktopName: String? = null
        set(name) {
            if (name == field) return
            field = name
            notifyListeners()
        }

    /**
     * When that computer last told the server it's there (the computers list's seen_at, every
     * minute while PocketTerm runs there with Terminal from phone on), ms since epoch; null while
     * not known. Not answering and not seen for a while, it's asleep or off rather than just quiet.
     */
    var desktopSeenAt: Long? = null
        set(at) {
            if (at == field) return
            field = at
            notifyListeners()
        }

    private val ch: TerminalChannel by lazy {
        TerminalChannel(
            server,
            desktopId,
            listOf("state", "items", "live", "screen", "ran").associateWith { event -> { p: JsonObject -> receive(event, p) } },
            key = key,
            name = "terminal remote",
            scope = scope,
            onJoined = { joined ->
                // Ops may have gone by while away.
                if (joined) watched()
                notifyListeners()
            },
            onUnreachable = { notifyListeners() },
        )
    }
    private var timer: Job? = null

    /** Debug timing ([timing]): a state came since [attach]; sessions caught up since then. */
    private var stateSinceAttach = false
    private val caughtUp = mutableSetOf<String>()

    /** The server this goes through, as [TerminalLink.unreachable] tells it. */
    val backend: Backend get() = server.backend

    private var openedAt = clock()
    private var heard: Long? = null
    private var users = 0

    var windows: List<TermWindow> = emptyList()
    var sessions: List<LiveSummary> = emptyList()

    /** The computer's orchestrator ([LiveSummary.orchestrator]): the latest one, when several report; null when none. */
    val orchestrator: LiveSummary?
        get() {
            var found: LiveSummary? = null
            for (s in sessions) {
                if (!s.orchestrator) continue
                if (found == null || (s.at ?: 0) > (found.at ?: 0)) found = s
            }
            return found
        }

    var projects: List<String> = emptyList()

    /** The Mac's Project folders, where a new project can be made; null from a Mac that predates them (and can't make one). */
    var roots: List<String>? = null

    /** The Mac's home folder, shown as ~. */
    var home: String = ""

    /** What a new session starts on the Mac (its setting). */
    var agent: Agent = Agent.omp

    /** Where PocketTerm stands in each coding agent found on the computer; empty from a computer that doesn't say. */
    var agents: Map<Agent, AgentIntegration> = emptyMap()

    /** The computer's omp profiles besides the default, sorted; empty from a computer that has none or doesn't say. */
    var profiles: List<String> = emptyList()

    /** Where a session the phone starts opens ("kitty", "Ghostty (in tmux)"); null from a Mac that doesn't say. */
    var opensIn: String? = null

    /** Whether that is a tab in the project's window or a window of its own; null from a Mac that doesn't say. */
    var placement: Placement? = null

    /** The Mac's terminals (installed ones, and tmux) and how each stands; empty from a Mac that doesn't say. */
    var terminals: List<TermStatus> = emptyList()

    /** What the Mac can't do with its terminals, as it says it (none reachable, one not set up …). */
    var error: String? = null

    /** The sessions followed (Android notifications); set by the app (null in tests and wherever there are none). */
    var activities: LiveActivities? = null

    /** When the Mac last sent its state (ms since epoch); [fromCache]: that was before this launch, read from disk. */
    var stateAt: Long? = null
    var fromCache: Boolean = false

    private val views = mutableMapOf<String, LiveView>()

    /** Sessions with no cache file, so [view] doesn't look again. */
    private val uncached = mutableSetOf<String>()

    /** Sessions with a sync out: when it went. */
    private val syncing = mutableMapOf<String, Long>()

    /** Live ops that came while a sync was out, applied after it. */
    private val held = mutableMapOf<String, MutableList<Pair<String, List<LiveOp>>>>()

    /** Watched sessions the state says are ahead: since when. */
    private val behind = mutableMapOf<String, Long>()

    private val screens = mutableMapOf<String, TermScreen>()

    /** Each watched window's colors, as its terminal draws it. */
    val colors: MutableMap<String, TermColors> = mutableMapOf()

    private val watches = mutableListOf<Watch>()
    private val pending = mutableMapOf<String, CompletableDeferred<JsonObject>>()
    private val writes = mutableMapOf<String, Job>()

    init {
        load()
    }

    val link: TerminalLink
        get() {
            // A transport handed in (tests) is always there.
            if (transmit == null && !ch.joined) return if (ch.unreachable) TerminalLink.unreachable else TerminalLink.connecting
            val now = clock()
            val h = heard
            if (h != null && now - h < SILENT_MS) return TerminalLink.online
            if (h == null && now - openedAt < SILENT_MS) return TerminalLink.waiting
            return TerminalLink.offline
        }

    val online: Boolean get() = link == TerminalLink.online

    /**
     * How far the computer's clock is off this phone's while it's too far for anything from it to
     * be taken (more than 5 minutes: both should set the time automatically); null otherwise. Then
     * the computer reads as offline, though it's there.
     */
    val clockOff: Duration? get() = if (transmit == null) ch.clockOff else null

    fun window(key: String): TermWindow? = windows.firstOrNull { it.key == key }

    fun session(key: String): LiveSummary? = sessions.firstOrNull { it.key == key }

    fun screen(window: String): TermScreen? = screens[window]

    /** The session's transcript as far as the phone has it: in memory, else from the disk cache; null if neither has it. */
    fun view(key: String): LiveView? {
        val v = views[key]
        if (v != null || key in uncached) return v
        try {
            val f = sessionFile(key)
            if (f.exists()) {
                val j = jsonDecode(f.readText()) as JsonObject
                return LiveView.fromJson(j).also { views[key] = it }
            }
        } catch (e: Exception) {
            debugPrint("PocketTerm: terminal cache: $e")
        }
        uncached.add(key)
        return null
    }

    /** The session the phone shows, if it shows one. */
    val watchedSession: String? get() = watches.lastOrNull()?.session

    /** The window whose screen the phone shows, if it shows one. */
    val watchedWindow: String? get() = watches.lastOrNull()?.window

    /**
     * Pages call these when they show and the returned function when they go; the newest one open
     * is what the Mac hears about (one at a time), and closing it goes back to the one under it.
     */
    fun watchSession(key: String): () -> Unit = watch(Watch(session = key))

    fun watchWindow(key: String): () -> Unit = watch(Watch(window = key))

    private fun watch(w: Watch): () -> Unit {
        watches.add(w)
        watched()
        return {
            val top = watches.lastOrNull() === w
            watches.removeAll { it === w }
            if (top) watched()
        }
    }

    /** Tells the Mac what's watched now and catches up with it. */
    private fun watched() {
        hello()
        watchedSession?.let { sync(it, force = true) }
        watchedWindow?.let { post("sync", jsonOf("from" to from, "window" to it)) }
    }

    /** The app calls this when it comes to the front and [detach] when it leaves. */
    fun attach() {
        if (users++ > 0) return
        timing("attach")
        stateSinceAttach = false
        caughtUp.clear()
        openedAt = clock()
        if (transmit != null) return
        ch.open()
        timer = scope.launch {
            while (true) {
                delay(HELLO_EVERY)
                hello()
                // A session left behind with no state to come still catches up.
                checkBehind(clock())
                // The link can turn offline without a message.
                notifyListeners()
            }
        }
    }

    fun detach() {
        if (users == 0 || --users > 0) return
        timer?.cancel()
        timer = null
        heard = null
        syncing.clear()
        held.clear()
        behind.clear()
        if (transmit == null) ch.close()
        flush()
    }

    /**
     * Retry: a new connection at once (TerminalChannel.kt), and the computer asked again, given its
     * 10 seconds to answer before it reads as not answering. Only while attached.
     */
    fun reconnect() {
        if (users == 0) return
        openedAt = clock()
        heard = null
        if (transmit == null) ch.reconnect() else hello()
        notifyListeners()
    }

    fun hello() = post(
        "hello",
        jsonOf("from" to from).plusIfNotNull("session", watchedSession).plusIfNotNull("window", watchedWindow),
    )

    private fun receive(event: String, p: JsonObject) {
        try {
            handle(event, p)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: terminal remote: bad $event: $e")
        }
    }

    /** One message from the Mac; also handed in directly by tests and the phone's demo, which answer locally. */
    fun handle(event: String, p: JsonObject) {
        when (event) {
            "state" -> onState(p)
            "items" -> onItems(p)
            "live" -> onLive(p)
            "screen" -> onScreen(p)
            "ran" -> p["id"].str?.let { pending.remove(it) }?.complete(p)
        }
    }

    private fun transmitNow(event: String, payload: JsonObject) {
        val t = transmit
        if (t != null) t(event, payload) else ch.send(event, payload)
    }

    private fun post(event: String, payload: JsonObject) {
        try {
            transmitNow(event, payload)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: terminal: $e")
        }
    }

    /** Asks the Mac for what [key]'s view misses. Unforced, it waits for a sync already out. */
    private fun sync(key: String, force: Boolean = false) {
        val now = clock()
        val out = syncing[key]
        if (!force && out != null && now - out < SYNC_WAIT_MS) return
        syncing[key] = now
        held.remove(key)
        val v = view(key)
        post("sync", jsonOf("from" to from, "session" to key).plusIfNotNull("epoch", v?.epoch).plus("since", v?.seq ?: 0L))
    }

    private fun syncOut(key: String): Boolean {
        val out = syncing[key]
        return out != null && clock() - out < SYNC_WAIT_MS
    }

    private fun applyState(p: JsonObject) {
        windows = p["windows"].arr?.map { TermWindow.fromJson(it as JsonObject) } ?: emptyList()
        sessions = p["sessions"].arr?.map { LiveSummary.fromJson(it as JsonObject) } ?: emptyList()
        projects = p["projects"].arr?.map { it.str!! } ?: projects
        roots = p["roots"].arr?.map { it.str!! }
        home = p["home"].str ?: home
        agent = Agent.parse(p["agent"])
        agents = AgentIntegration.parseAll(p["agents"])
        profiles = p["profiles"].arr?.mapNotNull { x -> x.str?.takeIf { isOmpProfile(it) } } ?: emptyList()
        opensIn = p["opensIn"].str
        placement = Placement.entries.firstOrNull { it.name == p["placement"].str }
        terminals = p["terminals"].arr?.map { TermStatus.fromJson(it as JsonObject) } ?: emptyList()
    }

    private fun onState(p: JsonObject) {
        if (Timing.enabled && !stateSinceAttach) {
            stateSinceAttach = true
            timing("first state")
        }
        val now = clock()
        heard = now
        stateAt = now
        fromCache = false
        applyState(p)
        error = p["error"].str
        checkBehind(now)
        dirty(STATE_KEY)
        notifyListeners()
    }

    /** Syncs the watched session when the state says the Mac has more than live ops brought (a new epoch, or a seq ahead for a while). */
    private fun checkBehind(now: Long) {
        val w = watchedSession
        val s = if (w == null) null else session(w) ?: return
        if (s == null) return
        val v = view(s.key)
        if (v == null || (s.epoch.isNotEmpty() && s.epoch != v.epoch)) {
            sync(s.key)
        } else if (s.seq > v.seq) {
            val since = behind.getOrPut(s.key) { now }
            if (now - since >= BEHIND_WAIT_MS) {
                behind.remove(s.key)
                sync(s.key)
            }
        } else {
            behind.remove(s.key)
        }
    }

    private fun onItems(p: JsonObject) {
        if (p["to"].str != from) return
        heard = clock()
        val key = p["session"].str ?: throw IllegalArgumentException("session")
        val epoch = p["epoch"].str ?: throw IllegalArgumentException("epoch")
        val last = p["last"].bool == true
        val v = view(key) ?: LiveView(epoch = epoch).also { views[key] = it }
        v.catchUp(
            epoch = epoch,
            seq = p["seq"].long ?: throw IllegalArgumentException("seq"),
            reset = p["reset"].bool == true,
            items = p["items"].arr?.map { LiveItem.fromJson(it as JsonObject) } ?: emptyList(),
            last = last,
            older = p["older"].bool,
        )
        if (last && v.epoch == epoch) {
            if (Timing.enabled && key == watchedSession && caughtUp.add(key)) timing("caught up")
            syncing.remove(key)
            behind.remove(key)
            for ((e, ops) in held.remove(key) ?: emptyList()) {
                if (!v.apply(e, ops)) {
                    sync(key)
                    break
                }
            }
        }
        dirty(key)
        notifyListeners()
    }

    private fun onLive(p: JsonObject) {
        heard = clock()
        val key = p["session"].str ?: throw IllegalArgumentException("session")
        val epoch = p["epoch"].str ?: throw IllegalArgumentException("epoch")
        val ops = p["ops"].arr?.map { LiveOp.fromJson(it as JsonObject) } ?: emptyList()
        val isWatched = key == watchedSession
        if (isWatched && syncOut(key)) {
            held.getOrPut(key) { mutableListOf() }.add(epoch to ops)
            return
        }
        // Other phones' sessions too, when this one has them at hand.
        val v = views[key] ?: (if (isWatched) view(key) else null)
        if (v == null) {
            if (isWatched) sync(key)
            return
        }
        if (!v.apply(epoch, ops) && isWatched) sync(key)
        dirty(key)
        notifyListeners()
    }

    private fun onScreen(p: JsonObject) {
        heard = clock()
        val window = p["window"].str ?: throw IllegalArgumentException("window")
        val v = p["v"].long ?: throw IllegalArgumentException("v")
        p["colors"].obj?.let { colors[window] = TermColors.fromJson(it) }
        val old = screens[window]
        val lines = p["lines"].arr?.map { it.str!! }
        val diff = p["diff"].obj?.let { ScreenDiff.fromJson(it) }
        if (lines != null) {
            // How far it scrolled, if it did.
            val drop = if (old == null) 0 else ScreenDiff.between(old.lines, lines)?.drop ?: 0
            screens[window] = TermScreen(v, lines, (old?.base ?: 0) + drop)
        } else if (diff != null) {
            val next = if (old != null && old.v == v - 1) diff.apply(old.lines) else null
            if (next != null) {
                screens[window] = TermScreen(v, next, old!!.base + diff.drop)
            } else if (window == watchedWindow) {
                post("sync", jsonOf("from" to from, "window" to window))
            }
        }
        notifyListeners()
    }

    // ------------------------------------------------------------------ ops

    /** How long a request waits for the computer's answer (a prompt with images three times as long). */
    var answerWait: Duration = 10.seconds

    /**
     * [request]'s answer from the Mac, sending included within [wait] ([answerWait] by default),
     * under [id] (a new one by default). With [onLate], an answer that comes after [wait] (the Mac
     * did it after all) still goes there, for a while.
     */
    private suspend fun run(
        request: JsonObject,
        wait: Duration? = null,
        id: String? = null,
        onLate: ((JsonObject) -> Unit)? = null,
    ): JsonObject {
        if (!online) throw TerminalException("The computer is not answering.")
        val runId = id ?: UUID.randomUUID().toString()
        val done = CompletableDeferred<JsonObject>()
        pending[runId] = done
        var later = false
        val reply: JsonObject
        try {
            reply = withTimeoutOrNull(wait ?: answerWait) {
                transmitNow("run", JsonObject(linkedMapOf<String, JsonElement>("id" to JsonPrimitive(runId)) + request))
                done.await()
            } ?: run {
                if (onLate != null) {
                    later = true
                    scope.launch {
                        try {
                            withTimeoutOrNull(LATE_FOR) { runCatching { done.await() }.getOrNull() }?.let(onLate)
                        } finally {
                            pending.remove(runId)
                        }
                    }
                }
                throw NoAnswer()
            }
        } finally {
            if (!later) pending.remove(runId)
        }
        reply["error"].str?.let { throw TerminalException(it) }
        return reply
    }

    /** Types [text] into [window], then Enter. */
    suspend fun send(window: String, text: String) {
        run(jsonOf("op" to "send", "window" to window, "text" to text))
    }

    /** One of [phoneKeys], where the window's terminal can press keys. */
    suspend fun press(window: String, key: String) {
        run(jsonOf("op" to "key", "window" to window, "key" to key))
    }

    /** Closes [window] on the Mac, with what runs in it. */
    suspend fun close(window: String) {
        run(jsonOf("op" to "close", "window" to window))
    }

    /** Whether the agent in [window] looks at work: its screen changed over two seconds on the computer. */
    suspend fun probe(window: String): Boolean = run(jsonOf("op" to "probe", "window" to window))["busy"].bool == true

    /**
     * Switches [agent] in [window], which shows only as a screen, to reporting its session: omp
     * quits and starts again on the same conversation, Claude Code reloads its plugins. The
     * session shows up in [sessions] once the agent reports.
     */
    suspend fun switchToConversation(window: String, agent: Agent) {
        run(jsonOf("op" to "switch", "window" to window, "agent" to agent.name), wait = answerWait * 2)
    }

    /**
     * A new terminal window in [cwd] (where [opensIn] and [placement] say), running the Mac's coding
     * [agent] if [startAgent], in omp [profile] (one of [profiles]; '' the default).
     */
    suspend fun launch(cwd: String, startAgent: Boolean, profile: String = ""): Opened = open(
        jsonOf("op" to "launch", "cwd" to cwd, "agent" to startAgent)
            .let { if (startAgent && profile.isNotEmpty()) it.plus("profile", profile) else it },
    )

    /** A new folder [name] under [root] (one of [roots]) on the Mac, with a window in it as [launch]. */
    suspend fun create(root: String, name: String, startAgent: Boolean, profile: String = ""): Opened = open(
        jsonOf("op" to "create", "root" to root, "name" to name, "agent" to startAgent)
            .let { if (startAgent && profile.isNotEmpty()) it.plus("profile", profile) else it },
    )

    /** Starts the computer's orchestrator, or finds the one running; its window key. */
    suspend fun startOrchestrator(): String = open(jsonOf("op" to "orchestrator")).window

    /**
     * Runs [request], which opens a window. Starting a terminal app can take a while; a window that
     * opens after the phone stopped waiting is still taken as new ([fresh]).
     */
    private suspend fun open(request: JsonObject): Opened {
        val reply = run(request, wait = answerWait * 2, onLate = { r -> r["window"].str?.let { fresh(it) } })
        val window = reply["window"].str ?: throw IllegalStateException("The computer sent no window.")
        fresh(window)
        return Opened(window, reply["where"].str ?: "")
    }

    /**
     * A window just opened under [window]'s key. A key can come back (tmux numbers panes from %0
     * again once its server restarts, Terminal reuses ttys): what the phone kept for it is an ended
     * session's, and goes.
     */
    private fun fresh(window: String) {
        views.remove(window)
        writes.remove(window)?.cancel()
        try {
            val f = sessionFile(window)
            if (f.exists()) f.delete()
        } catch (e: Exception) {
            debugPrint("PocketTerm: terminal cache: $e")
        }
    }

    /**
     * The last prompt the computer didn't answer (the app went to the background, the network
     * dropped): what it was and the id it went under. The same prompt sent again soon goes under
     * the same id, which the computer answers without running it twice if it got it the first time.
     */
    private data class Unanswered(val what: String, val id: String, val at: Long)

    private var unanswered: Unanswered? = null

    /**
     * Prompts [session] with [text], [images] (image files: PNG, JPEG) and [files] (any file, as it
     * is). Their bytes pass through the server sealed with [key]; a file's name and type go inside
     * the sealed request. While omp works the prompt steers it, or waits for the turn to end if
     * [followUp]; Claude Code always waits. One that waits goes to the session's queue on the
     * computer: the id it waits under there ([LiveSummary.queue]), else null.
     */
    suspend fun prompt(
        session: String,
        text: String,
        images: List<ByteArray> = emptyList(),
        files: List<PromptFile> = emptyList(),
        followUp: Boolean = false,
    ): String? {
        if (!online) throw TerminalException("The computer is not answering.")
        val what = sha1Hex(
            jsonEncode(
                JsonArray(
                    listOf(JsonPrimitive(session), JsonPrimitive(text), JsonPrimitive(followUp)) +
                        images.map { JsonPrimitive(sha1Hex(it)) } +
                        files.map { f -> listOf(f.name, f.mime, sha1Hex(f.bytes)).toJsonElement() },
                ),
            ).toByteArray(Charsets.UTF_8),
        )
        val now = clock()
        val again = unanswered?.takeIf { it.what == what && now - it.at < SAME_FOR_MS }
        val id = again?.id ?: UUID.randomUUID().toString()
        val upload: ImageUpload = uploadImage ?: { path, bytes -> server.putBlob(path, bytes) }
        val paths = mutableListOf<String>()
        val sent = mutableListOf<Map<String, String>>()
        fun forget() {
            for (path in paths + sent.map { it.getValue("path") }) {
                scope.launch {
                    try {
                        server.deleteBlob(path)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        debugPrint("$e")
                    }
                }
            }
        }

        suspend fun sealed(bytes: ByteArray): String {
            val path = server.newBlobPath()
            upload(path, sealBytes(key, bytes, imageAad(path)))
            return path
        }

        try {
            for (bytes in images) paths.add(sealed(bytes))
            for (f in files) sent.add(mapOf("path" to sealed(f.bytes), "name" to f.name, "mime" to f.mime))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            forget()
            throw TerminalException("The ${if (paths.size < images.size) "image" else "file"} didn't upload: $e")
        }
        val bytes = (images + files.map { it.bytes }).sumOf { it.size.toLong() }
        try {
            val request = jsonOf("op" to "prompt", "session" to session, "text" to text, "images" to paths)
                .let { if (sent.isNotEmpty()) it.plus("files", sent.toJsonElement()) else it }
                .plus("deliver", if (followUp) "followUp" else "steer")
            val reply = run(
                request,
                // The computer downloads them first: a second more for each MB.
                wait = if (bytes == 0L) answerWait else answerWait * 3 + (bytes shr 20).seconds,
                id = id,
            )
            unanswered = null
            // The computer had it already, with the images and files sent the first time.
            if (reply["repeat"].bool == true) forget()
            return reply["queued"].str
        } catch (e: TerminalException) {
            unanswered = if (e is NoAnswer) Unanswered(what, id, again?.at ?: now) else null
            // The Mac deletes them once used; unanswered, nobody would.
            forget()
            throw e
        }
    }

    /** Esc: stops what the agent is doing. */
    suspend fun abort(session: String) {
        run(jsonOf("op" to "abort", "session" to session))
    }

    /** Changes [session]'s queue on the computer ([LiveSummary.queue]): [item]'s text to [text]. */
    suspend fun editQueued(session: String, item: String, text: String) = queue(session, "edit", "item" to item, "text" to text)

    /** Takes [item] out of [session]'s queue: it never goes. */
    suspend fun removeQueued(session: String, item: String) = queue(session, "remove", "item" to item)

    /** Moves [item] to place [to] (0: next) in [session]'s queue. */
    suspend fun moveQueued(session: String, item: String, to: Int) = queue(session, "move", "item" to item, "to" to to)

    /** Sends [item] now, out of [session]'s queue: it steers the run (omp). */
    suspend fun sendQueuedNow(session: String, item: String) = queue(session, "send", "item" to item)

    /** Holds [session]'s queue, or lets it go on ([paused] false): the next prompt goes when the run ends, or now if it has ended. */
    suspend fun pauseQueue(session: String, paused: Boolean) = queue(session, if (paused) "pause" else "resume")

    private suspend fun queue(session: String, what: String, vararg args: Pair<String, Any?>) {
        run(jsonOf("op" to "queue", "session" to session, "do" to what, *args))
    }

    /** Answers [ask]: [answers] (one per question), or [approve] an approval. */
    suspend fun answer(session: String, ask: LiveAsk, answers: List<LiveAnswer> = emptyList(), approve: Boolean = false) {
        val request = jsonOf("op" to "answer", "session" to session, "ask" to ask.id)
        run(if (ask.isApproval) request.plus("approve", approve) else request.plus("answers", JsonArray(answers.map { it.toJson() })))
    }

    /** Fetches items before the oldest the Mac has; they arrive as live ops. */
    suspend fun older(session: String) {
        run(jsonOf("op" to "older", "session" to session))
    }

    // ---------------------------------------------------------------- cache

    private val stateFile: File get() = File(cacheDir, "state.json")
    private val sessionDir: File get() = File(cacheDir, "sessions")
    private fun sessionFile(key: String): File = File(sessionDir, "${sha1Hex(key.toByteArray(Charsets.UTF_8))}.json")

    private fun load() {
        try {
            val f = stateFile
            if (f.exists()) {
                val j = jsonDecode(f.readText()) as JsonObject
                applyState(j)
                stateAt = j["at"].long
                fromCache = true
            }
        } catch (e: Exception) {
            debugPrint("PocketTerm: terminal cache: $e")
        }
        try {
            val dir = sessionDir
            if (!dir.isDirectory) return
            val now = clock()
            for (f in dir.listFiles().orEmpty()) {
                if (f.isFile && (now - f.lastModified()).milliseconds > KEEP_FOR) f.delete()
            }
        } catch (e: Exception) {
            debugPrint("PocketTerm: terminal cache: $e")
        }
    }

    /** Writes [key]'s file (a session, or the state) soon, at most every 2 s. */
    private fun dirty(key: String) {
        if (writes.containsKey(key)) return
        writes[key] = scope.launch {
            delay(WRITE_EVERY)
            writes.remove(key)
            write(key)
        }
    }

    /** Writes every file waiting to be. */
    fun flush() {
        for (key in writes.keys.toList()) {
            writes.remove(key)!!.cancel()
            write(key)
        }
    }

    private fun write(key: String) {
        val now = clock()
        val file: File
        val json: JsonObject
        if (key == STATE_KEY) {
            file = stateFile
            json = jsonOf(
                "windows" to windows.map { it.toJson() },
                "sessions" to sessions.map { it.toJson() },
                "projects" to projects,
            ).plusIfNotNull("roots", roots)
                .plus("home", home)
                .plus("agent", agent.name)
                .plus("agents", AgentIntegration.toJsonAll(agents))
                .let { if (profiles.isNotEmpty()) it.plus("profiles", profiles) else it }
                .plusIfNotNull("opensIn", opensIn)
                .plusIfNotNull("placement", placement?.name)
                .plus("terminals", terminals.map { it.toJson() })
                .plus("at", stateAt ?: now)
        } else {
            val v = views[key] ?: return
            file = sessionFile(key)
            json = JsonObject(linkedMapOf<String, JsonElement>("key" to JsonPrimitive(key), "at" to JsonPrimitive(now)) + v.toJson())
        }
        try {
            file.parentFile.mkdirs()
            // Whole or not at all, should the app be killed mid-write.
            val tmp = File("${file.path}.tmp")
            tmp.writeText(jsonEncode(json))
            if (!tmp.renameTo(file)) throw java.io.IOException("rename to $file failed")
        } catch (e: Exception) {
            debugPrint("PocketTerm: terminal cache: $e")
        }
    }

    override fun dispose() {
        users = 1
        detach()
        for (p in pending.values) {
            if (!p.isCompleted) p.completeExceptionally(TerminalException("Closed."))
        }
        super.dispose()
    }

    private companion object {
        val HELLO_EVERY = 4.seconds
        const val SILENT_MS = 10_000L

        /** A sync unanswered this long is taken as lost. */
        const val SYNC_WAIT_MS = 8_000L

        /** A watched session behind the state's seq this long, without live ops catching it up, syncs. */
        const val BEHIND_WAIT_MS = 3_000L
        val WRITE_EVERY = 2.seconds
        val KEEP_FOR = 14.days

        /** How long an answer that came too late is still taken. */
        val LATE_FOR = 2.minutes
        const val SAME_FOR_MS = 2 * 60_000L

        /** The writes' key for state.json (session keys are never empty). */
        const val STATE_KEY = ""
    }
}

/** Lower-case hex SHA-1 of [bytes]. */
internal fun sha1Hex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-1").digest(bytes).joinToString("") { "%02x".format(it) }

/** This object with [key] set to [value] (added at the end, or replaced in place). */
internal fun JsonObject.plus(key: String, value: Any?): JsonObject =
    JsonObject(LinkedHashMap<String, JsonElement>(this).apply { put(key, value.toJsonElement()) })

/** [plus], only when [value] isn't null (Dart's `'key': ?value`). */
internal fun JsonObject.plusIfNotNull(key: String, value: Any?): JsonObject = if (value == null) this else plus(key, value)
