package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One half of a theme, light or dark (ARGB colours): what colours terminal screens, code blocks
 * and the accent. The app's chrome is Material's own.
 */
data class PtTheme(
    val name: String,
    val dark: Boolean,
    /** The terminal screen's and code blocks' background. */
    val win: Long,
    /** Bars over a terminal screen (the keys bar). */
    val bar: Long,
    /** Fields and pressed rows on a terminal screen. */
    val field: Long,
    /** The selected row or tab. */
    val sel: Long,
    /** Borders and separators. */
    val line: Long,
    /** The terminal's default foreground. */
    val text: Long,
    /** Secondary text. */
    val dim: Long,
    /** Hints and what's off. */
    val dim2: Long,
    /** The accent; on [platformAccent] palettes only a stand-in for the system's own. */
    val accent: Long,
    /** Text and icons on [accent]. */
    val onAccent: Long,
    val ok: Long,
    val warn: Long,
    val error: Long,
    /** Raised surfaces over a terminal screen. */
    val card: Long,
    val cursor: Long,
    /** Selected text's background (it may be translucent). */
    val selection: Long,
    /** ANSI colours 0–15: 8 normal, then 8 bright. */
    val ansi: List<Long>,
    /** The accent is the platform's (the system theme): the app puts its own in place of [accent]. */
    val platformAccent: Boolean = false,
) {
    init {
        require(ansi.size == 16) { "a palette has 16 ANSI colours" }
    }

    /** A terminal's colours from this palette: its 16 ANSI colours, then xterm's cube and greys. */
    val termColors: TermColors get() = TermColors(text, win, ansi + (16 until 256).map(TermColors::xterm))

    companion object {
        private fun c(rgb: Long): Long = 0xFF000000 or rgb
        private fun ansi(vararg rgb: Long): List<Long> = rgb.map(::c)

        /** xterm's 16 basic colours, the System theme's in light and dark alike
         *  (https://github.com/ThomasDickey/xterm-snapshots/blob/master/XTerm-col.ad, as TermColors.xterm). */
        val xterm16: List<Long> = List(16) { TermColors.xterm(it) }

        // System: Apple Terminal's Basic profile, black on white or light on near-black, with
        // xterm's colours; the greys, greens, oranges and reds are Apple's system colours
        // (https://developer.apple.com/design/human-interface-guidelines/color), the same on
        // every platform. The accent is the platform's.
        val systemLight = PtTheme(
            "System Light", false,
            win = c(0xFFFFFF), bar = c(0xF2F2F7), field = c(0xF2F2F7), sel = c(0xE5E5EA), line = c(0xC6C6C8),
            text = c(0x000000), dim = c(0x8E8E93), dim2 = c(0xAEAEB2), accent = c(0x007AFF), onAccent = c(0xFFFFFF),
            ok = c(0x34C759), warn = c(0xFF9500), error = c(0xFF3B30), card = c(0xF2F2F7), cursor = c(0x929292),
            selection = c(0xB3D7FF), ansi = xterm16, platformAccent = true,
        )
        val systemDark = PtTheme(
            "System Dark", true,
            win = c(0x1E1E1E), bar = c(0x1C1C1E), field = c(0x2C2C2E), sel = c(0x3A3A3C), line = c(0x38383A),
            text = c(0xF2F2F2), dim = c(0x8E8E93), dim2 = c(0x636366), accent = c(0x0A84FF), onAccent = c(0xFFFFFF),
            ok = c(0x30D158), warn = c(0xFF9F0A), error = c(0xFF453A), card = c(0x1C1C1E), cursor = c(0x929292),
            selection = c(0x3F638B), ansi = xterm16, platformAccent = true,
        )

        // Catppuccin: https://github.com/catppuccin/palette/blob/main/palette.json (v1.8.0, colors
        // and ansiColors); cursor Rosewater and selection Overlay 2 at 25% as
        // https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md has them.
        val latte = PtTheme(
            "Catppuccin Latte", false,
            win = c(0xEFF1F5), bar = c(0xE6E9EF), field = c(0xCCD0DA), sel = c(0xCCD0DA), line = c(0xBCC0CC),
            text = c(0x4C4F69), dim = c(0x6C6F85), dim2 = c(0x8C8FA1), accent = c(0x8839EF), onAccent = c(0xEFF1F5),
            ok = c(0x40A02B), warn = c(0xFE640B), error = c(0xD20F39), card = c(0xE6E9EF), cursor = c(0xDC8A78),
            selection = 0x407C7F93,
            ansi = ansi(
                0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
                0x6C6F85, 0xDE293E, 0x49AF3D, 0xEEA02D, 0x456EFF, 0xFE85D8, 0x2D9FA8, 0xBCC0CC,
            ),
        )
        val mocha = PtTheme(
            "Catppuccin Mocha", true,
            win = c(0x1E1E2E), bar = c(0x181825), field = c(0x313244), sel = c(0x313244), line = c(0x45475A),
            text = c(0xCDD6F4), dim = c(0xA6ADC8), dim2 = c(0x7F849C), accent = c(0xCBA6F7), onAccent = c(0x1E1E2E),
            ok = c(0xA6E3A1), warn = c(0xFAB387), error = c(0xF38BA8), card = c(0x181825), cursor = c(0xF5E0DC),
            selection = 0x409399B2,
            ansi = ansi(
                0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
                0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE,
            ),
        )

        // Rosé Pine: https://rosepinetheme.com/palette/ingredients/ (roles: love errors, gold
        // warnings, foam additions); cursor, selection and ANSI colours from
        // https://github.com/rose-pine/kitty/tree/main/dist.
        val dawn = PtTheme(
            "Rosé Pine Dawn", false,
            win = c(0xFAF4ED), bar = c(0xF2E9E1), field = c(0xF2E9E1), sel = c(0xDFDAD9), line = c(0xDFDAD9),
            text = c(0x575279), dim = c(0x797593), dim2 = c(0x9893A5), accent = c(0x286983), onAccent = c(0xFAF4ED),
            ok = c(0x56949F), warn = c(0xEA9D34), error = c(0xB4637A), card = c(0xFFFAF3), cursor = c(0xCECACD),
            selection = c(0xDFDAD9),
            ansi = ansi(
                0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
                0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
            ),
        )
        val rosePine = PtTheme(
            "Rosé Pine", true,
            win = c(0x191724), bar = c(0x1F1D2E), field = c(0x26233A), sel = c(0x403D52), line = c(0x403D52),
            text = c(0xE0DEF4), dim = c(0x908CAA), dim2 = c(0x6E6A86), accent = c(0x9CCFD8), onAccent = c(0x191724),
            ok = c(0x31748F), warn = c(0xF6C177), error = c(0xEB6F92), card = c(0x1F1D2E), cursor = c(0x524F67),
            selection = c(0x403D52),
            ansi = ansi(
                0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
                0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            ),
        )

        // Tokyo Night: https://github.com/folke/tokyonight.nvim/blob/main/extras/lua/tokyonight_day.lua
        // and tokyonight_night.lua (bg, bg_dark, bg_highlight, bg_visual, fg_gutter, fg, dark5,
        // comment, blue, green, orange, red); cursor and ANSI colours from
        // extras/kitty/tokyonight_day.conf and tokyonight_night.conf.
        val tokyoNightDay = PtTheme(
            "Tokyo Night Day", false,
            win = c(0xE1E2E7), bar = c(0xD0D5E3), field = c(0xC4C8DA), sel = c(0xB7C1E3), line = c(0xA8AECB),
            text = c(0x3760BF), dim = c(0x68709A), dim2 = c(0x848CB5), accent = c(0x2E7DE9), onAccent = c(0xE1E2E7),
            ok = c(0x587539), warn = c(0xB15C00), error = c(0xF52A65), card = c(0xD0D5E3), cursor = c(0x3760BF),
            selection = c(0xB7C1E3),
            ansi = ansi(
                0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
                0xA1A6C5, 0xFF4774, 0x5C8524, 0xA27629, 0x358AFF, 0xA463FF, 0x007EA8, 0x3760BF,
            ),
        )
        val tokyoNight = PtTheme(
            "Tokyo Night", true,
            win = c(0x1A1B26), bar = c(0x16161E), field = c(0x292E42), sel = c(0x283457), line = c(0x3B4261),
            text = c(0xC0CAF5), dim = c(0x737AA2), dim2 = c(0x565F89), accent = c(0x7AA2F7), onAccent = c(0x16161E),
            ok = c(0x9ECE6A), warn = c(0xFF9E64), error = c(0xF7768E), card = c(0x16161E), cursor = c(0xC0CAF5),
            selection = c(0x283457),
            ansi = ansi(
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xFF899D, 0x9FE044, 0xFABA4A, 0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5,
            ),
        )
    }
}

