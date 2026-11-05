package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.security.GeneralSecurityException
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

// End-to-end encryption between a computer and its phones (docs/ARCHITECTURE.md,
// SECURITY.md). Each computer has one channel key, made on the computer and
// handed to a phone only in its QR code; the server relays what it seals and
// can't read it. Sealed bytes are nonce (12) || ciphertext || tag (16),
// AES-256-GCM, with additional data naming what they are, so a message can't
// be moved to another computer, event, image or push.

/** A computer (its id, Desktops.kt) and its channel key, as the computer's QR code hands them to a phone. */
data class ComputerKey(val desktop: String, val key: ChannelKey)

/** One computer's channel key: 32 random bytes. */
class ChannelKey(bytes: ByteArray) {
    init {
        require(bytes.size == LENGTH) { "A channel key is $LENGTH bytes, not ${bytes.size}." }
    }

    /** A copy; the key never hands out its own array. */
    val bytes: ByteArray = bytes.copyOf()

    /** Standard base64 with padding: how the phone's native side keeps it. */
    fun toBase64(): String = base64Encode(bytes)

    /** URL-safe base64 without padding: how a setup link carries it. */
    fun toBase64Url(): String = base64UrlEncode(bytes).replace("=", "")

    override fun equals(other: Any?): Boolean = other is ChannelKey && other.bytes.contentEquals(bytes)

    override fun hashCode(): Int = bytes.contentHashCode()

    override fun toString(): String = "ChannelKey(…)"

    companion object {
        const val LENGTH = 32

        /** A new random key. */
        fun generate(): ChannelKey = ChannelKey(ByteArray(LENGTH).also { random.nextBytes(it) })

        /** A key as [toBase64] or [toBase64Url] write it, with or without padding; null when it isn't one. */
        fun tryParse(text: String?): ChannelKey? {
            if (text == null) return null
            val bytes = base64UrlNormalizedDecode(text.trim().replace('+', '-').replace('/', '_')) ?: return null
            return if (bytes.size == LENGTH) ChannelKey(bytes) else null
        }
    }
}

/** The additional data of a live channel [event] on [topic]. */
fun channelAad(topic: String, event: String): String = "pocketterm/v1|$topic|$event"

/**
 * The additional data of an image, or a file a prompt takes, stored at [path] (the same for
 * both: the file's name and type travel in the sealed prompt).
 */
fun imageAad(path: String): String = "pocketterm/v1|image|$path"

/** The additional data of a push from computer [desktopId]. */
fun pushAad(desktopId: String): String = "pocketterm/v1|push|$desktopId"

/** The additional data of a followed session's update (Android) from computer [desktopId]. */
fun activityAad(desktopId: String): String = "pocketterm/v1|activity|$desktopId"

/**
 * What a push says about the computer that sealed it, instead of its id: the first 8 bytes of
 * HMAC-SHA256([key], `pocketterm/v1|push-tag`) in base64url without padding (11 characters).
 * The same for every push from that computer and meaningless without its key: the phone finds
 * the key whose tag it is, the relay and the push services can't tell which computer it is.
 */
fun pushTag(key: ChannelKey): String = tag(key, "pocketterm/v1|push-tag", 8)

/**
 * What a push says about coding session [routedKey] (`<desktop id>/<key>`): the first 16 bytes
 * of HMAC-SHA256([key], `pocketterm/v1|push-session|<routedKey>`) in base64url without padding
 * (22 characters). It lets a newer push for the session replace an older one (collapse id) and,
 * on Android, names the session a plain end is for, without telling anyone on the way which
 * session it is.
 */
fun sessionTag(key: ChannelKey, routedKey: String): String = tag(key, "pocketterm/v1|push-session|$routedKey", 16)

private fun tag(key: ChannelKey, what: String, length: Int): String =
    base64UrlEncode(hmacSha256(key.bytes, what.toByteArray(Charsets.UTF_8)).copyOf(length)).replace("=", "")

/** HMAC-SHA256 of [message] with [key]. */
fun hmacSha256(key: ByteArray, message: ByteArray): ByteArray =
    Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256"))
        doFinal(message)
    }

private const val NONCE_LENGTH = 12
private const val TAG_LENGTH = 16

/** What sealing adds to the bytes: the nonce and the tag. */
const val sealedOverhead: Int = NONCE_LENGTH + TAG_LENGTH

private val random = SecureRandom()

/** [plain] sealed with [key] for [aad]: nonce || ciphertext || tag. */
fun sealBytes(key: ChannelKey, plain: ByteArray, aad: String): ByteArray =
    sealBytesWithNonce(key, plain, aad, ByteArray(NONCE_LENGTH).also { random.nextBytes(it) })

