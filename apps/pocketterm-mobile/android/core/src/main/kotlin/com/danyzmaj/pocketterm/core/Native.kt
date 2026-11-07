package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.flow.Flow
import java.time.Instant

/**
 * What the server (POST /v1/push/register) calls this phone's push service: FCM on Android.
 * Tests may stand in another.
 */
@Volatile
var pushPlatform: String = "android"

/** One event from the phone's platform side; see [Native.events]. */
data class NativeEvent(val event: String, val args: Map<String, Any?>)

/** A running followed session (Live Activity / ongoing notification): its session key and push token, if any. */
data class LiveActivityRef(val key: String, val token: String?)

/** The server as kept where the platform side (push service, widgets) reads it too. */
data class SavedBackend(
    val url: String,
    /** `supabase` for a Supabase project an app from before saved, or null for a PocketTerm server. */
    val kind: String?,
    /** An app from before saved a Supabase project there (it came with a key). */
    val legacy: Boolean,
) {
    /** A Supabase project: PocketTerm no longer runs a server there, so the phone signs in again. */
    val isSupabase: Boolean get() = legacy || kind == "supabase"
}

/** iOS shows only so many Live Activities at once; Android never throws it, kept for parity. */
class TooManyActivities : Exception("Too many Live Activities")

/**
 * The phone's platform side, which the Android app implements (it was the Flutter method channel
 * `pocketterm/native`: MainActivity.kt, PocketTermShared.kt, SessionActivities.kt). Item names in
 * storage stay as the Flutter app's native side kept them, so an upgrade keeps the sign-in and keys.
 */
interface Native {
    /**
     * Events: openTerminal ({session}: a terminal push was tapped; see [takeTappedSession]),
     * activityToken ({key, token}: a followed session's push token, new or changed),
     * activityEnded ({key, token?}: it ended or was swiped away) and pushToken (FCM changed this
     * phone's token; register again).
     */
    val events: Flow<NativeEvent>

    /** The coding session (its key) whose terminal push was tapped, once. */
    suspend fun takeTappedSession(): String?

    /** Asks for notification permission and this phone's FCM token. Null: not allowed, or no token (a build without Firebase). */
    suspend fun registerPush(): String?

    /** Whether the system lets PocketTerm's notifications show now. */
    suspend fun notificationsAllowed(): Boolean

    /** Opens PocketTerm's page in the phone's Settings: its [notifications] settings, else the app's. */
    suspend fun openSettings(notifications: Boolean = false)

    /** The computers' channel keys (standard base64), by computer id, Keystore-backed. */
    suspend fun channelKeys(): Map<String, String>

    /** [key]: standard base64. */
    suspend fun setChannelKey(desktop: String, key: String)

    /**
     * Every computer's key goes, also ones never loaded (sign-out). The Keystore key that wraps
     * them goes too, and with it the sign-in ([deviceToken]) it also wraps.
     */
    suspend fun removeAllChannelKeys()

    /** Starts a followed session's ongoing notification, or updates it; false when notifications are off. */
    suspend fun startActivity(key: String, title: String, project: String, state: String, since: Instant, kind: String? = null): Boolean

    suspend fun updateActivity(key: String, state: String, since: Instant, kind: String? = null)

    /** [immediate]: gone at once (the person ended it), else Ended shows for a few minutes. */
    suspend fun endActivity(key: String, immediate: Boolean = false)

    /** The running ones: their session keys and push tokens (the phone's FCM token). */
    suspend fun liveActivities(): List<LiveActivityRef>

    /** The server kept where the platform side reads it too; null: none. */
    suspend fun getBackend(): SavedBackend?

    /** Null [url] forgets it. */
    suspend fun setBackend(url: String? = null, kind: String? = null)

    /** This phone's sign-in on its server (one opaque string, Keystore-wrapped). Null: none. */
    suspend fun deviceToken(): String?

    /** Null forgets it. */
    suspend fun setDeviceToken(value: String?)

    /** This phone's name: the label of its push registration. */
    suspend fun deviceName(): String

    /** Keeps the screen from dimming and locking while [on]. */
    suspend fun setKeepAwake(on: Boolean)

    /** Switches the launcher icon to [icon] (appIconFor's names). */
    suspend fun setAppIcon(icon: String)
}

/** The phone's sign-in kept by [Native.deviceToken]. */
class NativeDeviceTokens(private val native: Native) : DeviceTokens {
    override suspend fun read(): String? = native.deviceToken()

    override suspend fun write(value: String?) = native.setDeviceToken(value)
}
