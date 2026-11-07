package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Duration
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** One thread the tests and what they start (channels, sessions) run on, as the app's main thread. */
abstract class Confined {
    private val executor = Executors.newSingleThreadExecutor()
    protected val confined = executor.asCoroutineDispatcher()
    protected val scope = CoroutineScope(SupervisorJob() + confined)

    protected fun test(body: suspend CoroutineScope.() -> Unit) = runBlocking(confined) { body() }

    /** Waits up to 5 s for [check]. */
    protected suspend fun until(check: () -> Boolean) {
        for (i in 0 until 500) {
            if (check()) break
            delay(10)
        }
        assertTrue(check())
    }

    /** What's queued on this thread runs first. */
    protected suspend fun pump() = delay(50)

    protected fun closeConfined() {
        scope.cancel()
        executor.shutdownNow()
    }
}

/** The client's tests against the PocketTerm server ([ServerClientOwnServerTest]). */
abstract class ServerClientContract : Confined() {
    protected abstract fun start(): TestBackend

    protected lateinit var own: TestBackend
    private lateinit var mac: Server
    private lateinit var phone: Server

    @Before
    fun setUp() {
        own = start()
        runBlocking {
            mac = own.desktop()
            phone = own.phone(mac)
        }
    }

    @After
    fun tearDown() {
        if (::mac.isInitialized) mac.close()
        if (::phone.isInitialized) phone.close()
        closeConfined()
        if (::own.isInitialized) own.stop()
    }

    private suspend inline fun <reified T : Throwable> fails(noinline block: suspend () -> Unit): T {
        try {
            block()
        } catch (e: Throwable) {
            if (e is T) return e
            throw AssertionError("expected ${T::class.simpleName}, got $e", e)
        }
        throw AssertionError("expected ${T::class.simpleName}, nothing thrown")
    }

    @Test
    fun `a phone's code signs it in once, a wrong one or a wrong setup token signs nobody in`() = test {
        assertEquals(DeviceRole.desktop, mac.account?.device?.role)
        assertEquals(DeviceRole.phone, phone.account?.device?.role)
        assertEquals(mac.account?.id, phone.account?.id)

        val code = mac.createPairingCode()
        own.client().redeemCode(code, label = "iPad", platform = "ios")
        val late = own.client()
        assertEquals("invalid_code", fails<ServerException> { late.redeemCode(code, label = "Pixel", platform = "android") }.code)
        assertNull(late.account)
        assertEquals(
            "invalid_code",
            fails<ServerException> { own.client().redeemSetup("not-the-token", label = "Mac mini", platform = "macos") }.code,
        )
        fails<ServerException> { phone.createPairingCode() } // only computers make codes
    }

    @Test
    fun `the live channel carries sealed messages between the computer and the phone, both ways`() = test {
        val key = ChannelKey.generate()
        val atMac = mutableListOf<JsonObject>()
        val atPhone = mutableListOf<JsonObject>()
        val desk = TerminalChannel(mac, "abcd1234", mapOf("hello" to { p: JsonObject -> atMac.add(p); Unit }), key = key, name = "mac", scope = scope)
        val remote = TerminalChannel(phone, "abcd1234", mapOf("state" to { p: JsonObject -> atPhone.add(p); Unit }), key = key, name = "phone", scope = scope)
        // Someone on the same server without the key hears nothing it can open.
        val stranger = mutableListOf<JsonObject>()
        val strangerPhone = own.phone(mac)
        val other = TerminalChannel(
            strangerPhone,
            "abcd1234",
            mapOf("hello" to { p: JsonObject -> stranger.add(p); Unit }, "state" to { p: JsonObject -> stranger.add(p); Unit }),
            key = ChannelKey.generate(),
            name = "stranger",
            scope = scope,
        )
        try {
            desk.open()
            remote.open()
            other.open()
            until { desk.joined && remote.joined && other.joined }

            remote.send("hello", jsonOf("from" to "phone-1"))
            desk.send("state", jsonOf("windows" to emptyList<Any>()))
            until { atMac.isNotEmpty() && atPhone.isNotEmpty() }
            assertEquals(listOf(jsonOf("from" to "phone-1")), atMac)
            assertEquals(listOf(jsonOf("windows" to emptyList<Any>())), atPhone)
            delay(200)
            assertTrue(stranger.isEmpty())
        } finally {
            desk.close()
            remote.close()
            other.close()
            strangerPhone.close()
        }
    }

