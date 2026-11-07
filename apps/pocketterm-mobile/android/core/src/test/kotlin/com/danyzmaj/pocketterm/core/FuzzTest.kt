package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.Random
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Inputs a parser meets in the wild and some it never should (packages/pocketterm_core/test/fuzz_test.dart):
 * random bytes read as text, very long lines, unicode, the separators links use, and JSON of any shape.
 * Seeded, so a failure names its input and replays.
 */
private class Gen(seed: Int) {
    val r = Random(seed.toLong())

    fun text(max: Int = 200): String {
        val b = StringBuilder()
        repeat(r.nextInt(max)) {
            when (r.nextInt(4)) {
                0 -> b.append(r.nextInt(0x3000).toChar())
                1 -> b.append(PIECES[r.nextInt(PIECES.size)])
                else -> b.append((32 + r.nextInt(95)).toChar())
            }
        }
        return b.toString()
    }

    /** Random bytes, decoded the way a process's output is (malformed allowed). */
    fun bytes(max: Int = 400): String = String(ByteArray(r.nextInt(max)) { r.nextInt(256).toByte() }, Charsets.UTF_8)

    fun long(): String = text(20).repeat(1000 + r.nextInt(4000))

    fun json(depth: Int = 0): JsonElement = when (if (depth > 3) r.nextInt(5) else r.nextInt(7)) {
        0 -> JsonNull
        1 -> JsonPrimitive(r.nextBoolean())
        2 -> JsonPrimitive((r.nextInt().toLong() and 0x7fffffff) - (1L shl 30))
        3 -> JsonPrimitive(r.nextDouble() * 1e6)
        4 -> JsonPrimitive(text(30))
        5 -> JsonArray(List(r.nextInt(4)) { json(depth + 1) })
        else -> JsonObject(List(r.nextInt(5)) { key() to json(depth + 1) }.toMap())
    }

    fun key(): String = if (r.nextInt(4) == 0) text(8) else KEYS[r.nextInt(KEYS.size)]

    fun any(): String = when (r.nextInt(4)) {
        0 -> bytes()
        1 -> long()
        2 -> jsonEncode(json())
        else -> text()
    }

    companion object {
        val PIECES = listOf(
            "\t", "\n", "\r\n", " ", "\"", "'", "\\", "{", "}", "[", "]", ":", ",", "/", "=", "&", "?", "#", "%", "@",
            "\u001b[", "\u001b]", "m", ";", "38;5;", "48;2;", "0", "1", "255", "-1", "99999999999999999999", "NaN",
            "kitty-1/2", "tmux:", "pocketterm://setup?", "url=", "key=", "code=", "https://", "http://10.", "!", "tmr",
            "3pm", "9.30", "é", "\u0301", "😀", "👩‍💻", "\u202e", "\u0000", "\uFFFD", "\uD83D", "ж", "中文", "❯", "│", "─", "›", "●",
            // What a link and an envelope carry.
            "%3D", "%2F", "+", "-", "_", "d=", "k=", "kind=supabase", "setup=", "v", "n", "c",
        )
        val KEYS = listOf("id", "title", "ts", "mid", "ep", "seq", "m", "v", "n", "c", "url", "kind", "code", "pocketterm", "name")
    }
}

class FuzzTest {
    /** Runs [body] on [rounds] generated inputs: it must never throw, and each round must be quick. */
    private fun property(rounds: Int = 300, body: (Gen) -> Unit) {
        for (seed in 0 until rounds) {
            val started = System.nanoTime()
            try {
                body(Gen(seed))
            } catch (e: Throwable) {
                fail("seed $seed: $e", e)
            }
            assertTrue(System.nanoTime() - started < 2_000_000_000L, "seed $seed hangs")
        }
    }

    private val key = ChannelKey(ByteArray(32) { it.toByte() })

    @Test
    fun `Backend fromLink, pairingCode and parse take anything`() = property { g ->
        for (raw in listOf(
            g.text(),
            g.bytes(),
            "pocketterm://setup?${g.text()}",
            "pocketterm://setup?url=${g.text()}&setup=${g.text()}&code=${g.text()}",
            "pocketterm://setup?url=https://pt.example.com&code=${g.text()}&d=${g.text()}&k=${g.text()}",
        )) {
            if (DartUri.tryParse(raw) != null) {
                Backend.fromLink(raw)
                Backend.pairingCode(raw)
                Backend.setupToken(raw)
                Backend.computerKey(raw)
            }
            Backend.parse(raw)
        }
    }

    @Test
    fun `channel keys parse anything`() = property { g ->
        ChannelKey.tryParse(g.text())
        ChannelKey.tryParse(g.bytes())
    }

    @Test
    fun `envelopes of any shape are dropped, never thrown on`() = property { g ->
        val aad = channelAad("abcd1234", "state")
        val shaped = g.json()
        if (shaped is JsonObject) assertTrue(openEnvelope(key, shaped, aad).drop != null)
        val env = jsonOf("v" to 1, "n" to g.text(24), "c" to g.text(80))
        assertTrue(openEnvelope(key, env, aad).drop != null)
        // A real envelope with a part swapped for random JSON.
        val real = sealEnvelope(key, jsonOf("a" to 1), aad)
        val part = listOf("v", "n", "c")[g.r.nextInt(3)]
        val changed = JsonObject(real + (part to g.json()))
        openEnvelope(key, changed, aad)
        openBytes(key, g.bytes().toByteArray(), aad)
        base64DecodeOrNull(g.text())
    }

    @Test
    fun `the replay guard and the channel seal take messages of any shape`() = property(rounds = 100) { g ->
        var now = 1_792_670_400_000L
        val guard = ReplayGuard(clock = { now }, maxEpochs = 4, maxIds = 16)
        val seal = ChannelSeal(key, "abcd1234", guard = guard, clock = { now })
        repeat(50) {
            now += g.r.nextInt(120_000)
            val message = when (g.r.nextInt(3)) {
                0 -> g.json() as? JsonObject ?: jsonOf()
                1 -> jsonOf("ts" to now + g.r.nextInt(600_000) - 300_000, "mid" to g.text(4), "ep" to g.text(2), "seq" to g.r.nextInt(5) - 1)
                else -> jsonOf("ts" to g.json(), "mid" to g.json(), "ep" to g.json(), "seq" to g.json())
            }
            guard.check(message)
            seal.open("state", sealEnvelope(key, message, channelAad("abcd1234", "state")))
        }
    }

    @Test
    fun `sniffing random bytes`() = property { g ->
        sniffImageType(ByteArray(g.r.nextInt(64)) { g.r.nextInt(256).toByte() })
    }

    @Test
    fun `file types of any name`() = property { g ->
        val s = g.any()
        fileMime(s)
        fileExtension(s)
        mimeExtension(s)
    }
}
