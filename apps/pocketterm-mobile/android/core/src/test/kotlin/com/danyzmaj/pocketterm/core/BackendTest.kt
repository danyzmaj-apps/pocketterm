package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Instant
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** The platform side as far as the backend goes: only [getBackend] and [setBackend]. */
private class BackendOnlyNative : Native {
    /** What the platform side holds: `url` and `kind`, or a legacy `key`. */
    var saved: Map<String, String?>? = null

    override suspend fun getBackend(): SavedBackend? {
        val s = saved ?: return null
        val url = s["url"] ?: return null
        return SavedBackend(url, s["kind"], legacy = s["key"] != null)
    }

    override suspend fun setBackend(url: String?, kind: String?) {
        saved = mapOf("url" to url, "kind" to kind)
    }

    override val events: Flow<NativeEvent> get() = throw UnsupportedOperationException()
    override suspend fun takeTappedSession(): String? = throw UnsupportedOperationException()
    override suspend fun registerPush(): String? = throw UnsupportedOperationException()
    override suspend fun notificationsAllowed(): Boolean = throw UnsupportedOperationException()
    override suspend fun openSettings(notifications: Boolean) = throw UnsupportedOperationException()
    override suspend fun channelKeys(): Map<String, String> = throw UnsupportedOperationException()
    override suspend fun setChannelKey(desktop: String, key: String) = throw UnsupportedOperationException()
    override suspend fun removeAllChannelKeys() = throw UnsupportedOperationException()
    override suspend fun startActivity(key: String, title: String, project: String, state: String, since: Instant, kind: String?): Boolean =
        throw UnsupportedOperationException()
    override suspend fun updateActivity(key: String, state: String, since: Instant, kind: String?) = throw UnsupportedOperationException()
    override suspend fun endActivity(key: String, immediate: Boolean) = throw UnsupportedOperationException()
    override suspend fun liveActivities(): List<LiveActivityRef> = throw UnsupportedOperationException()
    override suspend fun deviceToken(): String? = throw UnsupportedOperationException()
    override suspend fun setDeviceToken(value: String?) = throw UnsupportedOperationException()
    override suspend fun deviceName(): String = throw UnsupportedOperationException()
    override suspend fun setKeepAwake(on: Boolean) = throw UnsupportedOperationException()
    override suspend fun setAppIcon(icon: String) = throw UnsupportedOperationException()
}

class BackendTest {
    private val closers = mutableListOf<() -> Unit>()

    @AfterTest
    fun tearDown() = closers.forEach { it() }

    // Backend.parse

    @Test
    fun `parse normalizes the server URL`() {
        for (url in listOf("https://pt.example.com", " https://pt.example.com/ ", "https://pt.example.com/v1/")) {
            assertEquals("https://pt.example.com", Backend.parse(url).backend?.url, url)
        }
    }

    @Test
    fun `parse allows plain http only to this machine - Tailscale and the local network need https`() {
        for (url in listOf("http://127.0.0.1:47900", "http://localhost:47900", "https://mac.tail1234.ts.net")) {
            assertNotNull(Backend.parse(url).backend, url)
        }
        for (url in listOf(
            "http://pt.example.com",
            "http://192.168.1.20:47900",
            "http://mac.local:47900",
            "http://100.64.0.1:47900",
            "http://mac.tail1234.ts.net:47900",
        )) {
            assertNotNull(Backend.parse(url).error, url)
        }
    }

    @Test
    fun `parse rejects garbage`() {
        assertNotNull(Backend.parse("").error)
        assertNotNull(Backend.parse("pt.example.com").error)
        assertNotNull(Backend.parse("https://pt.example.com/x").error)
    }

    @Test
    fun `setup links round-trip`() {
        val b = Backend("https://pt.example.com")
        assertEquals(b, Backend.fromLink(b.link))
        assertNull(Backend.fromLink("pocketterm://todos"))
        assertNull(Backend.fromLink("pocketterm://setup?code=K7QM"))
    }

    @Test
    fun `a setup link carrying a key is not one and never connects`() {
        val other = "pocketterm://setup?url=https://abcd.supabase.co&key=sb_publishable_x&code=K7QM&d=abcd1234&k=AAAA"
        assertNull(Backend.fromLink(other))
        assertNull(Backend.pairingCode(other))
        assertNull(Backend.computerKey(other))
    }

