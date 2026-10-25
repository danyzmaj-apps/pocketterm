package com.danyzmaj.pocketterm

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.content.res.Resources

/**
 * The launcher icon per theme (packages/pocketterm_core/lib/app_icon.dart): one activity-alias of
 * MainActivity per icon (AndroidManifest.xml), IconDefault, IconMocha, IconDawn, IconTokyoNight and
 * IconGruvbox, the chosen one enabled and the rest disabled.
 *
 * The switch waits for the app to leave the screen ([applyPending] from MainActivity.onStop): a
 * launcher drops the entry of a disabled alias at once, and some close the task started through it.
 * Only release builds switch; in debug and profile builds MainActivity itself is the launcher entry
 * (`flutter run` starts it), and an enabled alias would show a second icon.
 */
object AppIcons {
    private val icons = listOf("default", "mocha", "dawn", "tokyoNight", "gruvbox")

    /** The icon asked for, until the app leaves the screen. */
    @Volatile
    private var pending: String? = null

    fun request(icon: String) {
        if (icon in icons) pending = icon
    }

    /**
     * The system splash's theme for [icon] (values-v31/styles.xml), for SplashScreen.setSplashScreenTheme:
     * the chosen theme's background, or the manifest's LaunchTheme (the system's light or dark) for Auto's
     * default icon. Null for an unknown icon.
     */
    fun splashTheme(icon: String): Int? = when (icon) {
        "default" -> Resources.ID_NULL
        "mocha" -> R.style.LaunchTheme_Mocha
        "dawn" -> R.style.LaunchTheme_Dawn
        "tokyoNight" -> R.style.LaunchTheme_TokyoNight
        "gruvbox" -> R.style.LaunchTheme_Gruvbox
        else -> null
    }

    /**
     * The background of the theme the person chose (packages/pocketterm_core/lib/theme.dart, kept by
     * shared_preferences as `flutter.theme`); Auto's, by the system's light or dark, when none is.
     */
    fun themeBackground(context: Context): Int {
        val theme = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.theme", null)
        val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        return when (theme) {
            "mocha" -> 0xFF1E1E2E
            "dawn" -> 0xFFFAF4ED
            "tokyoNight" -> 0xFF1A1B26
            "gruvbox" -> 0xFF282828
            else -> if (dark) 0xFF1E1E2E else 0xFFFAF4ED
        }.toInt()
    }

    fun applyPending(context: Context) {
        val icon = pending ?: return
        pending = null
        if (!switchable(context)) return
        val pm = context.packageManager
        // The new one first, so the launcher always has one.
        val order = listOf(icon) + icons.filter { it != icon }
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
