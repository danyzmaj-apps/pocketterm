package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/** Receives one message, opened: its fields as the sender gave them. */
typealias TopicHandler = (payload: JsonObject) -> Unit

/**
 * Seals what goes out on [topic] with the computer's [key] and opens what comes in (E2e.kt).
 * Each message gets a `ts`, a random `mid`, this seal's `ep` (random, new for each seal: each
 * start of a sender) and `seq` (1, 2, 3 …). What doesn't open or the [ReplayGuard] refuses (stale,
 * seen before, out of order) is dropped and logged once per kind. The guard is the computer's for
 * this run of the app ([ReplayGuard.of]) unless one is given (`guard`, or a fresh one on a test `clock`).
 */
class ChannelSeal(
    val key: ChannelKey,
    val topic: String,
    /** Who this is, in the log. */
    val name: String = "channel",
    guard: ReplayGuard? = null,
    /** Milliseconds since epoch. */
    clock: (() -> Long)? = null,
) {
    private val clock: () -> Long = clock ?: System::currentTimeMillis
    private val guard: ReplayGuard = guard ?: if (clock == null) ReplayGuard.of(topic) else ReplayGuard(clock = clock)
    private val logged = mutableSetOf<String>()
    private val epoch = newMessageId()
    private var seq = 0L

    /**
     * [payload] of [event], as it goes on the topic. Seal in the order sent: a receiver drops a
     * `seq` below one it already took. The payload goes whole under `m`, beside the envelope's
     * `ts`, `mid`, `ep` and `seq`, so a payload's own keys of those names (an items catch-up's `seq`) stay.
     */
    @Synchronized
    fun seal(event: String, payload: JsonObject): JsonObject = sealEnvelope(
        key,
        jsonOf("m" to payload, "ts" to clock(), "mid" to newMessageId(), "ep" to epoch, "seq" to ++seq),
        channelAad(topic, event),
    )

    /**
     * How far the other side's clock is ahead of this one (behind: negative), as the last message
     * dropped for its time showed; null once a message opens. The guard drops every message more
     * than its window off, so with a clock that wrong nothing gets through at all.
     */
    @Volatile
    var clockOff: Duration? = null
        private set

    /** What [wire] (an [event] off the topic) says: the payload [seal] put in; null when it's dropped. */
    @Synchronized
    fun open(event: String, wire: JsonObject): JsonObject? {
        val (message, drop) = openEnvelope(key, wire, channelAad(topic, event))
        val why = drop ?: guard.check(message!!)
        val ts = message?.get("ts").long
        if (ts != null && why == "time") {
            val off = (ts - clock()).milliseconds
            // A message from before this app started is old, not off.
            if (off.absoluteValue > guard.window) {
                clockOff = off
                if (logged.add("clock")) debugPrint("PocketTerm: $name: the other side's clock is off by ${off.inWholeSeconds} s")
            }
        }
        if (why != null) {
            if (logged.add("$event $why")) debugPrint("PocketTerm: $name: dropped $event ($why); more alike go unlogged")
            return null
        }
        clockOff = null
        val payload = message!!["m"].obj
        if (payload == null) {
            if (logged.add("$event shape")) debugPrint("PocketTerm: $name: dropped $event (no payload)")
            return null
        }
        return payload
    }
}

/**
 * A computer's [topic] (its id) on the server's live channel (GET /v1/ws,
 * packages/pocketterm_server/PROTOCOL.md), kept joined
 * while open. Everything on it is sealed with the computer's key ([ChannelSeal]): the server only
 * relays envelopes; handlers get the opened messages, in the order they came.
 *
 * Whenever it isn't joined (no connection, the server went away or restarted, a join nobody
 * answers, two pings without a pong) this connects again after 1 s, 2 s, 4 s … up to 30 s. A
 * close with 4003 (this device was revoked or left) ends the sign-in instead ([Server.refused]).
 *
 * Confined to [scope]: call it on the scope's (single-threaded) dispatcher, Main on Android;
 * handlers and callbacks run there too.
 */
