package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonObject

/**
 * A terminal's colors: default foreground and background plus the 256-color palette, as the
 * terminal reports them (kitty's `get-colors`). Colors are opaque ARGB (`0xFFRRGGBB`).
 */
data class TermColors(val foreground: Long, val background: Long, val palette: List<Long>) {
    companion object {
        /** `{fg, bg, palette}` as 0xRRGGBB ints, made opaque; throws when one is missing, as Dart's casts do. */
        fun fromJson(j: JsonObject) = TermColors(
            foreground = opaque(j["fg"].long ?: throw IllegalArgumentException("fg")),
            background = opaque(j["bg"].long ?: throw IllegalArgumentException("bg")),
            palette = (j["palette"].arr ?: throw IllegalArgumentException("palette"))
                .map { opaque(it.long ?: throw IllegalArgumentException("palette entry")) },
        )


        private val basic = longArrayOf(
            0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
            0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
        )

        /** The xterm defaults, until the Mac has sent the terminal's (after [basic], which it reads). */
        val fallback = TermColors(0xFFDDDDDD, 0xFF000000, List(256) { xterm(it) })

        /** xterm's 256 colors: 16 basic, a 6×6×6 cube, 24 greys. */
        fun xterm(i: Int): Long {
            if (i < 16) return opaque(basic[i])
            if (i < 232) {
                fun level(v: Int) = if (v == 0) 0 else 55 + v * 40
                val n = i - 16
                return argb(255, level(n / 36), level(n / 6 % 6), level(n % 6))
            }
            val g = 8 + (i - 232) * 10
            return argb(255, g, g, g)
        }

        private fun opaque(rgb: Long) = (0xFF000000L or rgb) and 0xFFFFFFFFL

        /** Flutter's `Color.fromARGB`: each channel's low 8 bits. */
        internal fun argb(a: Int, r: Int, g: Int, b: Int): Long =
            ((a.toLong() and 0xFF) shl 24) or ((r.toLong() and 0xFF) shl 16) or ((g.toLong() and 0xFF) shl 8) or (b.toLong() and 0xFF)
    }
}

/** A span's line, underline winning over line-through. */
enum class TextDecoration { underline, lineThrough }

/** A run of terminal text in one style; [bg] null is no background. Colors are ARGB. */
data class AnsiSpan(
    val text: String,
    val fg: Long,
    val bg: Long? = null,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val decoration: TextDecoration? = null,
)

private class Pen {
    var fg: Long? = null
    var bg: Long? = null
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var strike = false
    var reverse = false

    fun reset() {
        fg = null; bg = null
        bold = false; dim = false; italic = false; underline = false; strike = false; reverse = false
    }

    fun span(text: String, c: TermColors): AnsiSpan {
        var f = fg ?: c.foreground
        var b = bg
        if (reverse) {
            val nf = b ?: c.background
            b = f
            f = nf
        }
        // Dim draws at alpha 0.6 (Flutter rounds 0.6 × 255 to 0x99).
        if (dim) f = (f and 0x00FFFFFF) or 0x99000000L
        return AnsiSpan(
            text, f, b, bold, italic,
            if (underline) TextDecoration.underline else if (strike) TextDecoration.lineThrough else null,
        )
    }
}

// SGR, other CSI (or one cut off at the end), OSC (to BEL or ESC \, or cut off), DCS, APC, PM and
// SOS strings (kitty's graphics, tmux passthrough; to ESC \ or cut off), and any other escape:
// two bytes, or more with intermediates (a charset choice, ESC ( B, as WezTerm sends), or a lone
// ESC at the end.
private val escape = Regex(
    """\x1b\[([0-9;:]*)m|\x1b\[[0-9;:?<=>]*[ -/]*(?:[@-~]|\z)|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|""" +
        """\x1b[P_^X][^\x1b]*(?:\x1b\\)?|\x1b[ -/]*[0-~]?""",
)

/**
 * Terminal text with ANSI escapes as styled spans: SGR colors (16, 256 and truecolor, `;` or
 * kitty's `:` form) and attributes; every other escape (hyperlinks, prompt marks) is dropped.
 * Adjacent spans are not merged.
 */
fun ansiSpans(text: String, colors: TermColors): List<AnsiSpan> {
    val spans = mutableListOf<AnsiSpan>()
    val pen = Pen()
    var at = 0
    for (m in escape.findAll(text)) {
        if (m.range.first > at) spans.add(pen.span(text.substring(at, m.range.first), colors))
        at = m.range.last + 1
        m.groups[1]?.let { sgr(it.value, pen, colors) }
    }
    if (at < text.length) spans.add(pen.span(text.substring(at), colors))
    return spans
}

private fun sgr(params: String, pen: Pen, colors: TermColors) {
    // `38:2:r:g:b` stays one group; `38;2;r;g;b` spreads over five.
    val groups = if (params.isEmpty()) listOf("0") else params.split(';')
    var i = 0
    while (i < groups.size) {
        val parts = groups[i].split(':')
        val code = parts.first().toLongOrNull() ?: 0
        when (code) {
            0L -> pen.reset()
            1L -> pen.bold = true
            2L -> pen.dim = true
            3L -> pen.italic = true
            4L -> pen.underline = parts.size < 2 || parts[1] != "0"
            7L -> pen.reverse = true
            9L -> pen.strike = true
            22L -> { pen.bold = false; pen.dim = false }
            23L -> pen.italic = false
            24L -> pen.underline = false
            27L -> pen.reverse = false
            29L -> pen.strike = false
            in 30L..37L -> pen.fg = colors.palette[(code - 30).toInt()]
            39L -> pen.fg = null
            in 40L..47L -> pen.bg = colors.palette[(code - 40).toInt()]
            49L -> pen.bg = null
            in 90L..97L -> pen.fg = colors.palette[(code - 90 + 8).toInt()]
            in 100L..107L -> pen.bg = colors.palette[(code - 100 + 8).toInt()]
            38L, 48L, 58L -> {
                val args: List<Long?>
                if (parts.size > 1) {
                    args = parts.drop(1).map { it.toLongOrNull() }
                } else {
                    val mode = if (i + 1 < groups.size) groups[i + 1].toLongOrNull() else null
                    val n = if (mode == 2L) 4 else if (mode == 5L) 2 else 1
                    args = groups.drop(i + 1).take(n).map { it.toLongOrNull() }
                    i += args.size
                }
                val color = extended(args, colors)
                if (code == 38L) pen.fg = color
                if (code == 48L) pen.bg = color
            }
        }
        i++
    }
}

/** `5;n` or `2;[colorspace;]r;g;b`, without the leading 38/48. */
private fun extended(args: List<Long?>, colors: TermColors): Long? {
    if (args.isEmpty()) return null
    if (args.first() == 5L && args.size > 1) {
        val n = args[1]
        return if (n != null && n >= 0 && n < colors.palette.size) colors.palette[n.toInt()] else null
    }
    if (args.first() == 2L) {
        val rgb = if (args.size >= 5) args.subList(args.size - 3, args.size) else args.drop(1)
        if (rgb.size != 3) return null
        return TermColors.argb(255, (rgb[0] ?: 0).toInt(), (rgb[1] ?: 0).toInt(), (rgb[2] ?: 0).toInt())
    }
    return null
}