/** [sealBytes] with a given [nonce]: only for tests that pin the output (never reuse a nonce). */
internal fun sealBytesWithNonce(key: ChannelKey, plain: ByteArray, aad: String, nonce: ByteArray): ByteArray {
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key.bytes, "AES"), GCMParameterSpec(TAG_LENGTH * 8, nonce))
    cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
    return nonce + cipher.doFinal(plain)
}

/**
 * What [sealed] holds, or null when it wasn't sealed with [key] for [aad] (another key,
 * another purpose, changed on the way, too short).
 */
fun openBytes(key: ChannelKey, sealed: ByteArray, aad: String): ByteArray? {
    if (sealed.size < NONCE_LENGTH + TAG_LENGTH) return null
    return try {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key.bytes, "AES"),
            GCMParameterSpec(TAG_LENGTH * 8, sealed, 0, NONCE_LENGTH),
        )
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        cipher.doFinal(sealed, NONCE_LENGTH, sealed.size - NONCE_LENGTH)
    } catch (_: GeneralSecurityException) {
        null
    }
}

/** The version an envelope's `v` says. */
const val envelopeVersion: Int = 1

/** [message] as it goes on the live channel: `{"v":1,"n":"<base64 nonce>","c":"<base64 ciphertext and tag>"}`. */
fun sealEnvelope(key: ChannelKey, message: JsonObject, aad: String): JsonObject {
    val sealed = sealBytes(key, jsonEncode(message).toByteArray(Charsets.UTF_8), aad)
    return jsonOf(
        "v" to envelopeVersion,
        "n" to base64Encode(sealed.copyOfRange(0, NONCE_LENGTH)),
        "c" to base64Encode(sealed.copyOfRange(NONCE_LENGTH, sealed.size)),
    )
}

/** What [openEnvelope] found: the [message], or why it was dropped ([drop]). */
data class OpenedEnvelope(val message: JsonObject?, val drop: String?)

/**
 * The message in [envelope], or why it was dropped: `version` (not one this reads), `sealed`
 * (not sealed with [key] for [aad]), `json` (not a JSON object inside).
 */
fun openEnvelope(key: ChannelKey, envelope: JsonObject, aad: String): OpenedEnvelope {
    // Dart's `!=` on a decoded number: 1.0 equals 1.
    if (envelope["v"].num != envelopeVersion.toDouble()) return OpenedEnvelope(null, "version")
    val n = envelope["n"].str
    val c = envelope["c"].str
    if (n == null || c == null) return OpenedEnvelope(null, "sealed")
    val nonce = base64DecodeOrNull(n) ?: return OpenedEnvelope(null, "sealed")
    val rest = base64DecodeOrNull(c) ?: return OpenedEnvelope(null, "sealed")
    if (nonce.size != NONCE_LENGTH) return OpenedEnvelope(null, "sealed")
    val plain = openBytes(key, nonce + rest, aad) ?: return OpenedEnvelope(null, "sealed")
    val message = utf8DecodeOrNull(plain)?.let { jsonDecodeOrNull(it) }
    return if (message is JsonObject) OpenedEnvelope(message, null) else OpenedEnvelope(null, "json")
}

/** A new message id: 16 random URL-safe characters. */
fun newMessageId(): String = base64UrlEncode(ByteArray(12).also { random.nextBytes(it) })

/**
 * Drops opened live channel messages that are stale, seen before or out of order. Every
 * message carries `ts` (ms since epoch), `mid` (a random id), `ep` (its sender's epoch: random,
 * new each time a sender starts) and `seq` (that sender's count, from 1). Dropped: a `ts` more
 * than [window] off this clock or before [notBefore] (sent before this guard existed, so before
 * this app started: nothing here remembers it), a `mid` seen in the last [remember], and a
 * `seq` at or below the last one taken for its `ep`. Memory stays bounded: epochs and ids go
 * after [remember] unseen, and past [maxEpochs] / [maxIds] the oldest go first (a message that
 * old is out of [window] by then anyway, or caught by the other check).
 */
