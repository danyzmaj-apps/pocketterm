package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.security.MessageDigest
import java.util.Base64

/** The frozen cross-language vectors (tool/vectors/vectors.json, see its README). */
object Vectors {
    val repoRoot: File by lazy {
        val p = System.getProperty("pocketterm.repoRoot")
        if (p != null) File(p) else generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "tool/vectors/vectors.json").isFile }
    }

    val root: JsonObject by lazy { jsonDecode(File(repoRoot, "tool/vectors/vectors.json").readText()).obj!! }

    /** A top-level section, e.g. `crypto`. */
    fun section(name: String): JsonObject = root[name].obj ?: error("no section $name")

    fun b64(s: String): ByteArray = Base64.getDecoder().decode(s)

    fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    fun toHex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }

    /**
     * Expands the README's repeated inputs: `{"repeat": u, "times": n, "then": s, "prefix": p}`;
     * a plain JSON string is itself.
     */
    fun text(e: JsonElement?): String? {
        e.str?.let { return it }
        val o = e.obj ?: return null
        val unit = o["repeat"].str ?: return null
        return (o["prefix"].str ?: "") + unit.repeat(o["times"].int!!) + (o["then"].str ?: "")
    }

    /**
     * Checks [actual] against a value or a summary
     * `{codeUnits, utf8Bytes, jsonBytes, sha256, head, tail}` (README "Summaries").
     */
    fun matches(expected: JsonElement?, actual: String): Boolean {
        expected.str?.let { return it == actual }
        val o = expected.obj ?: return false
        o["codeUnits"].int?.let { if (it != actual.length) return false }
        val utf8 = actual.toByteArray(Charsets.UTF_8)
        o["utf8Bytes"].int?.let { if (it != utf8.size) return false }
        // The bytes inside the JSON string, without its quotes.
        o["jsonBytes"].int?.let { if (it != jsonEncode(kotlinx.serialization.json.JsonPrimitive(actual)).toByteArray(Charsets.UTF_8).size - 2) return false }
        o["sha256"].str?.let { if (it != toHex(MessageDigest.getInstance("SHA-256").digest(utf8))) return false }
        val cps = actual.codePoints().toArray()
        o["head"].str?.let { if (it != String(cps, 0, minOf(40, cps.size))) return false }
        o["tail"].str?.let { if (it != String(cps, maxOf(0, cps.size - 40), minOf(40, cps.size))) return false }
        return true
    }
}