    @Test
    fun `a computer's setup token and a phone's code are read back - links without them have none`() {
        val b = Backend("https://pt.example.com")
        val computer = "pocketterm://setup?url=https://pt.example.com&setup=abc_DEF-123"
        assertEquals(b, Backend.fromLink(computer))
        assertEquals("abc_DEF-123", Backend.setupToken(computer))
        assertNull(Backend.pairingCode(computer))
        val phone = b.linkWithCode("K7QM-3XRT-AB12")
        assertEquals("K7QM-3XRT-AB12", Backend.pairingCode(phone))
        assertNull(Backend.setupToken(phone))
        assertNull(Backend.pairingCode(b.link))
        assertNull(Backend.pairingCode("pocketterm://setup?url=https://pt.example.com&code="))
        assertNull(Backend.pairingCode("pocketterm://todos?code=K7QM"))
        // A link with a code but no usable server is no link at all.
        assertNull(Backend.pairingCode("pocketterm://setup?url=ftp://x&code=K7QM"))
    }

    @Test
    fun `a computer's QR carries its id and key next to the code - a link without them still signs in`() {
        val b = Backend("https://pt.example.com")
        val key = ChannelKey.generate()
        val link = b.linkWithCode("K7QM-3XRT-AB12", computer = ComputerKey("abcd1234", key))
        assertEquals("K7QM-3XRT-AB12", Backend.pairingCode(link))
        assertEquals(ComputerKey("abcd1234", key), Backend.computerKey(link))
        // Its key is a secret; it rides the link as is, URL-safe.
        val good = DartUri.tryParse(link)!!.queryParameters
        assertEquals(key.toBase64Url(), good["k"])
        assertNull(Backend.computerKey(b.linkWithCode("K7QM-3XRT-AB12")))
        assertEquals("K7QM-3XRT-AB12", Backend.pairingCode(b.linkWithCode("K7QM-3XRT-AB12")))
        // A key cut short, or an id that isn't a computer's, is no key.
        assertNull(Backend.computerKey(DartUri.build("pocketterm", "setup", good + ("k" to "AAAA"))))
        assertNull(Backend.computerKey(DartUri.build("pocketterm", "setup", good + ("d" to "../etc"))))
    }

    @Test
    fun `a Supabase project's links say so, and every link made from it keeps saying so`() {
        val b = Backend("https://abcdefghijklmnop.supabase.co", BackendKind.supabase)
        assertEquals("https://abcdefghijklmnop.supabase.co/functions/v1/pocketterm", b.api)
        val key = ChannelKey.generate()
        for (link in listOf(b.link, b.linkWithSetup("abc"), b.linkWithCode("K7QM", computer = ComputerKey("abcd1234", key)))) {
            assertEquals(b, Backend.fromLink(link), link)
        }
        assertEquals("abc", Backend.setupToken(b.linkWithSetup("abc")))
        // The same URL as a PocketTerm server is another server.
        assertNotEquals(b, Backend.fromLink("pocketterm://setup?url=https://abcdefghijklmnop.supabase.co"))
        // The function's own URL, pasted, is the project.
        assertEquals(b, Backend.parse("https://abcdefghijklmnop.supabase.co/functions/v1/pocketterm/v1", BackendKind.supabase).backend)
        // A kind this app doesn't know is no link it can use.
        val unknown = "pocketterm://setup?kind=firebase&url=https://x.example.com&setup=abc"
        assertNull(Backend.fromLink(unknown))
        assertNull(Backend.setupToken(unknown))
    }

    // check

