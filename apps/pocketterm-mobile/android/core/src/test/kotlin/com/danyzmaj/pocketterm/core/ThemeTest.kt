package com.danyzmaj.pocketterm.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

class ThemeTest {
    @Test
    fun `System until a theme is picked, the picked one kept`() {
        val prefs = MemoryPreferences()
        val first = Appearance().apply { load(prefs) }
        assertEquals(ThemeChoice.system, first.choice.value)
        assertSame(PtTheme.systemLight, first.theme(dark = false))
        assertNull(prefs.getString(Appearance.prefsKey), "nothing kept until a pick")

        first.choose(ThemeChoice.rosePine)
        assertEquals(ThemeChoice.rosePine, first.choice.value)
        assertSame(PtTheme.dawn, first.theme(dark = false))
        assertSame(PtTheme.rosePine, first.theme(dark = true))
        assertEquals("rosePine", prefs.getString(Appearance.prefsKey))

        // The next launch reads it back.
        assertEquals(ThemeChoice.rosePine, Appearance().apply { load(prefs) }.choice.value)
    }

    @Test
    fun `an earlier version's name moves to its family and is kept so`() {
        val cases = mapOf(
            "mocha" to ThemeChoice.catppuccin, "auto" to ThemeChoice.catppuccin, "gruvbox" to ThemeChoice.catppuccin,
            "dawn" to ThemeChoice.rosePine, "tokyoNight" to ThemeChoice.tokyoNight, "solarized" to ThemeChoice.system,
            "system" to ThemeChoice.system, "catppuccin" to ThemeChoice.catppuccin,
        )
        for ((kept, want) in cases) {
            val prefs = MemoryPreferences(mapOf(Appearance.prefsKey to kept))
            assertEquals(want, Appearance().apply { load(prefs) }.choice.value, kept)
            assertEquals(want.name, prefs.getString(Appearance.prefsKey), kept)
        }
        assertEquals(ThemeChoice.system, ThemeChoice.migrating(null))
    }

    @Test
    fun `every family has a light and a dark half`() {
        assertEquals(listOf("system", "catppuccin", "rosePine", "tokyoNight"), ThemeChoice.entries.map { it.name })
        assertEquals(listOf("System", "Catppuccin", "Rosé Pine", "Tokyo Night"), ThemeChoice.entries.map { it.label })
        for (c in ThemeChoice.entries) {
            assertEquals(false, c.light.dark, c.name)
            assertEquals(true, c.dark.dark, c.name)
            assertSame(c.dark, c.palette(dark = true))
            assertSame(c.light, c.palette(dark = false))
            assertEquals(c == ThemeChoice.system, c.light.platformAccent)
            assertEquals(c == ThemeChoice.system, c.dark.platformAccent)
        }
        assertSame(PtTheme.latte, ThemeChoice.catppuccin.light)
        assertSame(PtTheme.mocha, ThemeChoice.catppuccin.dark)
        assertSame(PtTheme.tokyoNightDay, ThemeChoice.tokyoNight.light)
    }

    @Test
    fun `System is black on white or light on near-black, with xterm's colours`() {
        assertEquals(0xFFFFFFFF, PtTheme.systemLight.win)
        assertEquals(0xFF000000, PtTheme.systemLight.text)
        assertEquals(0xFF1E1E1E, PtTheme.systemDark.win)
        assertEquals(PtTheme.systemLight.ansi, PtTheme.systemDark.ansi)
        assertEquals(0xFFCD0000, PtTheme.systemDark.ansi[1])
        assertEquals(0xFF5C5CFF, PtTheme.systemDark.ansi[12])
    }

    @Test
    fun `official palette spot checks, the same as the Swift and C# cores`() {
        assertEquals(0xFFEFF1F5, PtTheme.latte.win)
        assertEquals(0xFFCBA6F7, PtTheme.mocha.accent)
        assertEquals(0xFF575279, PtTheme.dawn.text)
        assertEquals(0xFF191724, PtTheme.rosePine.win)
        assertEquals(0xFFE1E2E7, PtTheme.tokyoNightDay.win)
        assertEquals(0xFFFF899D, PtTheme.tokyoNight.ansi[9])
    }

    @Test
    fun `a palette's terminal colours`() {
        val colors = PtTheme.mocha.termColors
        assertEquals(PtTheme.mocha.text, colors.foreground)
        assertEquals(PtTheme.mocha.win, colors.background)
        assertEquals(256, colors.palette.size)
        assertEquals(PtTheme.mocha.ansi, colors.palette.take(16))
        assertEquals(TermColors.fallback.palette.drop(16), colors.palette.drop(16))
    }
}