class ReplayGuard(
    val window: Duration = 5.minutes,
    /** How long an id or an epoch is kept after it was last seen; at least twice [window], so a message taken once can't come back in time. */
    val remember: Duration = 10.minutes,
    val maxEpochs: Int = 64,
    val maxIds: Int = 10000,
    /** Milliseconds since epoch. */
    private val clock: () -> Long = System::currentTimeMillis,
) {
    /** When this guard started (ms since epoch): messages from before it are dropped. */
    val notBefore: Long = clock()

    private class Epoch(val seq: Long, val at: Long)

    // Both in the order last seen, oldest first.
    private val ids = LinkedHashMap<String, Long>()
    private val epochs = LinkedHashMap<String, Epoch>()

    /** Null when [message] may go on (and it is remembered), else why not: `time`, `replay` or `order`. */
    @Synchronized
    fun check(message: JsonObject): String? {
        val now = clock()
        val ts = message["ts"].long
        if (ts == null || kotlin.math.abs(now - ts) > window.inWholeMilliseconds || ts < notBefore) return "time"
        val mid = message["mid"].str
        val ep = message["ep"].str
        val seq = message["seq"].long
        if (mid.isNullOrEmpty() || ep.isNullOrEmpty() || seq == null || seq < 1) return "replay"
        val rememberMs = remember.inWholeMilliseconds
        ids.values.removeAll { now - it > rememberMs }
        epochs.values.removeAll { now - it.at > rememberMs }
        if (ids.containsKey(mid)) return "replay"
        val last = epochs.remove(ep)
        if (last != null && seq <= last.seq) {
            epochs[ep] = last
            return "order"
        }
        epochs[ep] = Epoch(seq, now)
        ids[mid] = now
        while (epochs.size > maxEpochs) epochs.remove(epochs.keys.first())
        while (ids.size > maxIds) ids.remove(ids.keys.first())
        return null
    }

    companion object {
        private val byTopic = HashMap<String, ReplayGuard>()

        /**
         * One guard per computer ([topic], its id) for this whole run of the app: it outlives each
         * channel, so a channel made again (the bridge restarted, another sign-in) still knows what it took.
         */
        @JvmStatic
        fun of(topic: String): ReplayGuard = synchronized(byTopic) { byTopic.getOrPut(topic) { ReplayGuard() } }
    }
}

/**
 * A push [notice] (`{title, body, session?, state?}`) from computer [desktopId], sealed with its
 * [key] for the phones (AAD [pushAad]), in base64: the `enc` the server forwards. Inside it gains
 * `ts` (ms since epoch) and `id` (random), so a phone can refuse an old or repeated one.
 */
fun sealNotice(key: ChannelKey, desktopId: String, notice: JsonObject): String = sealPush(key, notice, pushAad(desktopId))

/**
 * A followed session's [activity] (`{session, state, since, kind?}`) from computer [desktopId]
 * for Android phones, sealed like [sealNotice] (also with `ts` and `id` inside) but for [activityAad].
 */
fun sealActivity(key: ChannelKey, desktopId: String, activity: JsonObject): String =
    sealPush(key, activity, activityAad(desktopId))

private fun sealPush(key: ChannelKey, body: JsonObject, aad: String): String {
    val inner = LinkedHashMap(body).apply {
        put("ts", JsonPrimitive(System.currentTimeMillis()))
        put("id", JsonPrimitive(newMessageId()))
    }
    return base64Encode(sealBytes(key, jsonEncode(JsonObject(inner)).toByteArray(Charsets.UTF_8), aad))
}

// Base64 as Dart's dart:convert does it.

/** Standard base64 with padding (Dart's `base64Encode`). */
fun base64Encode(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

/** URL-safe base64 with padding (Dart's `base64UrlEncode`). */
fun base64UrlEncode(bytes: ByteArray): String = Base64.getUrlEncoder().encodeToString(bytes)

/**
 * Dart's `base64Decode`: either alphabet (even mixed), padding optional (`%3D` counts as `=`);
 * null where Dart throws a FormatException.
 */
fun base64DecodeOrNull(text: String): ByteArray? = try {
    Base64.getDecoder().decode(text.replace("%3D", "=").replace("%3d", "=").replace('-', '+').replace('_', '/'))
} catch (_: IllegalArgumentException) {
    null
}

// Dart's `base64Url.decode(base64Url.normalize(s))`, after the caller mapped `+` and `/`:
// the URL-safe alphabet only, padding optional.
private fun base64UrlNormalizedDecode(text: String): ByteArray? {
    val s = text.replace("%3D", "=").replace("%3d", "=")
    if (s.any { it == '+' || it == '/' }) return null
    return try {
        Base64.getUrlDecoder().decode(s)
    } catch (_: IllegalArgumentException) {
        null
    }
}

/** Strict UTF-8 decoding (Dart's `utf8.decode`): null on malformed bytes. */
fun utf8DecodeOrNull(bytes: ByteArray): String? = try {
    Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString()
} catch (_: CharacterCodingException) {
    null
}
