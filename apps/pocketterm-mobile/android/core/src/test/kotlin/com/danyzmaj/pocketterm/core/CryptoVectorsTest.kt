package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

/** tool/vectors/vectors.json `crypto` and `replayGuard`. */
class CryptoVectorsTest {
    private val crypto = Vectors.section("crypto")
    private val keys = crypto["keys"].obj!!

    private fun key(name: String?): ChannelKey = ChannelKey(Vectors.hex(keys[name ?: "key"].obj!!["hex"].str!!))

    private fun cases(name: String) = crypto[name].arr!!.map { it.obj!! }

    @Test
    fun constants() {
        val c = crypto["constants"].obj!!
        assertEquals(c["sealedOverhead"].int, sealedOverhead)
        assertEquals(c["envelopeVersion"].int, envelopeVersion)
        assertEquals(c["keyLength"].int, ChannelKey.LENGTH)
        assertEquals(c["nonceLength"].int!! + c["tagLength"].int!!, sealedOverhead)
    }

    @Test
    fun keys() {
        for ((name, k) in keys) {
            val o = k.obj!!
            val key = ChannelKey(Vectors.hex(o["hex"].str!!))
            assertEquals(o["base64"].str, key.toBase64(), name)
            assertEquals(o["base64url"].str, key.toBase64Url(), name)
            assertEquals(key, ChannelKey.tryParse(o["base64"].str))
            assertEquals(key, ChannelKey.tryParse(o["base64url"].str))
        }
    }

    @Test
    fun keyParse() {
        for (c in cases("keyParse")) {
            val parsed = ChannelKey.tryParse(c["input"].str)
            assertEquals(c["hex"].str, parsed?.let { Vectors.toHex(it.bytes) }, c["note"].str)
        }
    }

    @Test
    fun aad() {
        for (c in cases("aad")) {
            val args = c["args"].arr!!.map { it.str!! }
            val got = when (c["fn"].str) {
                "channel" -> channelAad(args[0], args[1])
                "image" -> imageAad(args[0])
                "push" -> pushAad(args[0])
                "activity" -> activityAad(args[0])
                else -> error("fn ${c["fn"]}")
            }
            assertEquals(c["aad"].str, got)
        }
    }

    @Test
    fun pushTag() {
        for (c in cases("pushTag")) assertEquals(c["tag"].str, pushTag(key(c["key"].str)), c["note"].str)
    }

    @Test
    fun sessionTag() {
        for (c in cases("sessionTag")) assertEquals(c["tag"].str, sessionTag(key(c["key"].str), c["routedKey"].str!!), c["note"].str)
    }

    @Test
    fun open() {
        for (c in cases("open")) {
            val plain = openBytes(key(c["key"].str), Vectors.b64(c["sealed"].str!!), c["aad"].str!!)
            assertContentEquals(Vectors.b64(c["plain"].str!!), plain, c["note"].str)
        }
    }

    @Test
    fun sealFixedNonce() {
        for (c in cases("sealFixedNonce")) {
            val sealed = sealBytesWithNonce(key(c["key"].str), Vectors.b64(c["plain"].str!!), c["aad"].str!!, Vectors.b64(c["nonce"].str!!))
            assertEquals(c["sealed"].str, base64Encode(sealed), c["note"].str)
        }
    }

    @Test
    fun openFails() {
        for (c in cases("openFails")) {
            val plain = openBytes(key(c["key"].str), Vectors.b64(c["sealed"].str!!), c["aad"].str!!)
            assertEquals(c["plain"].str, plain?.let { base64Encode(it) }, c["note"].str)
        }
    }

    @Test
    fun envelopes() {
        for (c in cases("envelopes")) {
            assertEquals(channelAad(c["topic"].str!!, c["event"].str!!), c["aad"].str)
            val opened = openEnvelope(key(c["key"].str), c["envelope"].obj!!, c["aad"].str!!)
            assertNull(opened.drop, c["note"].str)
            assertEquals(c["message"].obj, opened.message, c["note"].str)
        }
    }

