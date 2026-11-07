package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.runBlocking
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The platform side as far as a sign-in goes: the server, the device token and the computers' keys. */
private class SignInNative(var backend: SavedBackend?) : Native {
    var token: String? = "token-1"
    var keys = mutableMapOf("abcd1234" to "AAAA")

    override suspend fun getBackend(): SavedBackend? = backend
    override suspend fun setBackend(url: String?, kind: String?) {
        backend = url?.let { SavedBackend(it, kind, legacy = false) }
    }
    override suspend fun deviceToken(): String? = token
    override suspend fun setDeviceToken(value: String?) {
        token = value
    }
    override suspend fun channelKeys(): Map<String, String> = keys
    override suspend fun setChannelKey(desktop: String, key: String) {
        keys[desktop] = key
    }
    override suspend fun removeAllChannelKeys() = keys.clear()

    override val events: Flow<NativeEvent> get() = throw UnsupportedOperationException()
    override suspend fun takeTappedSession(): String? = throw UnsupportedOperationException()
    override suspend fun registerPush(): String? = throw UnsupportedOperationException()
    override suspend fun notificationsAllowed(): Boolean = throw UnsupportedOperationException()
    override suspend fun openSettings(notifications: Boolean) = throw UnsupportedOperationException()
    override suspend fun startActivity(key: String, title: String, project: String, state: String, since: Instant, kind: String?): Boolean =
        throw UnsupportedOperationException()
    override suspend fun updateActivity(key: String, state: String, since: Instant, kind: String?) = throw UnsupportedOperationException()
    override suspend fun endActivity(key: String, immediate: Boolean) = throw UnsupportedOperationException()
    override suspend fun liveActivities(): List<LiveActivityRef> = throw UnsupportedOperationException()
    override suspend fun deviceName(): String = throw UnsupportedOperationException()
    override suspend fun setKeepAwake(on: Boolean) = throw UnsupportedOperationException()
    override suspend fun setAppIcon(icon: String) = throw UnsupportedOperationException()
}

class SupabaseMigrationTest {
    @Test
    fun `a phone on a Supabase project is signed out, once`() = runBlocking {
        for (saved in listOf(
            SavedBackend("https://abcdefghijklmnop.supabase.co", "supabase", legacy = false),
            SavedBackend("https://abcdefghijklmnop.supabase.co", null, legacy = true),
        )) {
            val native = SignInNative(saved)
            assertTrue(forgetSupabase(native), saved.toString())
            assertNull(native.backend)
            assertNull(native.token)
            assertTrue(native.keys.isEmpty())
            assertNull(Backend.load(native))
            assertFalse(forgetSupabase(native), "nothing left to forget")
        }
    }

    @Test
    fun `any other server is kept, sign-in and keys too`() = runBlocking {
        for (url in listOf("https://my-mac.tail1234.ts.net", "https://pocketterm.example.com", "http://127.0.0.1:8080")) {
            val native = SignInNative(SavedBackend(url, null, legacy = false))
            assertFalse(forgetSupabase(native), url)
            assertEquals(url, native.backend?.url)
            assertEquals("token-1", native.token)
            assertEquals(mapOf("abcd1234" to "AAAA"), native.keys)
            assertEquals(Backend(url), Backend.load(native))
        }
        val none = SignInNative(null)
        assertFalse(forgetSupabase(none))
        assertEquals("token-1", none.token)
    }
}
