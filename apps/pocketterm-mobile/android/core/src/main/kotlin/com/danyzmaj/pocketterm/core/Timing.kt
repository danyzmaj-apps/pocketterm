package com.danyzmaj.pocketterm.core

/**
 * Debug builds only: one step of getting connected (the sign-in read, the computers fetched,
 * the WebSocket up, the computer's first state, a session caught up), logged as
 * `PocketTerm timing <epoch ms> <what>` for the end-to-end run's timing report
 * (apps/pocketterm-mobile/maestro/e2e/run.sh). The app turns it on in debug builds
 * ([enabled] = BuildConfig.DEBUG) and routes [log] to logcat.
 */
object Timing {
    @Volatile var enabled: Boolean = false
    @Volatile var log: (String) -> Unit = { println(it) }
}

/** Logs one step of getting connected when [Timing.enabled]; see [Timing]. */
fun timing(what: String) {
    if (!Timing.enabled) return
    Timing.log("PocketTerm timing ${System.currentTimeMillis()} $what")
}

/** Debug logging, as Dart's `debugPrint`; the app routes it to logcat. */
object DebugLog {
    @Volatile var sink: (String) -> Unit = { println(it) }
}

/** Logs [message] through [DebugLog]. */
fun debugPrint(message: String) = DebugLog.sink(message)
