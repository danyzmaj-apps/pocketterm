package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class E2eTest {
    private val key = ChannelKey(ByteArray(32) { it.toByte() })
    private val other = ChannelKey(ByteArray(32) { (255 - it).toByte() })
    private val topic = "abcd1234"

    // sealed bytes

    @Test
    fun `sealed bytes open with the same key and purpose, and come out as they went in`() {
        val plain = "a photo, really".toByteArray()
        val sealed = sealBytes(key, plain, imageAad("u1/x"))
        assertEquals(12 + plain.size + 16, sealed.size)
        assertFalse(String(sealed, Charsets.UTF_8).contains("photo"))
        assertContentEquals(plain, openBytes(key, sealed, imageAad("u1/x")))
    }

    @Test
    fun `two seals of the same bytes differ (a fresh nonce each time)`() {
        val a = sealBytes(key, byteArrayOf(1, 2, 3), pushAad("abcd1234"))
        val b = sealBytes(key, byteArrayOf(1, 2, 3), pushAad("abcd1234"))
        assertFalse(a.contentEquals(b))
    }

    @Test
    fun `a changed byte anywhere (nonce, ciphertext, tag) and they open to nothing`() {
        val sealed = sealBytes(key, "hello there".toByteArray(), imageAad("u1/x"))
        for (i in listOf(0, 11, 12, sealed.size - 17, sealed.size - 1)) {
            val changed = sealed.copyOf().also { it[i] = (it[i].toInt() xor 1).toByte() }
            assertNull(openBytes(key, changed, imageAad("u1/x")), "byte $i")
        }
        assertNull(openBytes(key, sealed.copyOfRange(0, 27), imageAad("u1/x")))
    }

    @Test
    fun `another key, or another purpose, and they open to nothing`() {
        val sealed = sealBytes(key, byteArrayOf(1, 2, 3), imageAad("u1/x"))
        assertNull(openBytes(other, sealed, imageAad("u1/x")))
        assertNull(openBytes(key, sealed, imageAad("u1/y")), "moved to another path")
        assertNull(openBytes(key, sealed, pushAad("abcd1234")), "taken for a push")
    }

    // envelopes

    @Test
    fun `envelopes round trip a JSON object`() {
        val env = sealEnvelope(key, jsonOf("a" to 1, "b" to "two"), channelAad(topic, "state"))
        assertEquals(setOf("v", "n", "c"), env.keys)
        assertFalse(jsonEncode(env).contains("two"))
        assertEquals(jsonOf("a" to 1, "b" to "two"), openEnvelope(key, env, channelAad(topic, "state")).message)
    }

    @Test
    fun `envelopes moved to another event or computer, changed, or of another version, are dropped`() {
        val env = sealEnvelope(key, jsonOf("a" to 1), channelAad(topic, "state"))
        fun with(k: String, v: Any) = JsonObject(env + (k to v.toJsonElement()))
        assertEquals("sealed", openEnvelope(key, env, channelAad(topic, "run")).drop)
        assertEquals("sealed", openEnvelope(key, env, channelAad("zzzz9999", "state")).drop)
        val c = base64DecodeOrNull(env["c"].str!!)!!.also { it[0] = (it[0].toInt() xor 1).toByte() }
        assertEquals("sealed", openEnvelope(key, with("c", base64Encode(c)), channelAad(topic, "state")).drop)
        assertEquals("version", openEnvelope(key, with("v", 2), channelAad(topic, "state")).drop)
        assertEquals("version", openEnvelope(key, jsonOf("windows" to 3), channelAad(topic, "state")).drop)
        assertEquals("sealed", openEnvelope(key, with("n", "not base64!"), channelAad(topic, "state")).drop)
    }

    // the live channel

    private val start = java.time.LocalDateTime.of(2026, 10, 22, 12, 0).atZone(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
    private var now = start
    private val clock: () -> Long = { now }
    private val phone = ChannelSeal(key, topic, clock = clock)
    private val desktop = ChannelSeal(key, topic, clock = clock)

    @Test
    fun `both ways, each side reads what the other sealed, as it was`() {
        assertEquals(jsonOf("from" to "p1"), desktop.open("hello", phone.seal("hello", jsonOf("from" to "p1"))))
        val windows = jsonOf("windows" to JsonArray(emptyList()))
        assertEquals(windows, phone.open("state", desktop.seal("state", windows)))
    }

    @Test
    fun `a payload's own seq, ts, mid and ep come through untouched (an items catch-up carries the log's seq)`() {
        val items = jsonOf("session" to "s1", "epoch" to "e1", "seq" to 42, "ts" to 7, "mid" to "m", "ep" to "x", "items" to JsonArray(emptyList()))
        assertEquals(items, phone.open("items", desktop.seal("items", items)))
    }

    @Test
    fun `the computer takes a phone message once - the server replaying it gets nothing through`() {
        val wire = phone.seal("run", jsonOf("id" to "r1", "op" to "send"))
        assertNotNull(desktop.open("run", wire))
        assertNull(desktop.open("run", wire))
        now += 3 * 60_000
        assertNull(desktop.open("run", wire), "still remembered within 10 minutes")
    }

    @Test
    fun `a message more than 5 minutes off the clock is dropped, either way`() {
        val fromPhone = phone.seal("hello", jsonOf("from" to "p1"))
        val fromDesktop = desktop.seal("state", jsonOf("windows" to 1))
        now += 5 * 60_000 + 1_000
        assertNull(desktop.open("hello", fromPhone))
        assertNull(phone.open("state", fromDesktop))
    }

    @Test
    fun `a message sealed with another computer key is dropped`() {
        val stranger = ChannelSeal(other, topic, clock = clock)
        assertNull(desktop.open("hello", stranger.seal("hello", jsonOf("from" to "p1"))))
    }

    @Test
    fun `a phone's command replayed to the computer's next channel (the bridge restarted) is dropped`() {
        val guard = ReplayGuard(clock = clock)
        val first = ChannelSeal(key, topic, guard = guard, clock = clock)
        val wire = phone.seal("run", jsonOf("id" to "r1", "op" to "send"))
        assertNotNull(first.open("run", wire))
        now += 60_000
        val next = ChannelSeal(key, topic, guard = guard, clock = clock)
        assertNull(next.open("run", wire))
        assertEquals(jsonOf("id" to "r2"), next.open("run", phone.seal("run", jsonOf("id" to "r2"))))
    }

    @Test
    fun `a message sealed before the app started is dropped, a fresh one after it goes through`() {
        val wire = phone.seal("run", jsonOf("id" to "r1", "op" to "send"))
        now += 30_000
        val restarted = ChannelSeal(key, topic, clock = clock)
        assertNull(restarted.open("run", wire))
        assertEquals(jsonOf("id" to "r2"), restarted.open("run", phone.seal("run", jsonOf("id" to "r2"))))
    }

    @Test
    fun `the phone drops the computer's messages replayed or out of order`() {
        val first = desktop.seal("screen", jsonOf("n" to 1))
        val second = desktop.seal("screen", jsonOf("n" to 2))
        val third = desktop.seal("ran", jsonOf("id" to "r1"))
        assertEquals(jsonOf("n" to 2), phone.open("screen", second))
        assertNull(phone.open("screen", first), "older than one already taken")
        assertNull(phone.open("screen", second), "replayed")
        assertEquals(jsonOf("id" to "r1"), phone.open("ran", third))
        assertNull(phone.open("ran", third))
    }

    @Test
    fun `a sender that starts again (new epoch) goes through - its old messages still do not`() {
        val guard = ReplayGuard(clock = clock)
        val computer = ChannelSeal(key, topic, guard = guard, clock = clock)
        val old = phone.seal("run", jsonOf("id" to "r1"))
        assertNotNull(computer.open("run", old))
        val relaunched = ChannelSeal(key, topic, clock = clock)
        assertEquals(jsonOf("from" to "p1"), computer.open("hello", relaunched.seal("hello", jsonOf("from" to "p1"))))
        assertEquals(jsonOf("id" to "r2"), computer.open("run", relaunched.seal("run", jsonOf("id" to "r2"))))
        assertNull(computer.open("run", old))
        assertEquals(jsonOf("id" to "r3"), computer.open("run", phone.seal("run", jsonOf("id" to "r3"))))
    }

    @Test
    fun `a message without its epoch and count is dropped`() {
        val env = sealEnvelope(key, jsonOf("id" to "r1", "ts" to now, "mid" to newMessageId()), channelAad(topic, "run"))
        assertNull(desktop.open("run", env))
    }

    @Test
    fun `epochs past the limit are forgotten oldest first - the newest still refuse a replay`() {
        val guard = ReplayGuard(clock = clock, maxEpochs = 2)
        fun msg(ep: String, seq: Int) = jsonOf("ts" to now, "mid" to newMessageId(), "ep" to ep, "seq" to seq)
        for (ep in listOf("a", "b", "c")) assertNull(guard.check(msg(ep, 5)))
        assertEquals("order", guard.check(msg("c", 5)))
        assertEquals("order", guard.check(msg("b", 4)))
        assertNull(guard.check(msg("a", 1)), "forgotten")
    }

    @Test
    fun `a sealed push opens for that computer's phones, with a time and an id inside`() {
        val before = System.currentTimeMillis()
        val a = sealNotice(key, topic, jsonOf("title" to "Claude", "body" to "Needs approval"))
        val b = sealNotice(key, topic, jsonOf("title" to "Claude", "body" to "Needs approval"))
        fun open(s: String) = jsonDecode(String(openBytes(key, base64DecodeOrNull(s)!!, pushAad(topic))!!, Charsets.UTF_8)).obj!!
        val opened = open(a)
        val again = open(b)
        assertEquals("Claude", opened["title"].str)
        assertTrue(opened["ts"].long!! >= before)
        assertNotEquals(again["id"], opened["id"])
        assertNull(openBytes(key, base64DecodeOrNull(a)!!, pushAad("zzzz9999")))
        val activity = sealActivity(key, topic, jsonOf("session" to "s1", "state" to "working"))
        assertNull(openBytes(key, base64DecodeOrNull(activity)!!, pushAad(topic)))
        assertNotNull(openBytes(key, base64DecodeOrNull(activity)!!, activityAad(topic)))
    }

    @Test
    fun `a push names its computer and session only by tags made with that computer's key`() {
        // The same values the phone's Swift and Kotlin code compute (PocketTermShared): a mismatch would leave every
        // push showing the generic alert.
        val seven = ChannelKey(ByteArray(32) { 7 })
        val nine = ChannelKey(ByteArray(32) { 9 })
        assertEquals("RJM0r7AxRLM", pushTag(seven))
        assertEquals("xx8kW7GbrvA", pushTag(nine))
        assertEquals("yMPqtkm1TA3-r0AeuNDSHg", sessionTag(seven, "abcd1234/kitty-1/2"))
        assertNotEquals("yMPqtkm1TA3-r0AeuNDSHg", sessionTag(seven, "abcd1234/kitty-1/3"))
        assertNotEquals("yMPqtkm1TA3-r0AeuNDSHg", sessionTag(nine, "abcd1234/kitty-1/2"))
    }

    @Test
    fun `a key reads back from both of its spellings - anything else is no key`() {
        assertEquals(key, ChannelKey.tryParse(key.toBase64()))
        assertEquals(key, ChannelKey.tryParse(key.toBase64Url()))
        assertFalse(key.toBase64Url().contains('='))
        assertNull(ChannelKey.tryParse(base64Encode(ByteArray(16) { 1 })))
        assertNull(ChannelKey.tryParse("not a key"))
        assertNull(ChannelKey.tryParse(null))
        assertNotEquals(ChannelKey.generate(), ChannelKey.generate())
    }
}
