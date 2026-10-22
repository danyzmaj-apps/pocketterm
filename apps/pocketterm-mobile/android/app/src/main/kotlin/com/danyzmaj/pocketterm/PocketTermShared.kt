package com.danyzmaj.pocketterm

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * What the app, its notifications and its push service share, in
 * app-private storage: the server the phone connected (written by
 * packages/pocketterm_core/lib/backend.dart), the FCM token, each
 * computer's channel key and the phone's sign-in on its server. Android's
 * ios/Shared/PocketTermShared.swift.
 */
object PocketTermShared {
    private const val FILE = "pocketterm_shared"

    private fun prefs(c: Context): SharedPreferences = c.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** The connected server's URL. */
    fun backendUrl(c: Context): String? = prefs(c).getString("backendUrl", null)

    /** What kind of server it is: "supabase", or null for a PocketTerm server. */
    fun backendKind(c: Context): String? = prefs(c).getString("backendKind", null)

    /** The key an app from before saved with a Supabase project, if any: its URL is no PocketTerm server. */
    fun legacyBackendKey(c: Context): String? = prefs(c).getString("backendKey", null)

    fun setBackend(c: Context, url: String?, kind: String?) {
        prefs(c).edit().apply {
            if (url == null) remove("backendUrl") else putString("backendUrl", url)
            if (url == null || kind == null) remove("backendKind") else putString("backendKind", kind)
            remove("backendKey")
        }.apply()
    }

    /** The FCM token this phone registered (registerPush, PushService.onNewToken). */
    fun fcmToken(c: Context): String? = prefs(c).getString("fcmToken", null)

    fun setFcmToken(c: Context, token: String) {
        prefs(c).edit().putString("fcmToken", token).apply()
    }

    /** The per-phone push key from before end-to-end encryption: no server has a use for it now. */
    fun forgetPushKey(c: Context) {
        prefs(c).edit().remove("pushKey").apply()
    }

    // Channel keys: each computer's (32 bytes), which the phone got only by
    // scanning that computer's code. Kept wrapped (AES-256-GCM, the computer's
    // id as AAD) by a key that lives in the Android Keystore and never leaves
    // it; nothing of the app's is backed up (AndroidManifest.xml).

    private const val KEYS_FILE = "pocketterm_channel_keys"
    private const val WRAP_ALIAS = "pocketterm_channel_wrap"

    private fun keyPrefs(c: Context): SharedPreferences = c.getSharedPreferences(KEYS_FILE, Context.MODE_PRIVATE)

    @Synchronized
    private fun wrapKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(WRAP_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(WRAP_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
        }.generateKey()
    }

