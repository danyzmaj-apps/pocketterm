package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** tool/vectors `terminal` (phone-side keys) and `live.models` TermWindow / TermStatus. */
class TerminalVectorsTest {
    private val t = Vectors.section("terminal")

    @Test
    fun windowOfTerm() {
        for (c in t["windowOfTerm"].arr!!) {
            val o = c.obj!!
            assertEquals(o["window"].str, windowOfTerm(o["term"].obj), o["note"].str)
        }
    }

    @Test
    fun tmuxSocketName() {
        for (c in t["tmuxSocketName"].arr!!) assertEquals(c.obj!!["ok"].bool, tmuxSocketName(c.obj!!["name"].str!!), c.obj!!["name"].str)
    }

    @Test
    fun keyBytes() {
        for (c in t["keyBytes"].arr!!) {
            val o = c.obj!!
            val name = o["name"].str!!
            val error = o["error"].str
            if (error != null) {
                val e = runCatching { keyBytes(name) }.exceptionOrNull()
                assertTrue(e is TerminalException, name)
                assertEquals(error, e.message)
            } else {
                val b = keyBytes(name)
                assertEquals(o["bytes"].str, b, name)
                assertEquals(o["hex"].str, Vectors.toHex(b.toByteArray(Charsets.UTF_8)), name)
            }
        }
    }

    @Test
    fun keyRuns() {
        for (c in t["keyRuns"].arr!!) {
            val o = c.obj!!
            assertEquals(o["runs"].arr!!.map { it.str }, keyRuns(o["names"].arr!!.map { it.str!! }), o["note"].str)
        }
    }

    @Test
    fun phoneKeys() = assertEquals(t["phoneKeys"].arr!!.map { it.str }, phoneKeys.toList())

    @Test
    fun textChunks() {
        for (c in t["textChunks"].arr!!) {
            val o = c.obj!!
            assertEquals(o["chunks"].arr!!.map { it.str }, textChunks(Vectors.text(o["text"])!!, o["maxBytes"].int!!), o["note"].str)
        }
    }

    @Test
    fun cleanTitle() {
        val v = t["cleanTitle"].obj!!
        assertEquals(v["titleRunes"].int, titleRunes)
        for (c in v["cases"].arr!!) {
            val o = c.obj!!
            assertTrue(Vectors.matches(o["title"], cleanTitle(Vectors.text(o["input"])!!)), o["note"].str)
        }
    }

    @Test
    fun screenLines() {
        val v = t["screenLines"].obj!!
        assertEquals(v["historyBytes"].int, historyBytes)
        for (c in v["cases"].arr!! + v["long"].arr!!) {
            val o = c.obj!!
            val expected = o["lines"].arr!!
            val actual = screenLines(Vectors.text(o["input"])!!)
            assertEquals(expected.size, actual.size, o["note"].str)
            expected.zip(actual).forEach { (e, a) -> assertTrue(Vectors.matches(e, a), o["note"].str) }
        }
    }

    @Test
    fun caps() {
        val v = t["caps"].obj!!
        assertEquals(v["all"].arr!!.map { it.str }, TermCap.entries.map { it.name })
        assertEquals(v["allCaps"].arr!!.map { it.str }, allCaps.map { it.name })
        assertEquals(v["termStates"].arr!!.map { it.str }, TermState.entries.map { it.name })
        for (p in v["placement"].arr!!) {
            assertEquals(p.obj!!["describe"].str, Placement.valueOf(p.obj!!["name"].str!!).describe)
        }
        assertEquals(v["placement"].arr!!.map { it.obj!!["name"].str }, Placement.entries.map { it.name })
    }

    @Test
    fun termWindowModels() {
        for (c in Vectors.section("live")["models"].obj!!["TermWindow"].arr!!) {
            val o = c.obj!!
            val w = TermWindow.fromJson(o["input"].obj!!)
            assertEquals(jsonEncode(o["output"]!!), jsonEncode(w.toJson()), o["note"].str)
            if (o.containsKey("agent")) assertEquals(o["agent"].takeIf { it != JsonNull }?.str, w.agent?.name, o["note"].str)
        }
    }

    @Test
    fun termStatusModels() {
        for (c in Vectors.section("live")["models"].obj!!["TermStatus"].arr!!) {
            val o = c.obj!!
            assertEquals(jsonEncode(o["output"]!!), jsonEncode(TermStatus.fromJson(o["input"].obj!!).toJson()), o["note"].str)
        }
    }
}
