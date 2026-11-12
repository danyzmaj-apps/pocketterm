package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.UUID

// Anonymous usage statistics to the publisher's self-hosted Umami (umami.danyzmaj.com, in the EU): which
// screens open and a fixed list of things that happened, each with a few fixed values. Off until the person
// turns it on in Settings, and off for good in a build without a website id (debug, CI, forks).

/** Where events go: Umami's collect API at [url], counted under [websiteId]. */
class AnalyticsTarget(val websiteId: String, val url: String = "https://umami.danyzmaj.com") {
    companion object {
        /** The build's target; null (nothing is ever sent) without a website id. */
        fun of(websiteId: String): AnalyticsTarget? = websiteId.trim().takeIf { it.isNotEmpty() }?.let(::AnalyticsTarget)
    }
}

/** What every call says about the phone; Umami reads the OS and model from [userAgent] and drops bot-like ones. */
class AnalyticsDevice(
    val platform: String,
    val hostname: String,
    val userAgent: String,
    val screen: String,
    val language: String,
    val appVersion: String,
)

/**
 * Everything that may be recorded: the screens, and per event its properties with the values each may take
 * (null: true or false). Anything else (another name, key or value) is dropped before it's queued, so no
 * host name, address, path, command, text or key ever goes.
 */
object AnalyticsEvents {
    val screens: Set<String> = setOf(
        "setup", "scan", "push_consent", "home", "session", "terminal", "queue", "orchestrator", "settings",
    )

    val events: Map<String, Map<String, Set<String>?>> = mapOf(
        "pairing_completed" to mapOf("method" to setOf("scan", "link"), "computer" to setOf("first", "another")),
        "pairing_failed" to mapOf("method" to setOf("scan", "link"), "code" to PairingFailure.entries.map { it.name }.toSet()),
        "demo_opened" to emptyMap(),
        "session_opened" to mapOf(
            "view" to setOf("conversation", "screen"),
            "from" to setOf("list", "notification", "new", "switch"),
        ),
        "session_started" to mapOf("kind" to setOf("agent", "shell"), "project" to setOf("existing", "new")),
        "prompt_sent" to mapOf("mode" to setOf("prompt", "steer", "queue", "command", "orchestrator"), "attachments" to null),
        "terminal_connected" to mapOf("transport" to setOf("tailnet", "local", "other")),
        "terminal_disconnected" to mapOf("reason" to setOf("unreachable", "computer_offline")),
        "notifications_set" to mapOf("on" to null),
    )

    /** At most this many properties per event, `platform` and `app_version` included. */
    const val MAX_PROPERTIES = 10

    /** [props] as they may leave the phone for event [name]: only its own keys, each with an allowed value; null for an unknown event. */
    fun sanitize(name: String, props: Map<String, Any?>): Map<String, Any>? {
        val allowed = events[name] ?: return null
        val out = LinkedHashMap<String, Any>()
        for ((key, value) in props) {
            if (out.size >= MAX_PROPERTIES - 2) break
            if (key !in allowed) continue
            val values = allowed[key]
            when {
                values == null && value is Boolean -> out[key] = value
                values != null && value is String && value in values -> out[key] = value
            }
        }
        return out
    }

    /** `terminal_connected`'s `transport`, from the server's host: never the host itself. */
    fun transport(host: String): String {
        val h = host.lowercase().trimEnd('.')
        return when {
            h.endsWith(".ts.net") -> "tailnet"
            h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]" || h == "10.0.2.2" -> "local"
            else -> "other"
        }
    }
}

/** Why a sign-in or an added computer's code didn't work (`pairing_failed`'s `code`). */
enum class PairingFailure {
    /** The link carries no pairing code. */
    no_code,

    /** The server isn't reachable or isn't a PocketTerm server. */
    server_check,

    /** The code was used or is too old. */
    code_used,

    /** The server refused it for another reason. */
    server_error,

    /** The phone couldn't keep the sign-in. */
    storage,

    /** The request didn't get through. */
    connection,

    /** Signed in to another server. */
    other_server,

    /** A key that would replace the one held came with a code that doesn't work. */
    key_rejected,

    /** A computer's key came from a link opened outside the app's scanner. */
    not_scanned,
}

/**
 * Anonymous usage statistics, off by default ([enabled]). On, each call queues one Umami event (in memory, at
 * most [MAX_QUEUE], the oldest dropped) that goes out at once, one request at a time; a failure waits
 * [RETRY_MILLIS] (or the next [flush]). Events carry a random install id ([INSTALL_ID_KEY], made the first
 * time one is recorded), never a device id; turning it off drops the id and the queue, and turning it on again
 * makes a new id. Without a [target] nothing is ever recorded.
 *
 * Confined to [scope] (the main thread); never throws.
 */
