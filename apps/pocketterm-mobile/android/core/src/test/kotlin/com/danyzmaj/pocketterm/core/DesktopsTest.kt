package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

class DesktopsTest {
    private val client = PocketTermServerClient(Backend("http://localhost:1"), tokens = MemoryDeviceTokens())

    private fun row(id: String, ago: Duration, platform: String = "macos") = jsonOf(
        "id" to id,
        "name" to "Computer $id",
        "platform" to platform,
        "seen_at" to dartIsoUtc(Instant.now().minusMillis(ago.inWholeMilliseconds)),
    )

    /** A phone signed in to [url] (its sign-in as kept), without asking the server. */
    private suspend fun signedInPhone(url: String): PocketTermServerClient {
        val kept = jsonEncode(
            jsonOf(
                "url" to url,
                "token" to "t",
                "server" to "srv",
                "device" to jsonOf("id" to "dev0000000000000", "role" to "phone", "label" to "Phone", "platform" to "android"),
            ),
        )
        return PocketTermServerClient(Backend(url), MemoryDeviceTokens(kept)).also { it.load() }
    }

    @Test
    fun `the computer last shown stays shown while it is listed, even when another was seen since`() {
        val changes = mutableListOf<String?>()
        val d = Desktops(client, saved = "bbbbbbbb", onChanged = { _, id -> changes.add(id) })
        d.apply(listOf(row("aaaaaaaa", Duration.ZERO), row("bbbbbbbb", 2.hours)))
        assertEquals("bbbbbbbb", d.selected?.id)
        assertEquals(listOf<String?>("bbbbbbbb"), changes)
    }

    @Test
    fun `with the last one gone, the newest seen is shown and kept as the computers take turns`() {
        val d = Desktops(client, saved = "gone0000")
        d.apply(listOf(row("aaaaaaaa", Duration.ZERO), row("bbbbbbbb", 1.minutes)))
        assertEquals("aaaaaaaa", d.selected?.id)
        d.apply(listOf(row("bbbbbbbb", Duration.ZERO), row("aaaaaaaa", 1.minutes)))
        assertEquals("aaaaaaaa", d.selected?.id)
    }

    @Test
    fun `none listed, none shown - a computer not seen for 30 days is not listed`() {
        val d = Desktops(client)
        d.apply(emptyList())
        assertNull(d.selected)
        d.apply(listOf(row("aaaaaaaa", 31.days)))
        assertTrue(d.all.isEmpty())
        assertNull(d.selected)
    }

    @Test
    fun `the person picks a listed computer only`() {
        val changes = mutableListOf<String?>()
        val d = Desktops(client, onChanged = { _, id -> changes.add(id) })
        d.apply(listOf(row("aaaaaaaa", Duration.ZERO), row("bbbbbbbb", Duration.ZERO, platform = "windows")))
        d.select("bbbbbbbb")
        d.select("cccccccc")
        assertEquals("bbbbbbbb", d.selected?.id)
        assertTrue(d.selected!!.windows)
        assertEquals(listOf<String?>("aaaaaaaa", "bbbbbbbb"), changes)
    }

    @Test
    fun `a computer asked for (its code scanned) is shown once listed, over one seen later`() {
        val d = Desktops(client)
        d.apply(listOf(row("aaaaaaaa", Duration.ZERO)))
        d.show("bbbbbbbb")
        assertEquals("aaaaaaaa", d.selected?.id, "not listed yet")
        d.apply(listOf(row("cccccccc", Duration.ZERO), row("bbbbbbbb", 1.minutes)))
        assertEquals("bbbbbbbb", d.selected?.id)
        d.apply(listOf(row("aaaaaaaa", Duration.ZERO), row("bbbbbbbb", 1.minutes)))
        assertEquals("bbbbbbbb", d.selected?.id, "asked for once, then kept like any choice")
        d.show("aaaaaaaa")
        assertEquals("aaaaaaaa", d.selected?.id)
    }

    @Test
    fun `the cached list shows the computer last shown before the server answers`() {
        val cached = Desktop.fromJson(row("bbbbbbbb", 5.minutes))
        val d = Desktops(client, cached = listOf(cached), saved = "bbbbbbbb")
        assertFalse(d.loaded)
        assertEquals(cached, d.selected)
        assertEquals(cached, Desktop.fromJson(cached.toJson()))
    }

    @Test
    fun `online means seen within two and a half minutes`() {
        assertTrue(Desktop.fromJson(row("aaaaaaaa", 140.seconds)).online)
        assertFalse(Desktop.fromJson(row("aaaaaaaa", 160.seconds)).online)
    }

    @Test
    fun `a server that stops answering keeps the list there is and says why, until a list comes`() = runBlocking<Unit> {
        // Nothing listens there any more.
        val closed = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val port = closed.localPort
        closed.close()
        val phone = signedInPhone("http://127.0.0.1:$port")
        val cached = Desktop.fromJson(row("bbbbbbbb", 5.minutes))
        val d = Desktops(phone, cached = listOf(cached), saved = "bbbbbbbb")
        var told = 0
        d.addListener { told++ }
        d.refresh()
        assertEquals(phone.backend.unreachable, d.error)
        assertEquals(cached, d.selected)
        assertEquals(1, told)
        d.refresh()
        assertEquals(1, told, "the same problem again is no news")
        d.apply(listOf(row("aaaaaaaa", Duration.ZERO)))
        assertNull(d.error)
    }

    @Test
    fun `a list that comes after the phone left the server isn't kept for the next sign-in`() = runBlocking<Unit> {
        val server = MockWebServer()
        server.enqueue(
            MockResponse.Builder()
                .body(jsonEncode(kotlinx.serialization.json.JsonArray(listOf(row("aaaaaaaa", Duration.ZERO)))))
                .headersDelay(300, TimeUnit.MILLISECONDS)
                .build(),
        )
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        try {
            val phone = signedInPhone("http://127.0.0.1:${server.port}")
            val kept = mutableListOf<List<Desktop>>()
            val d = Desktops(phone, onChanged = { all, _ -> kept.add(all) })
            val refreshed = async(start = CoroutineStart.UNDISPATCHED) { d.refresh() }
            d.dispose()
            refreshed.await()
            assertTrue(kept.isEmpty())
            assertEquals(1, server.requestCount)
        } finally {
            server.close()
        }
    }

    @Test
    fun `a Tailscale address that gets no answer says to connect Tailscale on this device`() = runBlocking<Unit> {
        val tailnet = Backend("https://my-mac.tail1234.ts.net")
        assertTrue(tailnet.onTailnet)
        assertTrue(tailnet.unreachable.contains("open Tailscale on this device"))
        val vps = Backend("https://pocketterm.example.com")
        assertFalse(vps.onTailnet)
        assertFalse(vps.unreachable.contains("Tailscale"))
        // Nothing listens there: the client's offline answer is the backend's.
        val closed = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val port = closed.localPort
        closed.close()
        val client = PocketTermServerClient(Backend("http://127.0.0.1:$port"), tokens = MemoryDeviceTokens())
        val e = assertFailsWith<ServerException> { client.redeemCode("K7QM", label = "iPhone", platform = "ios") }
        assertEquals(client.backend.unreachable, e.message)
    }
}
