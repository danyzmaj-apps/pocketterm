package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TerminalTest {
    private fun term(vararg pairs: Pair<String, String>): JsonObject = jsonOf(*pairs)

    @Test
    fun `keyBytes sends what a terminal sends for each key, Shift+Enter as Alt+Enter`() {
        assertEquals("\r", keyBytes("enter"))
        assertEquals("\u001b", keyBytes("esc"))
        assertEquals("\t", keyBytes("tab"))
        assertEquals("\u001b[Z", keyBytes("shift+tab"))
        assertEquals("\u001b[A", keyBytes("up"))
        assertEquals("\u001b[D", keyBytes("left"))
        assertEquals("\u007f", keyBytes("backspace"))
        assertEquals("\u001b\r", keyBytes("shift+enter"))
        assertEquals("\u0003", keyBytes("ctrl+c"))
        assertEquals("\u0001", keyBytes("ctrl+a"))
        assertEquals("3", keyBytes("3"))
        assertFailsWith<TerminalException> { keyBytes("ctrl+shift+x") }
        assertFailsWith<TerminalException> { keyBytes("ctrl+a\n") }
    }

    @Test
    fun `keyRuns keeps Esc apart, so what follows is not read as Alt+key`() {
        assertEquals(listOf("\u001b[B\u001b[B\r"), keyRuns(listOf("down", "down", "enter")))
        assertEquals(listOf("\u001b[A", "\u001b", "x"), keyRuns(listOf("up", "esc", "x")))
        assertEquals(listOf("\u001b"), keyRuns(listOf("esc")))
        assertEquals(emptyList(), keyRuns(emptyList()))
    }

    @Test
    fun `textChunks cuts long text between characters, within the byte limit, keeping every byte in order`() {
        val text = "ab漢👍🏽e\u0301" + "x".repeat(20)
        val chunks = textChunks(text, 5)
        assertEquals(text, chunks.joinToString(""))
        for (c in chunks) {
            assertTrue(c.isNotEmpty())
            assertTrue(c.toByteArray(Charsets.UTF_8).size <= 5, c)
        }
        // A surrogate pair (an emoji) is never split.
        assertTrue("👍" in chunks)
        assertEquals(emptyList(), textChunks("", 5))
        assertEquals(listOf("short"), textChunks("short", 100))
    }

    @Test
    fun `screenLines drops WezTerm's charset choices, so a reset-only line is blank`() {
        val text = "\u001b(B\u001b[0;1m\u001b[32m➜  \u001b[36mwezterm\r\n\u001b(B\u001b[0m\r\n"
        assertEquals(listOf("\u001b[0;1m\u001b[32m➜  \u001b[36mwezterm"), screenLines(text))
    }

    @Test
    fun `a newest line longer than the history budget comes as its end, not as nothing`() {
        val long = "\u001b[38:2:1:2:3m" + "é".repeat(historyBytes)
        val lines = screenLines("older\n$long\n\n")
        assertEquals(1, lines.size)
        assertTrue(lines.single().toByteArray(Charsets.UTF_8).size < historyBytes)
        assertTrue(lines.single().endsWith("é".repeat(100)))
        // A cut inside an escape starts after it, so none of its bytes show.
        val colored = "\u001b[31mx".repeat(historyBytes / 4)
        assertTrue(Regex("(\u001b\\[31m)?x(\u001b\\[31mx)*").matches(screenLines(colored).single()))
    }

    @Test
    fun `control characters, escapes and bidi overrides go, tab and newline read as spaces`() {
        assertEquals("x y z red", cleanTitle("x\ty\nz\u001b[31m red\u0007\u0001"))
        assertEquals("omp evil", cleanTitle("\u001b]0;inner\u0007omp \u202eevil"))
        assertEquals("漢字 👍🏽 é שלום zero\u200bwidth", cleanTitle("漢字 👍🏽 é שלום zero\u200bwidth"))
    }

    @Test
    fun `a very long title is cut to titleRunes characters, never inside an emoji`() {
        val t = cleanTitle("👍".repeat(1000))
        assertEquals(titleRunes, t.codePointCount(0, t.length))
        assertTrue(t.endsWith("👍\u2026"))
        assertEquals("t".repeat(titleRunes), cleanTitle("t".repeat(titleRunes)))
    }

    @Test
    fun `windowOfTerm kitty - the socket it listens on, else its pid`() {
        assertEquals("kitty/7", windowOfTerm(term("KITTY_WINDOW_ID" to "7", "KITTY_PID" to "88858", "KITTY_LISTEN_ON" to "unix:/tmp/dzt/ks/kitty")))
        assertEquals("kitty-23224/116", windowOfTerm(term("KITTY_WINDOW_ID" to "116", "KITTY_PID" to "23224", "KITTY_LISTEN_ON" to "unix:/tmp/kitty-23224")))
        assertEquals("kitty-501/3", windowOfTerm(term("KITTY_WINDOW_ID" to "3", "KITTY_PID" to "501")))
        // A socket that isn't kitty's own name can't be found again.
        assertNull(windowOfTerm(term("KITTY_WINDOW_ID" to "3", "KITTY_LISTEN_ON" to "unix:/tmp/other")))
    }

    private val leaked = arrayOf("KITTY_WINDOW_ID" to "116", "KITTY_PID" to "23224", "KITTY_LISTEN_ON" to "unix:/tmp/kitty-23224")

    @Test
    fun `tmux wins over the terminal showing it, even with kitty variables leaked in`() {
        assertEquals(
            "tmux:default/0",
            windowOfTerm(term("TERM_PROGRAM" to "tmux", *leaked, "TMUX" to "/private/tmp/tmux-501/default,4226,0", "TMUX_PANE" to "%0")),
        )
        assertEquals("tmux:work/12", windowOfTerm(term("TMUX" to "/private/tmp/tmux-501/work,1,0", "TMUX_PANE" to "%12")))
    }

    @Test
    fun `WezTerm and Ghostty started from kitty - their own TERM_PROGRAM wins over the leaked KITTY_`() {
        assertEquals(
            "wezterm:40899/2",
            windowOfTerm(term(*leaked, "TERM_PROGRAM" to "WezTerm", "WEZTERM_PANE" to "2", "WEZTERM_UNIX_SOCKET" to "/Users/me/.local/share/wezterm/gui-sock-40899")),
        )
        assertNull(windowOfTerm(term(*leaked, "TERM_PROGRAM" to "ghostty", "tty" to "/dev/ttys007")))
    }

    @Test
    fun `iTerm2 - its session's UUID, only where iTerm2 is the TERM_PROGRAM`() {
        val id = "w0t1p0:4E0BF942-D30A-4EDD-BD3A-616CCAED64DF"
        assertEquals("iterm:4E0BF942-D30A-4EDD-BD3A-616CCAED64DF", windowOfTerm(term(*leaked, "TERM_PROGRAM" to "iTerm.app", "ITERM_SESSION_ID" to id)))
        // kitty started from iTerm2 keeps iTerm2's variable.
        assertEquals("kitty-23224/116", windowOfTerm(term(*leaked, "TERM_PROGRAM" to "kitty", "ITERM_SESSION_ID" to id)))
        assertNull(windowOfTerm(term("TERM_PROGRAM" to "iTerm.app", "ITERM_SESSION_ID" to "w0t0p0:nope")))
    }

    @Test
    fun `nothing known - null`() {
        assertNull(windowOfTerm(null))
        assertNull(windowOfTerm(term()))
        assertNull(windowOfTerm(term("TERM_PROGRAM" to "vscode", "tty" to "/dev/ttys003")))
    }

    @Test
    fun `an older Mac's window (no app, no caps) is kitty's, able to do everything`() {
        val w = TermWindow.fromJson(jsonOf("key" to "kitty-1/2", "title" to "t", "program" to "claude"))
        assertEquals("kitty", w.app)
        assertEquals(allCaps, w.caps)
        assertEquals(Agent.claude, w.agent)
    }

    @Test
    fun `caps and via survive the trip to the phone, unknown caps are dropped`() {
        val w = TermWindow(
            key = "tmux:default/0", title = "x", tab = "s:w", cwd = "/x", program = "zsh", app = "tmux", via = "Ghostty",
            caps = setOf(TermCap.type, TermCap.keys),
        )
        val json = w.toJson()
        val back = TermWindow.fromJson(JsonObject(json + ("caps" to (json["caps"].arr!!.map { it.str } + "teleport").toJsonElement())))
        assertEquals("tmux" to "Ghostty", back.app to back.via)
        assertEquals(setOf(TermCap.type, TermCap.keys), back.caps)
    }
}