    @Test
    fun envelopeDrops() {
        for (c in cases("envelopeDrops")) {
            val opened = openEnvelope(key(c["key"].str), c["envelope"].obj!!, c["aad"].str!!)
            assertEquals(c["drop"].str, opened.drop, c["note"].str)
            assertEquals(c["message"].obj, opened.message, c["note"].str)
        }
    }

    @Test
    fun channelOpen() {
        val rows = cases("channelOpen")
        var now = rows[0]["startMs"].long!!
        val receiver = ChannelSeal(key(null), "abcd1234", clock = { now })
        for (c in rows.drop(1)) {
            now = c["nowMs"].long!!
            val payload = receiver.open(c["event"].str!!, c["envelope"].obj!!)
            val expected = c["payload"]
            assertEquals(if (expected == null || expected is JsonNull) null else expected.obj, payload, c["note"].str)
        }
    }

    private fun checkPush(name: String, other: (String) -> String) {
        for (c in cases(name)) {
            val k = key(c["key"].str)
            val enc = Vectors.b64(c["enc"].str!!)
            val inner = jsonDecode(String(openBytes(k, enc, c["aad"].str!!)!!, Charsets.UTF_8)).obj!!
            assertEquals(c["inner"].obj, inner, c["note"].str)
            val input = c["input"].obj!!
            assertEquals(JsonObject(inner.filterKeys { it != "ts" && it != "id" }), input)
            assertEquals(16, inner["id"].str!!.length)
            assertNull(openBytes(k, enc, other(c["desktop"].str!!)))
            // Sealing it now opens to the same input, with a fresh ts and id.
            val fresh = if (name == "notices") sealNotice(k, c["desktop"].str!!, input) else sealActivity(k, c["desktop"].str!!, input)
            val reopened = jsonDecode(String(openBytes(k, Vectors.b64(fresh), c["aad"].str!!)!!, Charsets.UTF_8)).obj!!
            assertEquals(input, JsonObject(reopened.filterKeys { it != "ts" && it != "id" }))
        }
    }

    @Test
    fun notices() {
        for (c in cases("notices")) assertEquals(pushAad(c["desktop"].str!!), c["aad"].str)
        checkPush("notices") { activityAad(it) }
    }

    @Test
    fun activities() {
        for (c in cases("activities")) assertEquals(activityAad(c["desktop"].str!!), c["aad"].str)
        checkPush("activities") { pushAad(it) }
    }

    @Test
    fun images() {
        for (c in cases("images")) {
            val k = key(c["key"].str)
            assertEquals(imageAad(c["path"].str!!), c["aad"].str)
            val sealed = Vectors.b64(c["sealed"].str!!)
            assertContentEquals(Vectors.b64(c["plain"].str!!), openBytes(k, sealed, c["aad"].str!!))
            val opensWithOther = openBytes(k, sealed, imageAad(c["path"].str!! + "x")) != null
            assertEquals(c["opensWithOtherPath"].bool, opensWithOther)
            assertFalse(opensWithOther)
        }
    }

    @Test
    fun replayGuard() {
        for (s in Vectors.section("replayGuard")["scenarios"].arr!!.map { it.obj!! }) {
            var now = s["startMs"].long!!
            val guard = ReplayGuard(
                window = kotlin.time.Duration.parse("${s["windowMs"].long}ms"),
                remember = kotlin.time.Duration.parse("${s["rememberMs"].long}ms"),
                maxEpochs = s["maxEpochs"].int!!,
                maxIds = s["maxIds"].int!!,
                clock = { now },
            )
            assertEquals(now, guard.notBefore)
            for (step in s["steps"].arr!!.map { it.obj!! }) {
                now = step["nowMs"].long!!
                assertEquals(step["result"].str, guard.check(step["message"].obj!!), "${s["note"].str}: ${step["note"].str}")
            }
        }
    }
}