    @Test
    fun `a blob goes up once at a path of its own, comes down once, and is gone after`() = test {
        val path = phone.newBlobPath()
        assertTrue(Server.isBlobPath(path))
        assertFalse(Server.isBlobPath("../etc/passwd"))
        val bytes = ByteArray(70000) { (it % 251).toByte() }
        phone.putBlob(path, bytes)
        assertEquals(409, fails<ServerException> { phone.putBlob(path, ByteArray(1)) }.status)
        assertContentEquals(bytes, mac.getBlob(path))
        assertEquals(404, fails<ServerException> { mac.getBlob(path) }.status)

        val unused = phone.newBlobPath()
        phone.putBlob(unused, ByteArray(4))
        phone.deleteBlob(unused)
        fails<ServerException> { mac.getBlob(unused) }
    }

    @Test
    fun `an image over the limit is refused with its reason, not as a lost connection`() = test {
        val path = phone.newBlobPath()
        assertEquals(413, fails<ServerException> { phone.putBlob(path, ByteArray(Server.maxBlobBytes + 1)) }.status)
        assertEquals(404, fails<ServerException> { mac.getBlob(path) }.status)
    }

    @Test
    fun `a computer lists itself for the phones and takes itself off`() = test {
        mac.putDesktop("abcd1234", name = "MacBook Pro", platform = "macos")
        val rows = phone.desktops()
        assertEquals("abcd1234", rows.single()["id"].str)
        assertEquals("MacBook Pro", rows.single()["name"].str)
        val seen = Instant.parse(rows.single()["seen_at"].str)
        assertTrue(Duration.between(seen, Instant.now()).abs() < Duration.ofMinutes(1))
        fails<ServerException> { phone.putDesktop("zzzz9999", name = "Fake", platform = "macos") }

        mac.deleteDesktop("abcd1234")
        assertTrue(phone.desktops().isEmpty())
    }

    @Test
    fun `a computer's push reaches each phone the relay knows, and stops once it unregisters`() = test {
        val token = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
        phone.push("register", jsonOf("token" to token, "label" to "iPhone", "platform" to "ios"))
        val key = ChannelKey.generate()
        val enc = base64Encode(sealBytes(key, "{\"title\":\"done\"}".toByteArray(), pushAad("abcd1234")))
        val sent = mac.push("notify", jsonOf("tag" to pushTag(key), "enc" to enc, "collapse" to sessionTag(key, "abcd1234/s1")))
        assertEquals(1, sent["sent"].int)
        until { own.relayed.isNotEmpty() }
        // One request for the one phone, sealed to the relay on its way.
        assertEquals(1, own.relayed.size)
        assertFalse(jsonEncode(own.relayed.single()).contains(token))

        phone.push("unregister", jsonOf("token" to token))
        assertEquals(0, mac.push("notify", jsonOf("tag" to pushTag(key), "enc" to enc))["sent"].int)
    }

    @Test
    fun `a phone that leaves, or that the computer signs out, can do nothing more`() = test {
        val ended = mutableListOf<Unit>()
        scope.launch(start = CoroutineStart.UNDISPATCHED) { phone.ended.collect { ended.add(it) } }
        mac.revokeDevice(phone.account!!.device.id)
        assertEquals(401, fails<ServerException> { phone.desktops() }.status)
        pump()
        assertEquals(1, ended.size)
        assertNull(phone.account)

        val other = own.phone(mac)
        other.leave()
        assertNull(other.account)
        assertTrue(mac.devices().none { it.role == DeviceRole.phone })
        other.close()
    }