    /** A server on a free port that answers every request with [answer]. */
    private fun answering(answer: (RecordedRequest, String) -> MockResponse): Backend {
        val server = MockWebServer()
        lateinit var url: String
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = answer(request, url)
        }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        closers.add { server.close() }
        url = "http://127.0.0.1:${server.port}"
        return Backend(url)
    }

    private fun json(body: String) = MockResponse.Builder().body(body).build()

    /** Stands in for packages/pocketterm_server: GET /v1/health as it answers. */
    private fun ownServer(): Backend = answering { _, _ ->
        json(jsonEncode(jsonOf("pocketterm" to 1, "version" to "0.1.7", "time" to dartIsoUtc(Instant.now()))))
    }

    /** A raw TCP server: [handle] gets each connection once its request head is read. */
    private fun raw(handle: (java.net.Socket) -> Unit): Backend {
        val server = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        closers.add { server.close() }
        thread(isDaemon = true) {
            while (!server.isClosed) {
                val socket = try { server.accept() } catch (_: Exception) { break }
                thread(isDaemon = true) {
                    val r = socket.getInputStream().bufferedReader()
                    while (r.readLine()?.isNotEmpty() == true) Unit
                    handle(socket)
                }
            }
        }
        return Backend("http://127.0.0.1:${server.localPort}")
    }

    @Test
    fun `a PocketTerm server passes - anything else answering is named`() = runBlocking<Unit> {
        assertNull(ownServer().check())
        val other = answering { _, _ -> json("<html>hello</html>") }
        assertTrue(other.check()!!.contains("No PocketTerm server"))
    }

    @Test
    fun `a server that drops the connection mid-answer is a message, not a throw`() = runBlocking<Unit> {
        // Answers half a status line, then hangs up.
        val b = raw { s ->
            s.getOutputStream().apply { write("HTTP/1.1 200".toByteArray()); flush() }
            s.close()
        }
        assertTrue(b.check()!!.contains("Couldn't reach"))
    }

    @Test
    fun `a server that sends its headers and then stalls the body times out with a message`() = runBlocking<Unit> {
        val b = raw { s ->
            s.getOutputStream().apply {
                write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{\"pocketterm\":".toByteArray())
                flush()
            }
            Thread.sleep(10_000)
            s.close()
        }
        val health = withTimeout(5.seconds) { b.health(wait = 300.milliseconds) }
        assertTrue(health.error!!.contains("took too long to answer"), health.error)
    }

    @Test
    fun `a device whose clock is off the server's is told - one close enough is not`() = runBlocking<Unit> {
        val ok = ownServer().health()
        assertNull(ok.error)
        assertNull(Backend.clockWarning(ok.clockOffset))

        val ahead = answering { _, _ ->
            json(
                jsonEncode(
                    jsonOf(
                        "pocketterm" to 1,
                        "version" to Backend.MIN_SERVER,
                        "time" to dartIsoUtc(Instant.now().plusSeconds(600)),
                    ),
                ),
            )
        }
        val skewed = ahead.health()
        assertNull(skewed.error)
        assertTrue(skewed.clockOffset!!.inWholeMinutes in 9..10)
        assertTrue(Backend.clockWarning(skewed.clockOffset)!!.contains("10 minutes behind"))
        assertTrue(Backend.clockWarning((-3).minutes)!!.contains("ahead of"))
        assertNull(Backend.clockWarning(90.seconds))
    }

    @Test
    fun `a server older than this app needs says to update it`() = runBlocking<Unit> {
        val old = answering { _, _ -> json(jsonEncode(jsonOf("pocketterm" to 1, "version" to "0.0.9"))) }
        assertTrue(old.check()!!.contains("Update the server"))
        val newer = answering { _, _ -> json(jsonEncode(jsonOf("pocketterm" to 1, "version" to "0.10.0"))) }
        assertNull(newer.check())
    }

    @Test
    fun `Cloudflare that can't reach the server, and a redirect loop, are named as such`() = runBlocking<Unit> {
        val cloudflare = answering { _, _ -> MockResponse.Builder().code(521).addHeader("cf-ray", "8a1b2c3d4e5f-FRA").build() }
        assertTrue(cloudflare.check()!!.contains("Cloudflare"))

        val loop = answering { _, url -> MockResponse.Builder().code(301).addHeader("location", "$url/v1/health").build() }
        assertTrue(loop.check()!!.contains("redirecting"))
    }

    // where the backend is kept (the desktop's shared preferences are the computer's, not ported here)

    @Test
    fun `a phone's is where its native side reads it`() = runBlocking<Unit> {
        val backend = Backend("https://pt.example.com")
        val supabase = Backend("https://abcdefghijklmnop.supabase.co", BackendKind.supabase)
        val native = BackendOnlyNative()
        backend.save(native)
        assertEquals(mapOf("url" to backend.url, "kind" to null), native.saved)
        assertEquals(backend, Backend.load(native))
        supabase.save(native)
        assertEquals(mapOf("url" to supabase.url, "kind" to "supabase"), native.saved)
        assertEquals(supabase, Backend.load(native))
        native.saved = mapOf("url" to "https://abc.supabase.co", "key" to "sb_x")
        assertNull(Backend.load(native), "a Supabase project from an app before")
        Backend.clear(native)
        assertNull(Backend.load(native))
    }
}
