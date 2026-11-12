package com.danyzmaj.pocketterm

import android.app.Application
import android.os.Build
import android.util.Log
import android.os.LocaleList
import android.provider.Settings
import com.danyzmaj.pocketterm.core.Analytics
import com.danyzmaj.pocketterm.core.AnalyticsDevice
import com.danyzmaj.pocketterm.core.AnalyticsTarget
import com.danyzmaj.pocketterm.core.Appearance
import com.danyzmaj.pocketterm.core.DebugLog
import com.danyzmaj.pocketterm.core.SpeechSource
import com.danyzmaj.pocketterm.core.Timing
import com.danyzmaj.pocketterm.core.followAppIcon
import com.danyzmaj.pocketterm.core.timing
import com.danyzmaj.pocketterm.state.MobileSession
import com.danyzmaj.pocketterm.state.VoiceLanguage
import com.danyzmaj.pocketterm.ui.voice.ScriptedSpeech
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import java.util.Locale

/** The process: builds the [AppGraph] once and starts the session (reading what this phone kept). */
class PocketTermApp : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        // First, so a crash while the graph is built is reported too.
        ErrorReports.start(this)
        instance = this
        Timing.enabled = BuildConfig.DEBUG
        // Logcat, under the tag the end-to-end run's timing report reads (maestro/e2e/run.sh).
        Timing.log = { Log.i("PocketTerm", it) }
        DebugLog.sink = { Log.d("PocketTerm", it) }
        timing("launch")
        graph = AppGraph(this)
        graph.start()
    }

    companion object {
        lateinit var instance: PocketTermApp
            private set
    }
}

/**
 * Everything the screens share, made once per process: preferences (the Flutter app's migrated on
 * the first launch), the platform side, the theme and voice language, the speech source, and the
 * phone's [session]. Everything runs on the main thread ([scope]).
 */
class AppGraph(val app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val prefs: AndroidPreferences = AndroidPreferences.open(app)
    val native = AndroidNative(app)

    /** The end-to-end build: the scanner takes a pasted code, tips start seen, the microphone hears a script. */
    val e2e: Boolean = BuildConfig.DEBUG && BuildConfig.E2E

    val appearance = Appearance().apply { load(prefs) }
    val voiceLanguage = VoiceLanguage(prefs) {
        val l = LocaleList.getDefault()
        List(l.size()) { l[it] }.ifEmpty { listOf(Locale.getDefault()) }
    }
    val speech: SpeechSource = if (e2e) ScriptedSpeech() else Dictation(app)

    /** Anonymous usage statistics: off until turned on in Settings, and never in a build without a website id. */
    val analytics = Analytics(
        AnalyticsTarget.of(BuildConfig.UMAMI_WEBSITE_ID),
        analyticsDevice(app),
        prefs,
        scope,
    )

    val session = MobileSession(
        prefs,
        native,
        device = Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)?.ifBlank { null } ?: Build.MODEL,
        scope = scope,
        cacheDir = app.cacheDir,
        tipsStartSeen = e2e,
        analytics = analytics,
    )

    /** `pocketterm://` links opened from outside (setup links, followed sessions'): kept until the session reads them. */
    private val links = Channel<String>(Channel.UNLIMITED)

    fun openLink(link: String) {
        links.trySend(link)
    }

    fun start() {
        followAppIcon(appearance, native::setAppIcon, scope)
        // Started first: the app's first frame shows it's still reading what it kept, not setup.
        scope.launch { session.startPhone(links.receiveAsFlow()) }
    }
}

/**
 * What Umami reads this phone as: a browser-like User-Agent (Umami drops bot-like ones, OkHttp's own among them)
 * with the Android version and model, the screen in pixels, the language, and the app's version.
 */
private fun analyticsDevice(app: Application): AnalyticsDevice {
    fun clean(text: String) = text.replace(Regex("[;()\\r\\n]"), " ").replace(Regex("\\s+"), " ").trim()
    val metrics = app.resources.displayMetrics
    return AnalyticsDevice(
        platform = "android",
        hostname = "android.pocketterm.app.danyzmaj.com",
        userAgent = "Mozilla/5.0 (Linux; Android ${clean(Build.VERSION.RELEASE)}; ${clean(Build.MODEL)}) " +
            "PocketTerm/${clean(BuildConfig.VERSION_NAME)}",
        screen = "${metrics.widthPixels}x${metrics.heightPixels}",
        language = Locale.getDefault().toLanguageTag(),
        appVersion = BuildConfig.VERSION_NAME,
    )
}
