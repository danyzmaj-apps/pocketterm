package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ProtocolException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import kotlin.math.abs
import kotlin.math.roundToLong
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/** What answers a [Backend]: PocketTerm's own server, or PocketTerm set up on a Supabase project. */
enum class BackendKind {
    /** packages/pocketterm_server, on a VPS or built into a computer's app. */
    pocketterm,

    /**
     * The Edge Function `pocketterm` on a Supabase project: the same REST paths under
     * `/functions/v1/pocketterm`, the live channel over Supabase Realtime.
     */
    supabase,
}

/** [Backend.parse]'s answer: the backend, or why the URL can't be used. */
data class ParsedBackend(val backend: Backend?, val error: String?)

/** [Backend.health]'s answer: [error] null when all is well; [clockOffset] the server's clock ahead of this device's (null: not said). */
data class Health(val error: String?, val clockOffset: Duration?)

/**
 * The server this device connects through (packages/pocketterm_server/PROTOCOL.md): one on a
 * VPS, the one built into a computer's app, reached on the same network or through Tailscale,
 * or a Supabase project ([kind]). A phone signs in with a computer's code, a setup link with a
 * pairing code and that computer's key in it (`pocketterm://setup?url=…&code=…&d=…&k=…`), and
 * keeps the server where its platform side reads it too ([Native.getBackend]).
 */
