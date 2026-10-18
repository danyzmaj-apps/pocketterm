package com.danyzmaj.pocketterm

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import org.json.JSONObject
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * What the app, its notifications and its push service share, in
 * app-private storage: the backend (the Supabase project the user connected,
 * written by packages/pocketterm_core/lib/backend.dart), the FCM token and
 * the push key. Android's ios/Shared/PocketTermShared.swift.
 */
object PocketTermShared {
    private const val FILE = "pocketterm_shared"

    data class Backend(val url: String, val key: String)

    private fun prefs(c: Context): SharedPreferences = c.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun backend(c: Context): Backend? {
        val p = prefs(c)
        val url = p.getString("backendUrl", null) ?: return null
        val key = p.getString("backendKey", null) ?: return null
        return Backend(url, key)
    }

    fun setBackend(c: Context, backend: Backend?) {
        prefs(c).edit().apply {
            if (backend == null) {
                remove("backendUrl")
                remove("backendKey")
            } else {
                putString("backendUrl", backend.url)
                putString("backendKey", backend.key)
            }
        }.apply()
    }

    /** The FCM token this phone registered (registerPush, PushService.onNewToken). */
    fun fcmToken(c: Context): String? = prefs(c).getString("fcmToken", null)

    fun setFcmToken(c: Context, token: String) {
        prefs(c).edit().putString("fcmToken", token).apply()
    }

    /**
     * This phone's push key (32 bytes): made here, given only to the user's
     * own server (functions/push), which seals each push with it; PushService
     * opens them. Made on first use, kept across sign-ins.
     */
    fun pushKey(c: Context): ByteArray? =
        prefs(c).getString("pushKey", null)?.let { Base64.decode(it, Base64.NO_WRAP) }

    @Synchronized
    fun makePushKey(c: Context): ByteArray {
        pushKey(c)?.let { return it }
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs(c).edit().putString("pushKey", Base64.encodeToString(key, Base64.NO_WRAP)).commit()
        return key
    }

    /**
     * A push's `enc`: base64(nonce 12 ‖ ciphertext ‖ tag 16), AES-256-GCM with
     * [pushKey]. Null if anything is off.
     */
    fun open(c: Context, enc: String): JSONObject? = runCatching {
        val sealed = Base64.decode(enc, Base64.DEFAULT)
        val key = pushKey(c) ?: return null
        if (sealed.size < 12 + 16) return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealed, 0, 12))
        JSONObject(String(cipher.doFinal(sealed, 12, sealed.size - 12), Charsets.UTF_8))
    }.getOrNull()
}
