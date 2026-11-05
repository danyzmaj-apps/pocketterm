package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.consumeAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import java.io.IOException
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes

private const val TOPIC = "abcd1234"

/**
 * A PocketTerm server's live channel (packages/pocketterm_server/PROTOCOL.md) answering joins of
 * [TOPIC]. It refuses the first [refuse] connections at the door, can be [reachable] or not, and
 * can drop or end the connection there is.
 */
private class FakeLiveServer(
    var refuse: Int = 0,
    inner: Server = PocketTermServerClient(Backend(url = "http://localhost:1"), MemoryDeviceTokens()),
) : Server by inner {
    var reachable = true

    /** Answers joins and pings. */
    var answering = true

    var signedIn = true
    var connects = 0
    var joinCount = 0
    var pings = 0
    val sent = mutableListOf<Pair<String, JsonObject>>()
    var socket: FakeSocket? = null
    private val endedFlow = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    override val ended: SharedFlow<Unit> get() = endedFlow

    override suspend fun recheck() {}

    override suspend fun refused() {
        if (!signedIn) return
        signedIn = false
        endedFlow.emit(Unit)
    }

    override suspend fun connectLive(): LiveSocket {
        connects++
        if (!reachable) throw IOException("Connection refused")
        if (refuse > 0) {
            refuse--
            throw ServerException(401, "unauthorized", "Not signed in.")
        }
        return FakeSocket(this).also { socket = it }
    }

    fun received(ws: FakeSocket, data: String) {
        val f = jsonDecode(data) as JsonObject
        when (f["t"].str) {
            "join" -> if (f["topic"].str == TOPIC && answering) {
                joinCount++
                ws.push(jsonEncode(jsonOf("t" to "joined", "topic" to TOPIC)))
            }
            "send" -> sent += f["event"].str!! to f["payload"].obj!!
            "ping" -> {
                pings++
                if (answering) ws.push(jsonEncode(jsonOf("t" to "pong")))
            }
        }
    }

    /** Relays [payload] of [event] to the client, as from another device. */
    fun deliver(event: String, payload: JsonObject) =
        socket!!.push(jsonEncode(jsonOf("t" to "msg", "topic" to TOPIC, "event" to event, "payload" to payload)))

    /** Closes the connection there is with [code]: 1001 the server stopping, 4003 this device revoked. */
    fun drop(code: Int) = socket!!.end(code)
}

private class FakeSocket(private val server: FakeLiveServer) : LiveSocket {
    private val channel = Channel<String>(Channel.UNLIMITED)
    override val frames: Flow<String> = channel.consumeAsFlow()
    override var closeCode: Int? = null
    var closed = false

    override fun add(frame: String) {
        if (!closed) server.received(this, frame)
    }

    fun push(frame: String) {
        if (!closed) channel.trySend(frame)
    }

    fun end(code: Int) {
        if (closed) return
        closed = true
        closeCode = code
        channel.close()
    }

    override suspend fun close(code: Int) = end(code)
}

class TerminalChannelTest {
    private val key = ChannelKey(ByteArray(32) { 3 })

    private inner class Setup(scope: TestScope, refuse: Int = 0) {
        val server = FakeLiveServer(refuse)
        val states = mutableListOf<Boolean>()
        val received = mutableListOf<JsonObject>()
        var told = 0
        val channel = TerminalChannel(
            server,
            TOPIC,
            mapOf("state" to { p: JsonObject -> received += p }),
            key = key,
            name = "test",
            scope = scope.backgroundScope,
            onJoined = { states += it },
            onUnreachable = { told++ },
        )

        /** The computer's side of the topic, sealing what [FakeLiveServer.deliver] relays. */
        val computer = ChannelSeal(key, TOPIC, guard = ReplayGuard())
    }

    @Test
    fun `a connection the server drops is made again, and messages reach it after`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        assertTrue(s.channel.joined)
        assertEquals(1, s.server.joinCount)

        s.server.drop(1001)
        runCurrent()
        assertFalse(s.channel.joined)
        advanceTimeBy(1001)
        assertEquals(2, s.server.joinCount)
        assertTrue(s.channel.joined)
        assertEquals(listOf(true, false, true), s.states)

