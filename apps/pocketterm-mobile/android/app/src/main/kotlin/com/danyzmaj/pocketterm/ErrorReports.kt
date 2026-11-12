package com.danyzmaj.pocketterm

import android.app.Application
import io.sentry.SentryEvent
import io.sentry.android.core.SentryAndroid

/**
 * Crash and error reports to GlitchTip (Sentry-compatible), on only in builds that baked in a DSN
 * (BuildConfig.SENTRY_DSN; app/build.gradle.kts). The SDK's default integrations catch crashes, native crashes
 * and ANRs; nothing else is captured. Reports carry the error and its stack, never what the terminal showed:
 * no breadcrumbs (they'd hold log lines, URLs and screen names), no sessions, no screenshots, no user, and
 * every message goes through [ErrorScrubber].
 */
object ErrorReports {
    fun start(app: Application) {
        val dsn = BuildConfig.SENTRY_DSN.trim()
        if (dsn.isEmpty()) return
        SentryAndroid.init(app) { options ->
            options.dsn = dsn
            options.environment = if (BuildConfig.DEBUG) "development" else "production"
            // release stays the SDK's com.danyzmaj.pocketterm@<versionName>+<versionCode>.
            // Deprecated for the newer dataCollection settings, but still honoured; false is the SDK's default too,
            // set here so it never changes under us.
            @Suppress("DEPRECATION")
            options.isSendDefaultPii = false
            options.tracesSampleRate = 0.0
            options.isEnableAutoSessionTracking = false
            options.isAttachScreenshot = false
            options.isAttachViewHierarchy = false
            options.isAttachServerName = false
            options.serverName = null
            options.maxBreadcrumbs = 0
            options.setBeforeBreadcrumb { _, _ -> null }
            options.isEnableActivityLifecycleBreadcrumbs = false
            options.isEnableAppLifecycleBreadcrumbs = false
            options.isEnableSystemEventBreadcrumbs = false
            options.isEnableAppComponentBreadcrumbs = false
            options.isEnableNetworkEventBreadcrumbs = false
            options.isEnableUserInteractionBreadcrumbs = false
            options.setTag("component", "app")
            options.setBeforeSend { event, _ -> ErrorScrubber.scrub(event) }
        }
    }
}

/**
 * What a report may say: addresses of the person's computers (URLs, IPs, tailnet and LAN host names) and email
 * addresses are replaced, and each text is cut to [MAX_LENGTH] so no stretch of terminal output rides along.
 * Exception types and stack frames stay as they are. Plain JVM, so it's unit tested without a device.
 */
object ErrorScrubber {
    const val MAX_LENGTH = 300

    // Order matters: a URL can hold an email or host, an email a host.
    private val url = Regex("""\b([A-Za-z][A-Za-z0-9+.-]*)://[^\s'"<>()\[\]{}]+""")
    private val email = Regex("""[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}""")
    private val localHost = Regex("""\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ts\.net|local|lan)\b""", RegexOption.IGNORE_CASE)
    private val ipv4 = Regex("""\b(?:\d{1,3}\.){3}\d{1,3}\b""")
    private const val H = "[0-9A-Fa-f]{1,4}"
    // Full (eight groups) or compressed (with ::) forms; a time like 12:30:45 is neither.
    private val ipv6 = Regex("""(?<![\w:])(?:(?:$H:){7}$H|(?:$H(?::$H)*)?::(?:$H(?::$H)*)?)(?![\w:])""")

    fun scrub(text: String): String = text
        .replace(url, "$1://<redacted>")
        .replace(email, "<email>")
        .replace(localHost, "<host>")
        .replace(ipv4, "<ip>")
        .replace(ipv6) { if (it.value == "::") it.value else "<ip>" }
        .take(MAX_LENGTH)

    /** The beforeSend hook: scrubs the texts and drops the fields that could name the person or their machines. */
    fun scrub(event: SentryEvent): SentryEvent {
        event.message?.let { m ->
            m.formatted = m.formatted?.let(::scrub)
            m.message = m.message?.let(::scrub)
            m.params = m.params?.map(::scrub)
        }
        event.exceptions?.forEach { e -> e.value = e.value?.let(::scrub) }
        event.user = null
        event.request = null
        event.serverName = null
        event.extras = null
        event.breadcrumbs = null
        // The device name can be the owner's ("Ana's Pixel"); the id is a per-install identifier that would tie
        // every report from one phone together.
        event.contexts.device?.let { d ->
            d.name = null
            d.id = null
        }
        return event
    }
}