data class Backend(
    /**
     * The server's public URL, `https://pocketterm.example.com` or `https://my-mac.tail1234.ts.net`,
     * without a trailing slash; for a Supabase project, the project's (`https://<ref>.supabase.co`).
     */
    val url: String,
    val kind: BackendKind = BackendKind.pocketterm,
) {
    val isSupabase: Boolean get() = kind == BackendKind.supabase

    /** Where the REST paths of PROTOCOL.md start (`<api>/v1/health`, …). */
    val api: String get() = if (isSupabase) "$url/functions/v1/pocketterm" else url

    private val where: Map<String, String>
        get() = buildMap {
            if (isSupabase) put("kind", "supabase")
            put("url", url)
        }

    val link: String get() = DartUri.build("pocketterm", "setup", where)

    /** [link] with a computer's [setup] token: what signs another computer in. A secret: whoever has it can add a computer. */
    fun linkWithSetup(setup: String): String = DartUri.build("pocketterm", "setup", where + ("setup" to setup))

    /**
     * [link] with a pairing code and, from a computer, its [computer] key: what the computer's QR
     * holds. A secret: whoever has it reads that computer's sessions.
     */
    fun linkWithCode(code: String, computer: ComputerKey? = null): String = DartUri.build(
        "pocketterm",
        "setup",
        buildMap {
            putAll(where)
            put("code", code)
            if (computer != null) {
                put("d", computer.desktop)
                put("k", computer.key.toBase64Url())
            }
        },
    )

    /** The host, for display. */
    val host: String get() = DartUri.tryParse(url)?.host ?: ""

    /** Reached through Tailscale (`tailscale serve` on a computer): only a device on that tailnet, with Tailscale on, can reach it. */
    val onTailnet: Boolean get() = host.endsWith(".ts.net")

    /** Why this device gets no answer from the server, worded for the person: a Tailscale address needs Tailscale on here. */
    val unreachable: String
        get() = if (onTailnet) {
            "Can't reach $host. It's on your tailnet: open Tailscale on this device and connect."
        } else {
            "Can't reach $host. Check your connection."
        }

    /** Asks the server for its health: reachable, a PocketTerm server, one this app speaks to. Null when all is well, else what's wrong. */
    suspend fun check(): String? = health().error

    /**
     * GET /v1/health: `error` is null when all is well, else what's wrong, worded for the person.
     * `clockOffset` is how far the server's clock is ahead of this device's (null when it didn't
     * say); see [clockWarning]. The headers and then the body each have [wait] to arrive.
     */
    suspend fun health(wait: Duration = 10.seconds): Health {
        fun fail(error: String) = Health(error, null)
        val client = Http.base.newBuilder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(wait.inWholeMilliseconds, TimeUnit.MILLISECONDS)
            .callTimeout(8_000 + 2 * wait.inWholeMilliseconds, TimeUnit.MILLISECONDS)
            .build()
        return try {
            val sent = System.currentTimeMillis()
            val res = client.newCall(Request.Builder().url("$api/v1/health").build()).await()
            val body = res.use { withContext(Dispatchers.IO) { it.body.string() } }
            val received = System.currentTimeMillis()
            val status = res.code
            if (isSupabase && status != 200 && status != 404) {
                return fail("Your Supabase project $host doesn't answer ($status). $PAUSED")
            }
            if (status in 520..530 && (res.header("cf-ray") != null || res.header("server")?.lowercase() == "cloudflare")) {
                return fail(
                    "Cloudflare answers for $host but can't reach your server ($status). Turn the orange cloud off for " +
                        "this name (DNS only), or set SSL/TLS to Full (strict) in Cloudflare.",
                )
            }
            if (status == 502 || status == 503 || status == 504) {
                return fail(
                    "$host answers, but the PocketTerm server behind it doesn't ($status). On a VPS, check that it runs: " +
                        "`docker compose ps` and `docker compose logs server`.",
                )
            }
            if (status == 404) return fail(noServer)
            if (status != 200) return fail("The server answered with an error ($status).")
            val health = jsonDecodeOrNull(body) ?: return fail(noServer)
            val version = health.obj?.get("pocketterm").long ?: return fail(noServer)
            if (version > PROTOCOL) return fail("Your server is newer than this app. Update PocketTerm, then retry.")
            val serverVersion = health.obj?.get("version").str
            if (serverVersion != null && olderThan(serverVersion, MIN_SERVER)) {
                return fail(
                    if (isSupabase) {
                        "Your Supabase project runs PocketTerm $serverVersion; this app needs $MIN_SERVER or newer. Set " +
                            "PocketTerm up on Supabase again from a computer (it updates the project), then retry."
                    } else {
                        "Your server runs PocketTerm server $serverVersion; this app needs $MIN_SERVER or newer. Update the " +
                            "server (on a VPS: `docker compose pull && docker compose up -d`; built into PocketTerm on a " +
                            "computer: update PocketTerm there), then retry."
                    },
                )
            }
            val time = parseDartDateTime(health.obj?.get("time").str ?: "")
            // The server read its clock about halfway through the round trip.
            val here = sent + (received - sent) / 2
            Health(null, time?.let { (it.toEpochMilli() - here).milliseconds })
        } catch (_: SSLException) {
            fail(
                "Couldn't make a secure connection to $host: its HTTPS certificate isn't valid or isn't there yet. A new " +
                    "server takes a minute to get one; on a VPS, `docker compose logs caddy` says what went wrong.",
            )
        } catch (e: ProtocolException) {
            if (e.message?.contains("follow-up") == true) {
                fail("$host keeps redirecting to itself. If it is behind Cloudflare, set SSL/TLS to Full (strict) in Cloudflare.")
            } else {
                fail(if (onTailnet) unreachable else "Couldn't reach $host. Check the URL and your connection.")
            }
        } catch (_: InterruptedIOException) {
            // OkHttp's timeouts (connect, read, the whole call).
            fail("$host took too long to answer.${if (isSupabase) " $PAUSED" else ""}")
        } catch (_: IOException) {
            // Refused, reset, or closed mid-answer, e.g. a captive portal or a proxy.
            fail(if (onTailnet) unreachable else "Couldn't reach $host. Check the URL and your connection.")
        } catch (_: IllegalArgumentException) {
            // A URL OkHttp can't request.
            fail(noServer)
        }
    }

    private val noServer: String
        get() = if (isSupabase) {
            "PocketTerm isn’t set up on this Supabase project. Set it up from a computer: PocketTerm, Supabase."
        } else {
            "No PocketTerm server answers at this URL."
        }

    /** Remembers this server where the platform side reads it too. */
    suspend fun save(native: Native) = native.setBackend(url = url, kind = if (isSupabase) kind.name else null)

    companion object {
        /** The protocol version this app speaks (GET /v1/health). */
        const val PROTOCOL = 1

        /** The oldest PocketTerm server this app works with (GET /v1/health's `version`). */
        const val MIN_SERVER = "0.1.0"

        /**
         * How far this device's clock may be off the server's before [clockWarning] speaks up: each
         * side drops sealed messages more than 5 minutes off its own clock, so two devices each
         * within 2 minutes stay within reach of each other.
         */
        val clockTolerance: Duration = 2.minutes

        /** What a Supabase project that doesn't answer may be: paused. */
        private const val PAUSED =
            "Free Supabase projects pause after about a week without use: open supabase.com/dashboard and restore " +
                "the project, then retry."

        private val COMPUTER_ID = Regex("^[a-z0-9]{8}$")

        /** [url] as typed, or a reason it can't be used. */
        fun parse(url: String, kind: BackendKind = BackendKind.pocketterm): ParsedBackend {
            var u = url.trim()
            while (u.endsWith("/")) u = u.substring(0, u.length - 1)
            // The API's own path works too.
            u = if (kind == BackendKind.supabase) {
                u.replaceFirst(Regex("/functions/v1/pocketterm(/v1)?$"), "")
            } else {
                u.replaceFirst(Regex("/v1$"), "")
            }
            val uri = DartUri.tryParse(u)
            if (u.isEmpty() || uri == null || !uri.hasScheme || uri.host.isEmpty()) {
                return ParsedBackend(
                    null,
                    if (kind == BackendKind.supabase) {
                        "Enter your Supabase project URL, like https://abcdefghijklmnop.supabase.co."
                    } else {
                        "Enter your server URL, like https://pocketterm.example.com."
                    },
                )
            }
            if (uri.scheme != "https" && !(uri.scheme == "http" && isThisMachine(uri.host))) {
                return ParsedBackend(null, "The server URL must start with https://.")
            }
            if (uri.path.isNotEmpty() || uri.hasQuery || uri.hasFragment) {
                return ParsedBackend(null, "Use the server URL alone, without a path.")
            }
            return ParsedBackend(Backend(u, kind), null)
        }

        /**
         * A `pocketterm://setup?url=…` link (its pairing code, if any, is [pairingCode]'s; its setup
         * token [setupToken]'s). A link carrying a `key` isn't one, nor one of a `kind` this app doesn't know.
         */
        fun fromLink(link: String): Backend? {
            val uri = DartUri.tryParse(link) ?: return null
            val q = uri.queryParameters
            if (uri.scheme != "pocketterm" || uri.host != "setup" || q.containsKey("key")) return null
            val url = q["url"]
            val kind = when (q["kind"]) {
                null, "", "pocketterm" -> BackendKind.pocketterm
                "supabase" -> BackendKind.supabase
                else -> null
            }
            return if (url == null || kind == null) null else parse(url, kind).backend
        }

        /** The pairing code in a setup link (the computer's QR), if it has one: it signs a phone in. */
        fun pairingCode(link: String): String? = param(link, "code")

        /** The setup token in a server's setup link, if it has one: it signs a computer in. */
        fun setupToken(link: String): String? = param(link, "setup")

        private fun param(link: String, name: String): String? {
            if (fromLink(link) == null) return null
            val value = DartUri.tryParse(link)?.queryParameters?.get(name)?.trim() ?: ""
            return value.ifEmpty { null }
        }

        /**
         * The computer and its channel key in a setup link (`d`, `k`: the computer's QR), if it has
         * them. A link without them still signs in; that computer then stays locked on the phone.
         */
        fun computerKey(link: String): ComputerKey? {
            if (fromLink(link) == null) return null
            val q = DartUri.tryParse(link)?.queryParameters ?: return null
            val desktop = q["d"] ?: ""
            val key = ChannelKey.tryParse(q["k"])
            if (key == null || !COMPUTER_ID.matches(desktop)) return null
            return ComputerKey(desktop, key)
        }

        /**
         * What to tell the person when this device's clock is [offset] off the server's by more than
         * [clockTolerance]; null when it's close enough or unknown.
         */
        fun clockWarning(offset: Duration?): String? {
            if (offset == null || offset.absoluteValue <= clockTolerance) return null
            // Dart: whole seconds (truncated), then minutes rounded half away from zero.
            val minutes = (abs(offset.inWholeSeconds) / 60.0).roundToLong()
            return "This device's clock is $minutes minutes ${if (offset.isNegative()) "ahead of" else "behind"} the server's, so " +
                "its messages to your other devices are dropped. Turn on Set time automatically in this device's date and " +
                "time settings."
        }

        /**
         * The server this phone was connected to, if any. One saved by an app from before (a Supabase
         * project, which came with a key) isn't one.
         */
        suspend fun load(native: Native): Backend? {
            val saved = native.getBackend() ?: return null
            if (saved.legacy) return null
            return parse(saved.url, kindOf(saved.kind)).backend
        }

        suspend fun clear(native: Native) = native.setBackend()

        private fun kindOf(name: String?): BackendKind =
            if (name == BackendKind.supabase.name) BackendKind.supabase else BackendKind.pocketterm

        /**
         * Plain http only to this machine (a computer reaching the server built into it); everything
         * else, Tailscale included (`tailscale serve` gives it a ts.net certificate), needs https.
         */
        private fun isThisMachine(host: String): Boolean =
            host == "localhost" || host == "::1" || host == "[::1]" || host.startsWith("127.")

        /** Whether version [a] (`1.2.3`) comes before [b]. */
        internal fun olderThan(a: String, b: String): Boolean {
            fun parts(v: String) = v.split('-').first().split('.').map { it.toIntOrNull() ?: 0 }
            val x = parts(a)
            val y = parts(b)
            for (i in 0 until 3) {
                val d = (x.getOrElse(i) { 0 }) - (y.getOrElse(i) { 0 })
                if (d != 0) return d < 0
            }
            return false
        }
    }
}
