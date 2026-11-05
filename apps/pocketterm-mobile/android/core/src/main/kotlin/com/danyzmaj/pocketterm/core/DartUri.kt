package com.danyzmaj.pocketterm.core

import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * A URI read the way Dart's `Uri.parse` reads it, as far as links and server URLs need:
 * the scheme and host in lower case (the host without IPv6 brackets), the query's parameters
 * decoded with `+` as a space and the last of a repeated name winning. Setup links and
 * server URLs travel between devices, so every port reads them alike.
 */
class DartUri private constructor(
    val scheme: String,
    val host: String,
    val port: Int?,
    val path: String,
    val query: String?,
    val fragment: String?,
) {
    val hasScheme: Boolean get() = scheme.isNotEmpty()
    val hasQuery: Boolean get() = query != null
    val hasFragment: Boolean get() = fragment != null

    /** Dart's `queryParameters`. */
    val queryParameters: Map<String, String> by lazy { splitQueryString(query ?: "") }

    companion object {
        private val SPLIT = Regex("""^(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$""", RegexOption.DOT_MATCHES_ALL)
        private val SCHEME = Regex("""^[A-Za-z][A-Za-z0-9+.\-]*$""")

        /** [text] parsed, or null where Dart's `Uri.tryParse` gives null. */
        fun tryParse(text: String): DartUri? {
            val m = SPLIT.matchEntire(text) ?: return null
            val scheme = m.groups[1]?.value ?: ""
            if (scheme.isNotEmpty() && !SCHEME.matches(scheme)) return null
            var host = ""
            var port: Int? = null
            m.groups[2]?.value?.let { authority ->
                var hostPort = authority.substringAfterLast('@')
                if (hostPort.startsWith('[')) {
                    val end = hostPort.indexOf(']')
                    if (end < 0) return null
                    host = hostPort.substring(1, end)
                    hostPort = hostPort.substring(end + 1)
                    if (hostPort.isNotEmpty() && !hostPort.startsWith(':')) return null
                    port = portOf(hostPort.removePrefix(":")) ?: return null
                    if (port == -1) port = null
                } else {
                    val colon = hostPort.lastIndexOf(':')
                    host = if (colon >= 0) hostPort.substring(0, colon) else hostPort
                    if (colon >= 0) {
                        port = portOf(hostPort.substring(colon + 1)) ?: return null
                        if (port == -1) port = null
                    }
                    host = percentDecode(host, plusIsSpace = false).replace(" ", "%20")
                }
                host = host.lowercase()
            }
            return DartUri(scheme.lowercase(), host, port, m.groups[3]?.value ?: "", m.groups[4]?.value, m.groups[5]?.value)
        }

        // -1: no port given ("host:" counts as none); null: not a port.
        private fun portOf(s: String): Int? = when {
            s.isEmpty() -> -1
            s.all { it in '0'..'9' } -> s.toIntOrNull()
            else -> null
        }

        /** Dart's `Uri.splitQueryString`. */
        fun splitQueryString(query: String): Map<String, String> {
            val out = linkedMapOf<String, String>()
            for (element in query.split('&')) {
                val i = element.indexOf('=')
                if (i == -1) {
                    if (element.isNotEmpty()) out[decodeQueryComponent(element)] = ""
                } else if (i != 0) {
                    out[decodeQueryComponent(element.substring(0, i))] = decodeQueryComponent(element.substring(i + 1))
                }
            }
            return out
        }

        /** `+` as a space and `%XX` as UTF-8 bytes; a `%` that starts no escape stays as it is. */
        fun decodeQueryComponent(s: String): String = percentDecode(s, plusIsSpace = true)

        private fun percentDecode(s: String, plusIsSpace: Boolean): String {
            if ('%' !in s && !(plusIsSpace && '+' in s)) return s
            val out = StringBuilder()
            val bytes = ByteArrayOutputStream()
            fun flush() {
                if (bytes.size() > 0) {
                    out.append(bytes.toByteArray().toString(Charsets.UTF_8))
                    bytes.reset()
                }
            }
            var i = 0
            while (i < s.length) {
                val c = s[i]
                val hex = if (c == '%' && i + 2 < s.length) s.substring(i + 1, i + 3).toIntOrNull(16) else null
                when {
                    hex != null -> {
                        bytes.write(hex)
                        i += 3
                        continue
                    }
                    c == '+' && plusIsSpace -> {
                        flush()
                        out.append(' ')
                    }
                    else -> {
                        flush()
                        out.append(c)
                    }
                }
                i++
            }
            flush()
            return out.toString()
        }

        /** A query value as Dart's `Uri(queryParameters: …)` writes it: unreserved characters as they are, a space as `+`, the rest `%XX`. */
        fun encodeQueryComponent(s: String): String {
            val out = StringBuilder()
            for (b in s.toByteArray(Charsets.UTF_8)) {
                val c = b.toInt() and 0xff
                when {
                    c in 'a'.code..'z'.code || c in 'A'.code..'Z'.code || c in '0'.code..'9'.code ||
                        c == '-'.code || c == '.'.code || c == '_'.code || c == '~'.code -> out.append(c.toChar())
                    c == ' '.code -> out.append('+')
                    else -> out.append('%').append("%02X".format(c))
                }
            }
            return out.toString()
        }

        /** `scheme://host?k=v&…` as Dart's `Uri(scheme:, host:, queryParameters:).toString()` writes it. */
        fun build(scheme: String, host: String, queryParameters: Map<String, String>): String =
            "$scheme://$host" + if (queryParameters.isEmpty()) "" else "?" +
                queryParameters.entries.joinToString("&") { (k, v) -> "${encodeQueryComponent(k)}=${encodeQueryComponent(v)}" }
    }
}

