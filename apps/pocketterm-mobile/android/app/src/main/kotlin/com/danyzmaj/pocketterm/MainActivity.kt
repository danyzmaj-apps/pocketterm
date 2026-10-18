package com.danyzmaj.pocketterm

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.view.WindowManager
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Events for Dart (packages/pocketterm_core/lib/native.dart's Native.listen) from wherever they
 * happen: the activity, the push service, a followed session's notification.
 * Dropped while no engine runs; a tapped push's session waits in [tappedSession]
 * for Dart to take.
 */
object NativeEvents {
    @Volatile
    var channel: MethodChannel? = null

    /** The session a tapped terminal push is about, until Dart takes it. */
    @Volatile
    var tappedSession: String? = null

    private val main = Handler(Looper.getMainLooper())

    fun emit(method: String, args: Any? = null) {
        main.post { channel?.invokeMethod(method, args) }
    }
}

/**
 * Android's half of packages/pocketterm_core/lib/native.dart (the iPhone's is
 * ios/Runner/AppDelegate.swift; same methods, arguments and results).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** Waiting for the notification permission's answer. */
    private val permissionWaiters = mutableListOf<(Boolean) -> Unit>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity has already handled its intent.
        if (savedInstanceState == null) tapped(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        tapped(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pocketterm/native")
        ch.setMethodCallHandler(::handle)
        channel = ch
        NativeEvents.channel = ch
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (NativeEvents.channel === channel) NativeEvents.channel = null
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** A terminal push was tapped (pocketterm:// links go to app_links). */
    private fun tapped(intent: Intent?) {
        intent ?: return
        if (intent.hasExtra(Notifications.EXTRA_SESSION)) {
            val session = intent.getStringExtra(Notifications.EXTRA_SESSION)
            NativeEvents.tappedSession = session
            NativeEvents.emit("openTerminal", session?.let { mapOf("session" to it) })
            intent.removeExtra(Notifications.EXTRA_SESSION)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        when (call.method) {
            "setKeepAwake" -> {
                if (args["on"] == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "deviceName" -> result.success(
                Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)?.ifBlank { null }
                    ?: Build.MODEL,
            )
            "getBackend" -> result.success(PocketTermShared.backend(this)?.let { mapOf("url" to it.url, "key" to it.key) })
            "setBackend" -> {
                val url = args["url"] as? String
                val key = args["key"] as? String
                PocketTermShared.setBackend(this, if (url != null && key != null) PocketTermShared.Backend(url, key) else null)
                result.success(null)
            }
            "takeTappedSession" -> {
                result.success(NativeEvents.tappedSession)
                NativeEvents.tappedSession = null
            }
            "registerPush" -> registerPush(result)
            "startActivity" -> askNotifications { result.success(SessionActivities.start(this, args)) }
            "updateActivity" -> result.success(SessionActivities.update(this, args))
            "endActivity" -> {
                (args["key"] as? String)?.let { SessionActivities.end(this, it, immediate = args["immediate"] == true) }
                result.success(null)
            }
            "liveActivities" -> result.success(SessionActivities.running(this))
            else -> result.notImplemented()
        }
    }

    /**
     * Permission first (a no-op after the first answer), then the FCM token.
     * Null: not allowed, no token, or a build without Firebase
     * (android/app/google-services.json); the phone gets no pushes then.
     */
    private fun registerPush(result: MethodChannel.Result) {
        if (FirebaseApp.getApps(this).isEmpty()) return result.success(null)
        askNotifications { granted ->
            if (!granted) return@askNotifications result.success(null)
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                val token = if (task.isSuccessful) task.result else null
                if (token == null) return@addOnCompleteListener result.success(null)
                PocketTermShared.setFcmToken(this, token)
                val key = Base64.encodeToString(PocketTermShared.makePushKey(this), Base64.NO_WRAP)
                result.success(mapOf("token" to token, "key" to key))
            }
        }
    }

    /** Asks for POST_NOTIFICATIONS on Android 13+; [then] gets whether notifications can show. */
    private fun askNotifications(then: (Boolean) -> Unit) {
        Notifications.ensureChannels(this)
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            return then(Notifications.allowed(this))
        }
        permissionWaiters.add(then)
        if (permissionWaiters.size == 1) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATIONS_REQUEST) return
        val allowed = Notifications.allowed(this)
        val waiters = permissionWaiters.toList()
        permissionWaiters.clear()
        for (w in waiters) w(allowed)
    }

    private companion object {
        const val NOTIFICATIONS_REQUEST = 0x0D2E
    }
}
