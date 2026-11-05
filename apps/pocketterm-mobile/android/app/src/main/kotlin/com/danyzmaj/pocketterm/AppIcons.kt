package com.danyzmaj.pocketterm

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

/**
 * The launcher icon per theme (core AppIcon.kt's appIconFor): one activity-alias of
 * MainActivity per icon (AndroidManifest.xml), IconDefault (the app's own, Catppuccin Mocha's, for
 * System and Catppuccin), IconDawn (Rosé Pine) and IconTokyoNight, the chosen one enabled and the
 * rest disabled, the retired IconMocha and IconGruvbox among them.
 *
 * The switch waits for the app to leave the screen ([applyPending] from MainActivity.onStop): a
 * launcher drops the entry of a disabled alias at once, and some close the task started through it.
 * Only release builds switch; in debug builds MainActivity itself is the launcher entry (what Android
 * Studio and adb start), and an enabled alias would show a second icon.
 */
object AppIcons {
    private val icons = listOf("default", "dawn", "tokyoNight")

    /**
     * Aliases no icon asks for any more, disabled with the rest: IconMocha, 0.1.2's Mocha icon, and
     * IconGruvbox, 0.1.7's Gruvbox one (Gruvbox is gone; its people are on Catppuccin, IconDefault).
     */
    private val retired = listOf("mocha", "gruvbox")

    /** The icon asked for, until the app leaves the screen. */
    @Volatile
    private var pending: String? = null

    fun request(icon: String) {
        if (icon in icons) pending = icon
    }

    /**
     * The system splash's theme for [icon] (values-v31/styles.xml), for SplashScreen.setSplashScreenTheme:
     * the icon on its theme's background, light or dark as the system is. Null for an unknown icon.
     */
    fun splashTheme(icon: String): Int? = when (icon) {
        "default" -> R.style.LaunchTheme_Default
        "dawn" -> R.style.LaunchTheme_Dawn
        "tokyoNight" -> R.style.LaunchTheme_TokyoNight
        else -> null
    }

    fun applyPending(context: Context) {
        val icon = pending ?: return
        pending = null
        if (!switchable(context)) return
        val pm = context.packageManager
        // The new one first, so the launcher always has one.
        val order = listOf(icon) + (icons + retired).filter { it != icon }
        for (name in order) {
            val alias = alias(context, name)
            val on = name == icon
            if (enabled(pm, alias) == on) continue
            pm.setComponentEnabledSetting(
                alias,
                if (on) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    private fun alias(context: Context, icon: String) = ComponentName(
        context,
        "${MainActivity::class.java.name.substringBeforeLast('.')}.Icon${icon.replaceFirstChar { it.uppercase() }}",
    )

    /** Set at runtime, or else as the manifest has it. */
    private fun enabled(pm: PackageManager, component: ComponentName): Boolean =
        when (pm.getComponentEnabledSetting(component)) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
            PackageManager.COMPONENT_ENABLED_STATE_DEFAULT ->
                pm.getActivityInfo(component, PackageManager.MATCH_DISABLED_COMPONENTS).enabled
            else -> false
        }

    /** False while MainActivity itself is a launcher entry (debug and profile builds). */
    private fun switchable(context: Context): Boolean {
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(context.packageName)
        return context.packageManager.queryIntentActivities(launcher, 0).none {
            it.activityInfo.targetActivity == null && it.activityInfo.name == MainActivity::class.java.name
        }
    }
}