/**
 * The theme the person picked; [system] until they pick one. Each has a light and a dark
 * palette, shown as the system's appearance is. `name` is what's kept.
 */
enum class ThemeChoice(val label: String) {
    system("System"),
    catppuccin("Catppuccin"),
    rosePine("Rosé Pine"),
    tokyoNight("Tokyo Night");

    val light: PtTheme
        get() = when (this) {
            system -> PtTheme.systemLight
            catppuccin -> PtTheme.latte
            rosePine -> PtTheme.dawn
            tokyoNight -> PtTheme.tokyoNightDay
        }

    val dark: PtTheme
        get() = when (this) {
            system -> PtTheme.systemDark
            catppuccin -> PtTheme.mocha
            rosePine -> PtTheme.rosePine
            tokyoNight -> PtTheme.tokyoNight
        }

    /** The half that goes with the system's appearance. */
    fun palette(dark: Boolean): PtTheme = if (dark) this.dark else light

    /** The accent is the platform's own. */
    val platformAccent: Boolean get() = this == system

    companion object {
        /**
         * The choice a kept name stands for: this version's names, and those of earlier ones
         * (`mocha` and 0.1.2's `auto` → Catppuccin, `dawn` → Rosé Pine, `gruvbox`, which is gone,
         * → Catppuccin); nothing kept, or a name no version had → System.
         */
        fun migrating(kept: String?): ThemeChoice = when (kept) {
            null -> system
            "mocha", "auto", "gruvbox" -> catppuccin
            "dawn" -> rosePine
            else -> entries.firstOrNull { it.name == kept } ?: system
        }
    }
}

/** The active theme choice, kept per device in a [PreferenceStore]; [choice] emits each change. */
class Appearance {
    private var prefs: PreferenceStore? = null
    private val state = MutableStateFlow(ThemeChoice.system)

    val choice: StateFlow<ThemeChoice> = state.asStateFlow()

    /** The palette showing now, the system being [dark] or not. */
    fun theme(dark: Boolean): PtTheme = state.value.palette(dark)

    /** Reads the kept choice ([ThemeChoice.migrating]); an earlier version's name is kept under this version's. */
    fun load(prefs: PreferenceStore) {
        this.prefs = prefs
        val kept = prefs.getString(prefsKey)
        val choice = ThemeChoice.migrating(kept)
        state.value = choice
        if (kept != null && kept != choice.name) prefs.setString(prefsKey, choice.name)
    }

    /** Shows [choice] now and keeps it. */
    fun choose(choice: ThemeChoice) {
        if (choice == state.value) return
        state.value = choice
        prefs?.setString(prefsKey, choice.name)
    }

    companion object {
        /** The preference the choice is kept under. */
        const val prefsKey = "theme"
    }
}