class Analytics(
    private val target: AnalyticsTarget?,
    private val device: AnalyticsDevice,
    private val prefs: PreferenceStore,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    /** Sends one JSON body; answers the HTTP status. Tests pass their own. */
    private val post: suspend (url: String, userAgent: String, body: String) -> Int = ::okHttpPost,
) : ChangeNotifier() {
    /** Whether this build can send at all. */
    val configured: Boolean get() = target != null

    /** The person's choice, off until they turn it on. */
    val enabled: Boolean get() = prefs.getBool(ENABLED_KEY) ?: false

    private val active: Boolean get() = target != null && enabled

    private val queue = ArrayDeque<String>()
    private var sending: Job? = null
    private var retryAt = 0L

    /** How many events wait (tests). */
    val queued: Int get() = queue.size

    fun setEnabled(on: Boolean) {
        if (on == enabled) return
        prefs.setBool(ENABLED_KEY, on)
        if (!on) {
            sending?.cancel()
            sending = null
            queue.clear()
            retryAt = 0
            prefs.remove(INSTALL_ID_KEY)
        }
        notifyListeners()
    }

    /** A screen view; [name] one of [AnalyticsEvents.screens]. */
    fun screen(name: String) {
        if (!active || name !in AnalyticsEvents.screens) return
        enqueue(null, name, emptyMap())
    }

    /** An event of [AnalyticsEvents.events]; what isn't allowed in [props] is left out. */
    fun event(name: String, vararg props: Pair<String, Any?>) {
        if (!active) return
        val clean = AnalyticsEvents.sanitize(name, props.toMap()) ?: return
        enqueue(name, null, clean)
    }

    /** Tries what waits now (the app came back to the front), even within a failure's wait. */
    fun flush() {
        retryAt = 0
        drain()
    }

    private var lastScreen: String? = null

    private fun enqueue(name: String?, screen: String?, props: Map<String, Any>) {
        val t = target ?: return
        val id = prefs.getString(INSTALL_ID_KEY) ?: UUID.randomUUID().toString().also { prefs.setString(INSTALL_ID_KEY, it) }
        if (screen != null) lastScreen = screen
        val page = screen ?: lastScreen
        val payload = buildJsonObject {
            put("website", t.websiteId)
            put("hostname", device.hostname)
            put("language", device.language)
            put("screen", device.screen)
            put("url", "/" + (page ?: ""))
            page?.let { put("title", it) }
            name?.let { put("name", it) }
            put("id", id)
            put("timestamp", clock() / 1000)
            put("data", JsonObject(buildMap {
                put("platform", JsonPrimitive(device.platform))
                put("app_version", JsonPrimitive(device.appVersion))
                for ((k, v) in props) put(k, if (v is Boolean) JsonPrimitive(v) else JsonPrimitive(v.toString()))
            }))
        }
        queue.addLast(jsonEncode(jsonOf("type" to "event", "payload" to payload)))
        while (queue.size > MAX_QUEUE) queue.removeFirst()
        drain()
    }

    private fun drain() {
        val t = target ?: return
        if (sending?.isActive == true || queue.isEmpty() || clock() < retryAt) return
        sending = scope.launch {
            while (active && queue.isNotEmpty()) {
                val body = queue.first()
                val status = try {
                    post(t.url.trimEnd('/') + "/api/send", device.userAgent, body)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    null
                }
                when {
                    status != null && status in 200..299 -> queue.removeFirstOrNull()
                    // Umami will never take it (malformed, unknown website): not sent again.
                    status != null && status in 400..499 && status != 408 && status != 429 -> queue.removeFirstOrNull()
                    else -> {
                        retryAt = clock() + RETRY_MILLIS
                        break
                    }
                }
            }
        }
    }

    companion object {
        const val ENABLED_KEY = "pocketterm_analytics_on"
        const val INSTALL_ID_KEY = "pocketterm_analytics_id"
        const val MAX_QUEUE = 100
        const val RETRY_MILLIS = 60_000L

        private val http: OkHttpClient by lazy { Http.base.newBuilder().followRedirects(false).build() }
        private val json = "application/json".toMediaType()

        private suspend fun okHttpPost(url: String, userAgent: String, body: String): Int {
            val request = Request.Builder().url(url).header("User-Agent", userAgent).post(body.toRequestBody(json)).build()
            return http.newCall(request).await().use { it.code }
        }
    }
}
