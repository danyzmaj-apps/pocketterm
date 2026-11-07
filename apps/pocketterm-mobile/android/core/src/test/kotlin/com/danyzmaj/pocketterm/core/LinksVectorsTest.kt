package com.danyzmaj.pocketterm.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Duration.Companion.seconds

/** tool/vectors/vectors.json `links`. */
class LinksVectorsTest {
    private val links = Vectors.section("links")

    private fun cases(name: String) = links[name].arr!!.map { it.obj!! }

    @Test
    fun parse() {
        for (c in cases("parse")) {
            val note = c["note"].str
            assertEquals("pocketterm", c["kind"].str ?: "pocketterm", note)
            val parsed = Backend.parse(c["input"].str!!)
            assertEquals(c["error"].str, parsed.error, note)
            val e = c["backend"].obj
            val b = parsed.backend
            if (e == null) {
                assertEquals(null, b, note)
                continue
            }
            b!!
            assertEquals(e["url"].str, b.url, note)
            assertEquals("pocketterm", e["kind"].str ?: "pocketterm", note)
            assertEquals(e["api"].str, b.api, note)
            assertEquals(e["host"].str, b.host, note)
            assertEquals(e["onTailnet"].bool, b.onTailnet, note)
            assertEquals(e["unreachable"].str, b.unreachable, note)
        }
    }

    @Test
    fun build() {
        for (c in cases("build")) {
            val e = c["backend"].obj!!
            val b = Backend(e["url"].str!!)
            val link = when (c["fn"].str) {
                "link" -> b.link
                "linkWithSetup" -> b.linkWithSetup(c["setup"].str!!)
                "linkWithCode" -> b.linkWithCode(
                    c["code"].str!!,
                    c["computer"].obj?.let { ComputerKey(it["desktop"].str!!, ChannelKey(Vectors.hex(it["keyHex"].str!!))) },
                )
                else -> error("fn ${c["fn"]}")
            }
            assertEquals(c["link"].str, link, c["note"].str)
        }
    }

    @Test
    fun read() {
        for (c in cases("read")) {
            val note = c["note"].str
            val link = c["link"].str!!
            val b = Backend.fromLink(link)
            val e = c["backend"].obj
            assertEquals(e?.let { Backend(it["url"].str!!) }, b, note)
            assertEquals(c["pairingCode"].str, Backend.pairingCode(link), note)
            assertEquals(c["setupToken"].str, Backend.setupToken(link), note)
            val k = Backend.computerKey(link)
            val ek = c["computerKey"].obj
            assertEquals(ek?.get("desktop").str, k?.desktop, note)
            assertEquals(ek?.get("keyHex").str, k?.let { Vectors.toHex(it.key.bytes) }, note)
        }
    }

    @Test
    fun clockWarning() {
        for (c in cases("clockWarning")) {
            assertEquals(c["warning"].str, Backend.clockWarning(c["offsetSeconds"].long?.seconds), c["note"].str)
        }
    }

    @Test
    fun constants() {
        val c = links["constants"].obj!!
        assertEquals(c["protocol"].int, Backend.PROTOCOL)
        assertEquals(c["minServer"].str, Backend.MIN_SERVER)
        assertEquals(c["clockToleranceSeconds"].long, Backend.clockTolerance.inWholeSeconds)
    }
}