// Dates as Dart's DateTime reads and writes them on the wire (ISO-8601).

private val DART_DATE = Regex(
    """^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)?)?$""",
)

/** Dart's `DateTime.tryParse`: ISO-8601 with or without a zone (none = this device's local time); null when it isn't one. */
fun parseDartDateTime(text: String): Instant? {
    val m = DART_DATE.matchEntire(text) ?: return null
    return try {
        val g = m.groupValues
        fun num(i: Int) = if (g[i].isEmpty()) 0 else g[i].toInt()
        val frac = g[7]
        val nanos = if (frac.isEmpty()) 0 else frac.take(6).padEnd(9, '0').toInt()
        // Dart rolls over out-of-range fields (month 13, second 60); LocalDateTime.of would refuse them.
        val local = LocalDateTime.of(g[1].toInt(), 1, 1, 0, 0)
            .plusMonths(num(2) - 1L).plusDays(num(3) - 1L)
            .plusHours(num(4).toLong()).plusMinutes(num(5).toLong()).plusSeconds(num(6).toLong()).plusNanos(nanos.toLong())
        when {
            g[8].isEmpty() -> local.atZone(ZoneId.systemDefault()).toInstant()
            g[9].isEmpty() -> local.toInstant(ZoneOffset.UTC)
            else -> {
                val sign = if (g[9] == "-") -1 else 1
                val offsetMinutes = sign * (num(10) * 60 + num(11))
                local.toInstant(ZoneOffset.UTC).minusSeconds(offsetMinutes * 60L)
            }
        }
    } catch (_: Exception) {
        null
    }
}

private val ISO_SECONDS = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss").withZone(ZoneOffset.UTC)

/** Dart's `toUtc().toIso8601String()`: milliseconds always, microseconds when there are some, `Z`. */
fun dartIsoUtc(instant: Instant): String {
    val micros = instant.nano / 1000
    val frac = if (micros % 1000 == 0) "%03d".format(micros / 1000) else "%06d".format(micros)
    return "${ISO_SECONDS.format(instant)}.${frac}Z"
}
