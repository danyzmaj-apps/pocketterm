package com.danyzmaj.pocketterm.ui.terminal

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import com.danyzmaj.pocketterm.core.TermColors
import com.danyzmaj.pocketterm.core.TextDecoration
import com.danyzmaj.pocketterm.core.ansiSpans
import com.danyzmaj.pocketterm.ui.theme.Palette
import com.danyzmaj.pocketterm.ui.theme.argb
import androidx.compose.ui.text.style.TextDecoration as ComposeDecoration

/** One line of terminal text with its ANSI escapes as styles ([ansiSpans]); every other escape is dropped. */
fun ansiAnnotated(line: String, colors: TermColors): AnnotatedString = buildAnnotatedString {
    for (s in ansiSpans(line, colors)) {
        withStyle(
            SpanStyle(
                color = argb(s.fg),
                background = s.bg?.let(::argb) ?: Color.Unspecified,
                fontWeight = if (s.bold) FontWeight.Bold else null,
                fontStyle = if (s.italic) FontStyle.Italic else null,
                textDecoration = when (s.decoration) {
                    TextDecoration.underline -> ComposeDecoration.Underline
                    TextDecoration.lineThrough -> ComposeDecoration.LineThrough
                    null -> null
                },
            ),
        ) { append(s.text) }
    }
}

/**
 * The colours a screen draws in until the computer sends its terminal's: the chosen theme's half
 * for the system's appearance, its text, background and 16 ANSI colours, then xterm's cube and greys.
 */
fun themeColors(p: Palette): TermColors = p.theme.termColors
