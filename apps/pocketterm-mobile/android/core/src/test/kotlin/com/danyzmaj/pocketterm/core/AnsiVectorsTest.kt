package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonElement
import kotlin.test.Test
import kotlin.test.assertEquals

/** tool/vectors `ansi`: ansiSpans over TermColors.fallback, and TermColors.fromJson. */
class AnsiVectorsTest {
    private val a = Vectors.section("ansi")

    private fun hex(c: Long) = "#%08X".format(c)
    private fun hexes(e: JsonElement?) = e.arr!!.map { it.str }

    @Test
    fun fallbackColors() {
        val v = a["colors"].obj!!
        val f = TermColors.fallback
        assertEquals(v["foreground"].str, hex(f.foreground))
        assertEquals(v["background"].str, hex(f.background))
        assertEquals(hexes(v["palette"]), f.palette.map(::hex))
    }

    @Test
    fun termColorsFromJson() {
        val v = a["termColorsFromJson"].obj!!
        val c = TermColors.fromJson(v["input"].obj!!)
        assertEquals(v["foreground"].str, hex(c.foreground))
        assertEquals(v["background"].str, hex(c.background))
        assertEquals(hexes(v["palette"]), c.palette.map(::hex))
    }

    @Test
    fun spans() {
        for (c in a["cases"].arr!!) {
            val o = c.obj!!
            val actual = ansiSpans(o["input"].str!!, TermColors.fallback).map {
                jsonOf("text" to it.text, "fg" to hex(it.fg), "bg" to it.bg?.let(::hex), "bold" to it.bold, "italic" to it.italic, "decoration" to it.decoration?.name)
            }
            assertEquals(jsonEncode(o["spans"]!!), jsonEncode(actual.toJsonElement()), o["note"].str)
        }
    }
}