    /** Stores [key] (32 bytes) for computer [desktop], replacing the one it had. */
    fun setChannelKey(c: Context, desktop: String, key: ByteArray) {
        require(key.size == 32) { "a channel key is 32 bytes" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        cipher.updateAAD(desktop.toByteArray(Charsets.UTF_8))
        val wrapped = cipher.iv + cipher.doFinal(key)
        keyPrefs(c).edit().putString(desktop, Base64.encodeToString(wrapped, Base64.NO_WRAP)).commit()
    }

    /**
     * Every computer's key goes (sign-out), and the Keystore key that wraps
     * them with it. The sign-in it also wraps goes too: it couldn't be read
     * any more.
     */
    @Synchronized
    fun removeAllChannelKeys(c: Context) {
        keyPrefs(c).edit().clear().commit()
        tokenPrefs(c).edit().clear().commit()
        runCatching {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(WRAP_ALIAS)
        }
    }

    /** Computer [desktop]'s key; null without one, or when it doesn't unwrap. */
    fun channelKey(c: Context, desktop: String): ByteArray? = runCatching {
        val wrapped = Base64.decode(keyPrefs(c).getString(desktop, null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, wrapped, 0, 12))
        cipher.updateAAD(desktop.toByteArray(Charsets.UTF_8))
        cipher.doFinal(wrapped, 12, wrapped.size - 12)
    }.getOrNull()

    /** Every computer's key that unwraps, by its id. */
    fun channelKeys(c: Context): Map<String, ByteArray> =
        keyPrefs(c).all.keys.mapNotNull { d -> channelKey(c, d)?.let { d to it } }.toMap()

    /**
     * What a push names the computer that sealed it by, instead of its id (pocketterm_core's pushTag): the first
     * 8 bytes of HMAC-SHA256([key], "pocketterm/v1|push-tag"), base64url without padding.
     */
    fun pushTag(key: ByteArray): String = tag(key, "pocketterm/v1|push-tag", 8)

    /**
     * What a push names coding session [routed] (`<desktop id>/<key>`) by (pocketterm_core's sessionTag): the first
     * 16 bytes of HMAC-SHA256([key], "pocketterm/v1|push-session|<routed>"), base64url without padding.
     */
    fun sessionTag(key: ByteArray, routed: String): String = tag(key, "pocketterm/v1|push-session|$routed", 16)

    private fun tag(key: ByteArray, what: String, length: Int): String {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
        val bytes = mac.doFinal(what.toByteArray(Charsets.UTF_8)).copyOf(length)
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    /** The computer among [keys] (by id) whose push tag is [tag]: its id and key; null when none. */
    fun computer(tag: String, keys: Map<String, ByteArray>): Pair<String, ByteArray>? =
        keys.entries.firstOrNull { pushTag(it.value) == tag }?.toPair()

    // The phone's sign-in on its server (the device token and what came with
    // it, one string the Dart side reads), wrapped like the channel keys.

    private const val TOKEN_FILE = "pocketterm_device_token"
    private const val TOKEN_AAD = "device-token"

    private fun tokenPrefs(c: Context): SharedPreferences = c.getSharedPreferences(TOKEN_FILE, Context.MODE_PRIVATE)

    /** Replaces it; null removes it. */
    fun setDeviceToken(c: Context, value: String?) {
        if (value == null) {
            tokenPrefs(c).edit().remove("token").commit()
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        cipher.updateAAD(TOKEN_AAD.toByteArray(Charsets.UTF_8))
        val wrapped = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        tokenPrefs(c).edit().putString("token", Base64.encodeToString(wrapped, Base64.NO_WRAP)).commit()
    }

    /** Null without one, or when it doesn't unwrap. */
    fun deviceToken(c: Context): String? = runCatching {
        val wrapped = Base64.decode(tokenPrefs(c).getString("token", null) ?: return null, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, wrapped, 0, 12))
        cipher.updateAAD(TOKEN_AAD.toByteArray(Charsets.UTF_8))
        String(cipher.doFinal(wrapped, 12, wrapped.size - 12), Charsets.UTF_8)
    }.getOrNull()

    /**
     * Opens [sealed] (nonce 12 ‖ ciphertext ‖ tag 16, AES-256-GCM) with [key]
     * and [aad]; null if it was made with another key or for anything else.
     */
    fun open(sealed: ByteArray, key: ByteArray, aad: String): ByteArray? = runCatching {
        if (key.size != 32 || sealed.size < 12 + 16) return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealed, 0, 12))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        cipher.doFinal(sealed, 12, sealed.size - 12)
    }.getOrNull()

    // Fresh pushes: a sealed notice older (or further ahead) than FRESH_FOR,
    // or one whose id came before, shows only the generic alert. The relay
    // or anyone on the way could hold one back and send it again later.

    private const val FRESH_FOR = 10 * 60 * 1000L
    /** More than a computer sends in FRESH_FOR. */
    private const val SEEN_KEPT = 256

    /** Whether a notice sealed at [ts] (ms since 1970) with [id] is new; remembers [id] (the last 256) either way. */
    @Synchronized
    fun isFreshPush(c: Context, ts: Long?, id: String?): Boolean {
        if (ts == null || id.isNullOrEmpty()) return false
        val seen = prefs(c).getString("seenPushIds", null)?.split('\n')?.filter { it.isNotEmpty() } ?: emptyList()
        val repeated = id in seen
        if (!repeated) {
            prefs(c).edit().putString("seenPushIds", (seen + id).takeLast(SEEN_KEPT).joinToString("\n")).apply()
        }
        return !repeated && kotlin.math.abs(System.currentTimeMillis() - ts) <= FRESH_FOR
    }
}