    @Test
    fun `erasing the server signs every device out but keeps its setup link`() = test {
        mac.putDesktop("abcd1234", name = "MacBook Pro", platform = "macos")
        mac.erase()
        assertNull(mac.account)
        fails<ServerException> { phone.desktops() }
        val again = own.desktop()
        try {
            assertTrue(again.desktops().isEmpty())
        } finally {
            again.close()
        }
    }

    @Test
    fun `a phone signed out while it's on the live channel is told, and its sign-in ends`() = test {
        val key = ChannelKey.generate()
        mac.putDesktop("abcd1234", name = "MacBook Pro", platform = "macos")
        val ended = mutableListOf<Unit>()
        scope.launch(start = CoroutineStart.UNDISPATCHED) { phone.ended.collect { ended.add(it) } }
        val remote = TerminalChannel(phone, "abcd1234", emptyMap(), key = key, name = "phone", scope = scope)
        try {
            remote.open()
            until { remote.joined }
            mac.revokeDevice(phone.account!!.device.id)
            until { ended.isNotEmpty() }
            assertNull(phone.account)
        } finally {
            remote.close()
        }
    }
}

class ServerClientOwnServerTest : ServerClientContract() {
    override fun start(): TestBackend = OwnServer.start()
}

class ServerClientTest : Confined() {
    @After
    fun tearDown() = closeConfined()

    private fun kept(url: String) = MemoryDeviceTokens(
        jsonEncode(
            jsonOf(
                "url" to url,
                "token" to "token-1",
                "server" to "srv0000000000001",
                "device" to jsonOf("id" to "dev0000000000001", "role" to "phone", "label" to "iPhone", "platform" to "ios"),
            ),
        ),
    )

    // A connection kept open from before the app went to the background can be dead without having said so: a
    // request on it waited out its whole timeout, and the phone said it couldn't reach the server.
    @Test
    fun `back at the front, requests go on new connections, not on ones that went quiet meanwhile`() = test {
        val quiet = GoesQuiet()
        val client = PocketTermServerClient(quiet.backend, kept(quiet.backend.url))
        try {
            client.load()
            assertTrue(client.desktops().isEmpty())

            client.freshConnections()
            assertTrue(withTimeout(3.seconds) { client.desktops() }.isEmpty())
            assertEquals(2, quiet.connections.get())
        } finally {
            client.close()
            quiet.stop()
        }
    }

    // A background recheck's 401 can land while the app disconnects: the sign-in is forgotten, no error escapes.
    @Test
    fun `a refusal that lands after the client closed is quiet`() = test {
        val tokens = kept("http://127.0.0.1:9")
        val client = PocketTermServerClient(Backend(url = "http://127.0.0.1:9"), tokens)
        client.load()
        val ended = mutableListOf<Unit>()
        val watch = scope.launch(start = CoroutineStart.UNDISPATCHED) { client.ended.collect { ended.add(it) } }
        client.close()
        client.refused()
        pump()
        watch.cancel()
        assertNull(client.account)
        assertNull(tokens.value)
        assertTrue(ended.isEmpty())
    }
}

/**
 * A server that answers the first request on each connection, keeping it open, and then never
 * another on it: what a connection the network dropped looks like from the phone.
 */
private class GoesQuiet {
    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    val connections = AtomicInteger()
    val backend = Backend(url = "http://127.0.0.1:${socket.localPort}")

    init {
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val s = runCatching { socket.accept() }.getOrNull() ?: break
                connections.incrementAndGet()
                thread(isDaemon = true) {
                    runCatching {
                        val input = s.getInputStream()
                        val buf = ByteArray(8192)
                        if (input.read(buf) > 0) {
                            s.getOutputStream().write("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\n\r\n[]".toByteArray())
                            s.getOutputStream().flush()
                        }
                        // Never another answer on it.
                        while (input.read(buf) >= 0) Unit
                    }
                }
            }
        }
    }

    fun stop() = socket.close()
}
