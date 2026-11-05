package com.danyzmaj.pocketterm.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AnsiTest {
    private val c = TermColors.fallback
    private fun text(s: String) = ansiSpans(s, c).joinToString("") { it.text }

    @Test
    fun `truecolor in kitty colon form and in semicolon form`() {
        val spans = ansiSpans("\u001b[38:2:0:180:255ma\u001b[38;2;1;2;3;48;5;196mb\u001b[0mc", c)
        assertEquals("abc", spans.joinToString("") { it.text })
        assertEquals(0xFF00B4FF, spans[0].fg)
        assertEquals(0xFF010203, spans[1].fg)
        assertEquals(c.palette[196], spans[1].bg)
        assertEquals(c.foreground, spans[2].fg)
        assertNull(spans[2].bg)
    }

    @Test
    fun `attributes on and off, basic and bright colors`() {
        val spans = ansiSpans("\u001b[1;31ma\u001b[22;39;94mb", c)
        assertEquals(true, spans[0].bold)
        assertEquals(c.palette[1], spans[0].fg)
        assertEquals(false, spans[1].bold)
        assertEquals(c.palette[12], spans[1].fg)
    }

    @Test
    fun `hyperlinks, prompt marks and other escapes leave only their text`() {
        assertEquals("link end", text("\u001b]133;A\u001b\\\u001b]8;id=1;file:///x\u001b\\link\u001b]8;;\u001b\\ \u001b[2Kend"))
    }

    @Test
    fun `escapes with intermediates (a charset choice, ESC ( B) leave nothing`() {
        val spans = ansiSpans("\u001b(B\u001b[32ma\u001b(0\u001b#8b\u001b7c", c)
        assertEquals("abc", spans.joinToString("") { it.text })
        assertEquals(c.palette[2], spans.first().fg)
    }

    @Test
    fun `a cut-off OSC, CSI or lone ESC at the end leaks none of its bytes`() {
        for (cut in listOf("\u001b]8;;https://example.com/a", "\u001b[38;2;1", "\u001b")) assertEquals("text", text("text$cut"), cut)
        // An OSC whose terminator never came, followed by the next escape.
        assertEquals("red", text("\u001b]0;title\u001b[31mred"))
    }

    @Test
    fun `kitty's graphics (APC) and tmux passthrough (DCS) leave nothing of their payload`() {
        assertEquals("abc", text("a\u001b_Gf=100,a=T;iVBORw0KGgo=\u001b\\b\u001bPtmux;\u001b\u001b]52;c;eA==\u0007\u001b\\c"))
    }

    @Test
    fun `private modes, keyboard modes and 256 colors with a missing index draw nothing`() {
        val spans = ansiSpans("\u001b[?2004h\u001b[>4;2m\u001b[=1;u\u001b[38;5ma\u001b[48;5;999mb", c)
        assertEquals("ab", spans.joinToString("") { it.text })
        assertNull(spans.last().bg)
    }
}