        s.server.deliver("state", s.computer.seal("state", jsonOf("windows" to 3)))
        runCurrent()
        assertEquals(listOf(jsonOf("windows" to 3)), s.received)
    }

    @Test
    fun `opened messages reach the handler in the order they came, unsealed ones never do, sent ones go sealed`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        assertTrue(s.channel.joined)

        s.server.deliver("state", jsonOf("windows" to 99))
        for (i in 0 until 20) s.server.deliver("state", s.computer.seal("state", jsonOf("windows" to i)))
        runCurrent()
        assertEquals((0 until 20).toList(), s.received.map { it["windows"].int })

        s.channel.send("hello", jsonOf("from" to "phone"))
        val (event, payload) = s.server.sent.single()
        assertEquals(setOf("v", "n", "c"), payload.keys, "the server sees only the envelope")
        assertEquals(jsonOf("from" to "phone"), s.computer.open(event, payload))
    }

    @Test
    fun `a message replayed or out of order is dropped`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        val first = s.computer.seal("state", jsonOf("windows" to 1))
        val second = s.computer.seal("state", jsonOf("windows" to 2))
        s.server.deliver("state", second)
        s.server.deliver("state", first)
        s.server.deliver("state", second)
        runCurrent()
        assertEquals(listOf(jsonOf("windows" to 2)), s.received)
    }

    @Test
    fun `a connection refused at the door is tried again until it is let in`() = runTest {
        val s = Setup(this, refuse = 2)
        s.channel.open()
        runCurrent()
        assertFalse(s.channel.joined)
        // Refused at 0 and 1 s, let in at 3 s.
        advanceTimeBy(2999)
        assertFalse(s.channel.joined)
        advanceTimeBy(2)
        assertTrue(s.channel.joined)
        assertEquals(listOf(true), s.states)
        assertTrue(s.server.signedIn, "the token itself still works")
    }

    @Test
    fun `the wait between tries doubles up to 30 s`() = runTest {
        val s = Setup(this, refuse = 1000)
        s.channel.open()
        runCurrent()
        val at = mutableListOf<Long>()
        var seen = s.server.connects
        at += testScheduler.currentTime
        while (at.size < 9) {
            advanceTimeBy(500)
            if (s.server.connects != seen) {
                seen = s.server.connects
                at += testScheduler.currentTime
            }
        }
        val waits = at.zipWithNext { a, b -> (b - a + 499) / 1000 }
        assertEquals(listOf(1L, 2, 4, 8, 16, 30, 30, 30), waits)
    }

    @Test
    fun `Retry connects at once, however long the wait between tries had grown`() = runTest {
        val s = Setup(this, refuse = 1000)
        s.channel.open()
        // Refused at 0, 1 and 3 s: the next try would be at 7 s.
        advanceTimeBy(3500)
        assertEquals(997, s.server.refuse)
        assertTrue(s.channel.unreachable)

        s.server.refuse = 0
        s.channel.reconnect()
        assertFalse(s.channel.unreachable, "trying again, not given up")
        runCurrent()
        assertTrue(s.channel.joined)
        assertEquals(listOf(true), s.states)
    }

    @Test
    fun `after close nothing joins again`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        val socket = s.server.socket!!
        s.channel.close()
        runCurrent()
        socket.end(1001)
        advanceTimeBy(1500)
        assertEquals(1, s.server.joinCount)
        assertFalse(s.channel.joined)
    }

    @Test
    fun `a message too big for the server is refused before it goes, the connection and later messages stay`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        assertTrue(s.channel.joined)

        // Sealed and in base64 it would be over 256 KiB, which closes the socket.
        assertFailsWith<TerminalException> { s.channel.send("run", jsonOf("text" to "x".repeat(200 * 1024))) }
        s.channel.send("run", jsonOf("text" to "small"))
        assertEquals(jsonOf("text" to "small"), s.computer.open("run", s.server.sent.single().second))
        runCurrent()
        assertEquals(listOf(true), s.states, "never dropped")
    }

    @Test
    fun `a sender whose clock is far off is told apart - how far, until one of its messages opens again`() {
        val now = System.currentTimeMillis()
        var skew = 12.minutes.inWholeMilliseconds
        val phone = ChannelSeal(key, TOPIC, clock = { System.currentTimeMillis() + skew })
        val mac = ChannelSeal(key, TOPIC, clock = System::currentTimeMillis)
        assertNull(mac.open("hello", phone.seal("hello", jsonOf("from" to "p"))))
        // The receiver reads its clock a moment after the sender did.
        assertTrue(abs(mac.clockOff!!.inWholeSeconds - 12 * 60) <= 2)
        skew = (-30).minutes.inWholeMilliseconds
        assertNull(mac.open("hello", phone.seal("hello", jsonOf("from" to "p"))))
        assertTrue(abs(mac.clockOff!!.inWholeSeconds + 30 * 60) <= 2)
        skew = 0
        assertEquals(jsonOf("from" to "p"), mac.open("hello", phone.seal("hello", jsonOf("from" to "p"))))
        assertNull(mac.clockOff)
        // A message from before the receiver started is old, not off.
        val early = ChannelSeal(key, TOPIC, clock = { now - 30_000 })
        val late = ChannelSeal(key, TOPIC, clock = System::currentTimeMillis)
        assertNull(late.open("hello", early.seal("hello", jsonOf())))
        assertNull(late.clockOff)
    }

    @Test
    fun `a close for a revoked device ends the sign-in, and nothing joins again`() = runTest {
        val s = Setup(this)
        var ended = false
        backgroundScope.launch { s.server.ended.collect { ended = true } }
        s.channel.open()
        runCurrent()
        s.server.drop(4003)
        runCurrent()
        assertTrue(ended)
        assertFalse(s.server.signedIn)
        advanceTimeBy(1500)
        assertEquals(1, s.server.joinCount)
        assertFalse(s.channel.joined)
    }

    @Test
    fun `a join nobody answers is given up after 20 s`() = runTest {
        val s = Setup(this)
        s.server.answering = false
        s.channel.open()
        runCurrent()
        assertEquals(1, s.server.connects)
        advanceTimeBy(19_999)
        assertEquals(1, s.server.connects)
        // Given up at 20 s, tried again 1 s later.
        advanceTimeBy(1002)
        assertEquals(2, s.server.connects)
        s.server.answering = true
        s.channel.reconnect()
        runCurrent()
        assertTrue(s.channel.joined)
    }

    @Test
    fun `pings go every 25 s and two unanswered drop the connection`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        advanceTimeBy(25_001)
        assertEquals(1, s.server.pings)
        assertTrue(s.channel.joined)
        s.server.answering = false
        advanceTimeBy(50_000)
        assertEquals(3, s.server.pings)
        assertTrue(s.channel.joined)
        // The third tick finds two unanswered.
        advanceTimeBy(25_000)
        assertFalse(s.channel.joined)
        assertEquals(1, s.server.connects)
        s.server.answering = true
        advanceTimeBy(1001)
        assertEquals(2, s.server.connects)
        assertTrue(s.channel.joined)
    }

    @Test
    fun `a server that no longer has the join is joined again`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        s.server.socket!!.push(jsonEncode(jsonOf("t" to "error", "error" to "not_joined")))
        runCurrent()
        assertFalse(s.channel.joined)
        advanceTimeBy(1001)
        assertTrue(s.channel.joined)
        assertEquals(2, s.server.joinCount)
    }

    @Test
    fun `a server that goes away reads as unreachable until the channel is let in again`() = runTest {
        val s = Setup(this)
        s.channel.open()
        runCurrent()
        assertFalse(s.channel.unreachable)

        s.server.reachable = false
        s.server.drop(1001)
        advanceTimeBy(1001)
        assertTrue(s.channel.unreachable)
        assertFalse(s.channel.joined)

        s.server.reachable = true
        advanceTimeBy(15_000)
        assertTrue(s.channel.joined)
        assertFalse(s.channel.unreachable)
        assertEquals(2, s.told, "once when it went, once when it came back")

        s.server.reachable = false
        s.server.drop(1001)
        advanceTimeBy(1001)
        assertTrue(s.channel.unreachable)
        s.channel.close()
        assertFalse(s.channel.unreachable, "closed, nothing is tried")
        assertNotNull(s.server.socket)
    }
}
