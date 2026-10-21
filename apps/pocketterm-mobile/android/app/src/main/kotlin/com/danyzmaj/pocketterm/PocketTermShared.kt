package com.danyzmaj.pocketterm

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
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

    /** The connected PocketTerm server's URL. */
    fun backendUrl(c: Context): String? = prefs(c).getString("backendUrl", null)

    /** The key an app from before saved with a Supabase project, if any: its URL is no PocketTerm server. */
    fun legacyBackendKey(c: Context): String? = prefs(c).getString("backendKey", null)

    fun setBackendUrl(c: Context, url: String?) {
        prefs(c).edit().apply {
            if (url == null) remove("backendUrl") else putString("backendUrl", url)
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

    fun removeChannelKey(c: Context, desktop: String) {
        keyPrefs(c).edit().remove(desktop).commit()
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
}