class TerminalChannel(
    private val server: Server,
    /** The topic joined: the computer's id. */
    val topic: String,
    private val handlers: Map<String, TopicHandler>,
    key: ChannelKey,
    /** Who this is, in the log. */
    val name: String,
    private val scope: CoroutineScope,
    /** The channel joined (true), or stopped being joined (false). */
    private val onJoined: ((joined: Boolean) -> Unit)? = null,
    /** [unreachable] changed. */
    private val onUnreachable: (() -> Unit)? = null,
    seal: ChannelSeal? = null,
) {
    private val seal: ChannelSeal = seal ?: ChannelSeal(key, topic, name = name)

    private var ws: LiveSocket? = null
    private var sub: Job? = null
    private var open = false
    private var retry: Job? = null
    private var joinWait: Job? = null
    private var ping: Job? = null
    private var unanswered = 0
    private var wait: Duration = FIRST_WAIT

    /** Bumped by [open] and [close]: a connection still on its way from before must not make a second one. */
    private var gen = 0

    var joined: Boolean = false
        private set

    /** How far the other side's clock is off this one's, while it's too far for its messages to be taken ([ChannelSeal.clockOff]). */
    val clockOff: Duration? get() = seal.clockOff

    /**
     * The last try to connect got no connection to the server (offline, DNS, TLS, a timeout), as
     * opposed to one still on its way; false again once a connection is made, and after [close].
     */
    var unreachable: Boolean = false
        private set

    fun open() {
        if (open) return
        open = true
        val g = ++gen
        debugPrint("PocketTerm: $name: open")
        wait = FIRST_WAIT
        scope.launch { connect(g) }
    }

    fun close() {
        if (!open) return
        open = false
        gen++
        debugPrint("PocketTerm: $name: close")
        retry?.cancel()
        retry = null
        unreachable = false
        drop()
    }

    /**
     * Connects again at once, on a new socket, with the wait between tries back at its shortest:
     * the person asked (Retry), so whatever the last try ran into may be gone. Nothing while closed.
     */
    fun reconnect() {
        if (!open) return
        val g = ++gen
        debugPrint("PocketTerm: $name: reconnect")
        retry?.cancel()
        retry = null
        drop()
        wait = FIRST_WAIT
        setUnreachable(false)
        scope.launch { connect(g) }
    }

    /**
     * Drops [event] if the channel isn't joined: whoever waits on an answer times out, and the
     * other side catches up after the next join. A message too big for the server fails with a
     * [TerminalException] and goes nowhere; the connection stays.
     */
    fun send(event: String, payload: JsonObject) {
        val w = ws
        if (w == null || !joined) return
        val sealed = seal.seal(event, payload)
        // Sealed, it's all ASCII: its length is its size in bytes.
        val frame = jsonEncode(jsonOf("t" to "send", "topic" to topic, "event" to event, "payload" to sealed))
        if (frame.length > maxFrameBytes) {
            debugPrint("PocketTerm: $name: $event not sent: ${frame.length} bytes, over $maxFrameBytes")
            throw TerminalException("That is too big to send in one go. Send it in smaller parts.")
        }
        w.add(frame)
    }

    private fun receive(event: String, handler: TopicHandler, wire: JsonObject) {
        try {
            seal.open(event, wire)?.let(handler)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            debugPrint("PocketTerm: $name: $event: $e")
        }
    }

    private suspend fun connect(g: Int) {
        fun stale() = !open || g != gen
        val socket: LiveSocket
        try {
            timing("socket connecting")
            socket = server.connectLive()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            timing("socket failed")
            if (stale()) return
            // Refused at the door: maybe the token stopped working.
            scope.launch { server.recheck() }
            setUnreachable(true)
            return again(null, "$e")
        }
        if (stale()) {
            scope.launch { runCatching { socket.close() } }
            return
        }
        timing("socket open")
        setUnreachable(false)
        ws = socket
        sub = scope.launch {
            try {
                socket.frames.collect { frame(socket, it) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                // A broken connection ends like a closed one.
            }
            closed(socket)
        }
        socket.add(jsonEncode(jsonOf("t" to "join", "topic" to topic)))
        joinWait = scope.launch {
            delay(STUCK)
            again(socket, "no answer to the join")
        }
        unanswered = 0
        ping = scope.launch {
            while (true) {
                delay(PING_EVERY)
                if (unanswered >= 2) {
                    again(socket, "no answer to the pings")
                    continue
                }
                unanswered++
                socket.add(jsonEncode(jsonOf("t" to "ping")))
            }
        }
    }

    private fun frame(socket: LiveSocket, data: String) {
        if (socket !== ws) return
        val f = jsonDecodeOrNull(data).obj ?: return
        val t = f["topic"].str
        when (f["t"].str) {
            "joined" -> if (t == topic) {
                timing("joined")
                joinWait?.cancel()
                wait = FIRST_WAIT
                setJoined(true)
            }
            "msg" -> {
                val event = f["event"].str
                val p = f["payload"].obj
                if (t == topic && event != null && p != null) handlers[event]?.let { receive(event, it, p) }
            }
            "pong" -> unanswered = 0
            "error" -> {
                val error = f["error"].str ?: return
                debugPrint("PocketTerm: $name: the server said $error")
                // Joined on the server no more (it restarted under us).
                if (error == "not_joined") again(socket, error)
            }
        }
    }

    private fun closed(socket: LiveSocket) {
        if (socket !== ws) return
        if (socket.closeCode == 4003) {
            debugPrint("PocketTerm: $name: this device was signed out on the server")
            drop()
            scope.launch { server.refused() }
            return
        }
        again(socket, "closed${socket.closeCode?.let { " ($it)" } ?: ""}")
    }

    /** Leaves the connection there is, if any. */
    private fun drop() {
        joinWait?.cancel()
        ping?.cancel()
        joinWait = null
        ping = null
        setJoined(false)
        val socket = ws
        ws = null
        sub?.cancel()
        sub = null
        if (socket != null) {
            scope.launch {
                try {
                    socket.close()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    debugPrint("PocketTerm: $name: $e")
                }
            }
        }
    }

    /** [socket] (null: none was made) is no good: a new one after a while. */
    private fun again(socket: LiveSocket?, why: String) {
        if (!open || retry != null || socket !== ws) return
        drop()
        val w = wait
        wait = if (wait * 2 > MAX_WAIT) MAX_WAIT else wait * 2
        debugPrint("PocketTerm: $name: joining again in ${w.inWholeSeconds} s ($why)")
        val g = gen
        retry = scope.launch {
            delay(w)
            retry = null
            if (g == gen) connect(g)
        }
    }

    private fun setUnreachable(value: Boolean) {
        if (unreachable == value) return
        unreachable = value
        onUnreachable?.invoke()
    }

    private fun setJoined(value: Boolean) {
        if (joined == value) return
        joined = value
        debugPrint("PocketTerm: $name: ${if (value) "joined" else "not joined"}")
        onJoined?.invoke(value)
    }

    companion object {
        private val FIRST_WAIT = 1.seconds
        private val MAX_WAIT = 30.seconds

        /** How long a join may take before it counts as stuck. */
        private val STUCK = 20.seconds

        /** How often to ping the server; two without a pong and the link is dead. */
        private val PING_EVERY = 25.seconds

        /**
         * The largest frame the server takes (packages/pocketterm_server/PROTOCOL.md); a larger one
         * would close the socket, and every message after it would be lost until the next join.
         */
        const val maxFrameBytes: Int = 256 * 1024
    }
}
