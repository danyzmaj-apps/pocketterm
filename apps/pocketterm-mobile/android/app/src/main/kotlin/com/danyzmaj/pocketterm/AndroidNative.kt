package com.danyzmaj.pocketterm

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Base64
import android.view.WindowManager
import com.danyzmaj.pocketterm.core.LiveActivityRef
import com.danyzmaj.pocketterm.core.Native
import com.danyzmaj.pocketterm.core.NativeEvent
import com.danyzmaj.pocketterm.core.SavedBackend
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.time.Instant
import kotlin.coroutines.resume

/**
 * The phone's platform side for the core ([Native]): what the Flutter app's MainActivity answered on
 * its `pocketterm/native` channel, now called directly. Storage stays where that app kept it
 * (PocketTermShared, SessionActivities), so an upgrade keeps the sign-in, keys and followed sessions.
 */
class AndroidNative(private val context: Context) : Native {
    override val events: Flow<NativeEvent> = NativeEvents.events

    override suspend fun takeTappedSession(): String? {
        val s = NativeEvents.tappedSession
        NativeEvents.tappedSession = null
        return s
    }

    /**
     * Permission first (a no-op after the first answer), then the FCM token. Null: not allowed, no
     * token, or a build without Firebase (android/app/google-services.json); the phone gets no pushes then.
     */
    override suspend fun registerPush(): String? {
        if (!BuildConfig.FIREBASE || FirebaseApp.getApps(context).isEmpty()) return null
        if (!askNotifications()) return null
        val token = suspendCancellableCoroutine<String?> { cont ->
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                cont.resume(if (task.isSuccessful) task.result else null)
            }
        } ?: return null
        PocketTermShared.setFcmToken(context, token)
        return token
    }

    /** POST_NOTIFICATIONS on Android 13+, asked for once; then whether notifications can show. */
    private suspend fun askNotifications(): Boolean {
        Notifications.ensureChannels(context)
        if (Build.VERSION.SDK_INT >= 33) ActivityHost.request(Manifest.permission.POST_NOTIFICATIONS)
        return Notifications.allowed(context)
    }

    override suspend fun notificationsAllowed(): Boolean = Notifications.allowed(context)

    /** PocketTerm's notification settings (Android 8+), else its app info (permissions). */
    override suspend fun openSettings(notifications: Boolean) {
        val intent = if (notifications) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
        }
        ActivityHost.start(intent)
    }

    override suspend fun channelKeys(): Map<String, String> = withContext(Dispatchers.IO) {
        PocketTermShared.channelKeys(context).mapValues { Base64.encodeToString(it.value, Base64.NO_WRAP) }
    }

    override suspend fun setChannelKey(desktop: String, key: String) {
        val bytes = runCatching { Base64.decode(key, Base64.DEFAULT) }.getOrNull()
        require(bytes?.size == 32) { "bad-args: desktop and a 32-byte base64 key" }
        withContext(Dispatchers.IO) { PocketTermShared.setChannelKey(context, desktop, bytes!!) }
    }

    override suspend fun removeAllChannelKeys() = withContext(Dispatchers.IO) {
        PocketTermShared.removeAllChannelKeys(context)
    }

    override suspend fun startActivity(
        key: String,
        title: String,
        project: String,
        state: String,
        since: Instant,
        kind: String?,
    ): Boolean {
        if (!askNotifications()) return false
        return SessionActivities.start(context, activityArgs(key, state, since, kind) + mapOf("title" to title, "project" to project))
    }

    override suspend fun updateActivity(key: String, state: String, since: Instant, kind: String?) {
        SessionActivities.update(context, activityArgs(key, state, since, kind))
    }

    private fun activityArgs(key: String, state: String, since: Instant, kind: String?) =
        mapOf("key" to key, "state" to state, "since" to since.toEpochMilli(), "kind" to kind)

    override suspend fun endActivity(key: String, immediate: Boolean) {
        SessionActivities.end(context, key, immediate)
    }

    override suspend fun liveActivities(): List<LiveActivityRef> =
        SessionActivities.running(context).map { LiveActivityRef(it.getValue("key"), it["token"]) }

    override suspend fun getBackend(): SavedBackend? {
        val url = PocketTermShared.backendUrl(context) ?: return null
        return SavedBackend(url, PocketTermShared.backendKind(context), PocketTermShared.legacyBackendKey(context) != null)
    }

    override suspend fun setBackend(url: String?, kind: String?) {
        PocketTermShared.setBackend(context, url, kind)
    }

    override suspend fun deviceToken(): String? = withContext(Dispatchers.IO) { PocketTermShared.deviceToken(context) }

    override suspend fun setDeviceToken(value: String?) = withContext(Dispatchers.IO) {
        PocketTermShared.setDeviceToken(context, value)
    }

    override suspend fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.ifBlank { null } ?: Build.MODEL

    override suspend fun setKeepAwake(on: Boolean) {
        val window = ActivityHost.activity?.window ?: return
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override suspend fun setAppIcon(icon: String) {
        AppIcons.request(icon)
        // The icon goes with the theme, so its splash does too; the system keeps it for later starts.
        if (Build.VERSION.SDK_INT >= 33) {
            val activity = ActivityHost.activity ?: return
            AppIcons.splashTheme(icon)?.let { activity.splashScreen.setSplashScreenTheme(it) }
        }
    }
}
