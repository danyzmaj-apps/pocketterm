package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// JSON as the Dart code handles it: decoded into a tree and read leniently (a field of the
// wrong type is absent), encoded exactly as Dart's `jsonEncode` writes it, so byte counts
// (chunking, caps) agree across devices.

/** Parses [text] into a JSON tree; throws on malformed JSON (as Dart's `jsonDecode`). */
fun jsonDecode(text: String): JsonElement = Json.parseToJsonElement(text)

/** Parses [text], or null when it isn't JSON. */
fun jsonDecodeOrNull(text: String): JsonElement? = try {
    Json.parseToJsonElement(text)
} catch (_: Exception) {
    null
}

/** [element] as Dart's `jsonEncode` writes it: no whitespace, `\uXXXX` in lower case for other control characters and lone surrogates. */
fun jsonEncode(element: JsonElement): String = StringBuilder().also { writeJson(it, element) }.toString()

/** The UTF-8 length of [jsonEncode]. */
fun jsonByteLength(element: JsonElement): Int = jsonEncode(element).toByteArray(Charsets.UTF_8).size

private fun writeJson(out: StringBuilder, e: JsonElement) {
    when (e) {
        is JsonNull -> out.append("null")
        is JsonObject -> {
            out.append('{')
            var first = true
            for ((k, v) in e) {
                if (!first) out.append(',')
                first = false
                writeJsonString(out, k)
                out.append(':')
                writeJson(out, v)
            }
            out.append('}')
        }
        is JsonArray -> {
            out.append('[')
            e.forEachIndexed { i, v ->
                if (i > 0) out.append(',')
                writeJson(out, v)
            }
            out.append(']')
        }
        is JsonPrimitive -> if (e.isString) writeJsonString(out, e.content) else out.append(e.content)
    }
}

/** Appends [s] as a JSON string literal the way Dart's encoder does. */
fun writeJsonString(out: StringBuilder, s: String) {
    out.append('"')
    var i = 0
    while (i < s.length) {
        val c = s[i]
        when {
            c == '"' -> out.append("\\\"")
            c == '\\' -> out.append("\\\\")
            c == '\b' -> out.append("\\b")
            c == '\t' -> out.append("\\t")
            c == '\n' -> out.append("\\n")
            c == '\u000C' -> out.append("\\f")
            c == '\r' -> out.append("\\r")
            c < ' ' -> out.append("\\u00").append(hex2(c.code))
            c.isHighSurrogate() && i + 1 < s.length && s[i + 1].isLowSurrogate() -> {
                out.append(c).append(s[i + 1])
                i++
            }
            c.isSurrogate() -> out.append("\\u").append(c.code.toString(16).padStart(4, '0'))
            else -> out.append(c)
        }
        i++
    }
    out.append('"')
}

private fun hex2(v: Int) = v.toString(16).padStart(2, '0')

// Lenient readers: Dart's `x is String ? x : null` and friends.

/** The string, when this is a JSON string. */
val JsonElement?.str: String?
    get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

/** The integer, when this is a JSON number without a fraction or exponent (Dart's `is int`). */
val JsonElement?.long: Long?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p.isString || p is JsonNull) return null
        val c = p.content
        if (c.any { it == '.' || it == 'e' || it == 'E' }) return null
        return c.toLongOrNull()
    }

/** [long] when it fits an Int. */
val JsonElement?.int: Int?
    get() = long?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()

/** Any JSON number (Dart's `is num`). */
val JsonElement?.num: Double?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p.isString || p is JsonNull) return null
        return p.content.toDoubleOrNull()
    }

/** The boolean, when this is JSON true or false. */
val JsonElement?.bool: Boolean?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p.isString) return null
        return when (p.content) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }

/** The object, when this is a JSON object. */
val JsonElement?.obj: JsonObject?
    get() = this as? JsonObject

/** The array, when this is a JSON array. */
val JsonElement?.arr: JsonArray?
    get() = this as? JsonArray

/** Builds a JSON object from Kotlin values (see [toJsonElement]); entries keep their order. */
fun jsonOf(vararg pairs: Pair<String, Any?>): JsonObject =
    JsonObject(linkedMapOf<String, JsonElement>().apply { for ((k, v) in pairs) put(k, v.toJsonElement()) })

/** Kotlin values to JSON: null, String, Boolean, Number, JsonElement, Map, Iterable, Array. */
fun Any?.toJsonElement(): JsonElement = when (this) {
    null -> JsonNull
    is JsonElement -> this
    is String -> JsonPrimitive(this)
    is Boolean -> JsonPrimitive(this)
    is Int -> JsonPrimitive(this)
    is Long -> JsonPrimitive(this)
    is Double -> JsonPrimitive(this)
    is Float -> JsonPrimitive(this)
    is Number -> JsonPrimitive(this)
    is Map<*, *> -> JsonObject(linkedMapOf<String, JsonElement>().apply { for ((k, v) in this@toJsonElement) put(k.toString(), v.toJsonElement()) })
    is Iterable<*> -> JsonArray(map { it.toJsonElement() })
    is Array<*> -> JsonArray(map { it.toJsonElement() })
    else -> throw IllegalArgumentException("not JSON: ${this::class}")
}
