package com.danyzmaj.pocketterm.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import com.danyzmaj.pocketterm.core.Appearance
import com.danyzmaj.pocketterm.core.PtTheme

/** A core ARGB colour ([PtTheme]'s) as a Compose one. */
fun argb(c: Long): Color = Color(c.toInt())

/**
 * The chosen theme's palette, its light or dark half as the system is (System, Catppuccin, Rosé
 * Pine, Tokyo Night): it colours what shows a terminal (screens, code blocks, the keys bar) and,
 * but for System, the accent; the app's chrome is Material's, light or dark as the system is.
 * [accent] is the platform's (Material's primary) for System.
 */
@Immutable
data class Palette(val theme: PtTheme, val accent: Color = argb(theme.accent), val onAccent: Color = argb(theme.onAccent)) {
    /** A terminal screen's or code block's background and text. */
    val termBg: Color = argb(theme.win)
    val termFg: Color = argb(theme.text)
    val termDim: Color = argb(theme.dim)
    val termBar: Color = argb(theme.bar)
    val termSel: Color = argb(theme.sel)
    val termLine: Color = argb(theme.line)
    val ok: Color = argb(theme.ok)
    val warn: Color = argb(theme.warn)
    val error: Color = argb(theme.error)

    /** The screen is dark: the chrome around it (bars, icons) goes dark too, so there's no seam. */
    val termDark: Boolean get() = theme.dark
}

/**
 * Colours that say how a session stands, readable on the system's light or dark surface:
 * working (the accent), needs you, failed, paused, done.
 */
@Immutable
data class StatusColors(
    val working: Color,
    val needs: Color,
    val failed: Color,
    val paused: Color,
    val done: Color,
)

val LocalPalette = staticCompositionLocalOf { Palette(PtTheme.systemDark) }
val LocalStatus = staticCompositionLocalOf {
    StatusColors(Color.Unspecified, Color.Unspecified, Color.Unspecified, Color.Unspecified, Color.Unspecified)
}

/** The terminal and code font: the system's monospace (Droid Sans Mono / Roboto Mono). */
val MonoFont: FontFamily = FontFamily.Monospace

/**
 * Material 3 over [appearance], light or dark as the system is: System takes the wallpaper's
 * colours on Android 12+ (dynamic color) and Material's baseline before; the other themes a
 * scheme from their accent. [LocalPalette] carries the theme's half for terminal screens and
 * code, [LocalStatus] the session-state colours.
 */
@Composable
fun PocketTermTheme(appearance: Appearance, content: @Composable () -> Unit) {
    val choice by appearance.choice.collectAsState()
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val theme = choice.palette(dark)
    val scheme = when {
        !choice.platformAccent -> remember(choice, dark) { accentScheme(argb(theme.accent), dark) }
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        else -> if (dark) darkColorScheme() else lightColorScheme()
    }
    val palette = remember(theme, scheme.primary, scheme.onPrimary) {
        if (theme.platformAccent) Palette(theme, scheme.primary, scheme.onPrimary) else Palette(theme)
    }
    val status = StatusColors(
        working = scheme.primary,
        needs = if (dark) Color(0xFFFFB74D) else Color(0xFFB25E00),
        failed = scheme.error,
        paused = scheme.outline,
        done = if (dark) Color(0xFF81C995) else Color(0xFF1E8E3E),
    )
    CompositionLocalProvider(LocalPalette provides palette, LocalStatus provides status) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

/** A scheme around [accent], darkened for a light surface when it's a pastel (the dark themes' accents are). */
private fun accentScheme(accent: Color, dark: Boolean): ColorScheme {
    if (dark) {
        val primary = if (accent.luminance() < .3f) lerp(accent, Color.White, .4f) else accent
        return darkColorScheme(
            primary = primary,
            onPrimary = if (primary.luminance() > .4f) Color(0xFF1B1B1F) else Color.White,
            primaryContainer = lerp(primary, Color(0xFF1B1B1F), .7f),
            onPrimaryContainer = lerp(primary, Color.White, .6f),
            secondaryContainer = lerp(primary, Color(0xFF1B1B1F), .78f),
            onSecondaryContainer = lerp(primary, Color.White, .7f),
        )
    }
    val primary = if (accent.luminance() > .3f) lerp(accent, Color.Black, .45f) else accent
    return lightColorScheme(
        primary = primary,
        onPrimary = Color.White,
        primaryContainer = lerp(primary, Color.White, .82f),
        onPrimaryContainer = lerp(primary, Color.Black, .5f),
        secondaryContainer = lerp(primary, Color.White, .88f),
        onSecondaryContainer = lerp(primary, Color.Black, .55f),
    )
}
