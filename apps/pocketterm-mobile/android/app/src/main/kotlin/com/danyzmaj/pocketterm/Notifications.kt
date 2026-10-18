package com.danyzmaj.pocketterm

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** The notification channels and what posts to them. */
object Notifications {
    const val SESSIONS = "sessions"
    const val FOLLOWED = "followed"

    /** Intent extra for MainActivity: the session a tap opens. */
    const val EXTRA_SESSION = "com.danyzmaj.pocketterm.session"

    fun ensureChannels(c: Context) {
        val m = c.getSystemService(NotificationManager::class.java)
        m.createNotificationChannels(
            listOf(
                NotificationChannel(SESSIONS, "Coding sessions", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "A coding session on your computer finished or needs you."
                },
                NotificationChannel(FOLLOWED, "Followed sessions", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "What a followed coding session is doing, kept up to date."
                    setShowBadge(false)
                },
            ),
        )
    }

    /** Android 13+ asks; before that it's on unless turned off in Settings. */
    fun allowed(c: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(c, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED) &&
            NotificationManagerCompat.from(c).areNotificationsEnabled()

    fun post(c: Context, tag: String, n: android.app.Notification) {
        if (!allowed(c)) return
        try {
            NotificationManagerCompat.from(c).notify(tag, 1, n)
        } catch (e: SecurityException) {
            // Permission withdrawn between the check and the post.
        }
    }

    fun cancel(c: Context, tag: String) = NotificationManagerCompat.from(c).cancel(tag, 1)

    /** Opens the app; [extras] say on what. */
    fun openApp(c: Context, request: String, extras: Intent.() -> Unit = {}): PendingIntent =
        PendingIntent.getActivity(
            c,
            request.hashCode(),
            Intent(c, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                extras()
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /** A terminal push: a tap opens that coding session. */
    fun terminal(c: Context, session: String?, title: String, body: String) {
        ensureChannels(c)
        val tag = "terminal:${session ?: System.currentTimeMillis()}"
        val n = NotificationCompat.Builder(c, SESSIONS)
            .setSmallIcon(R.drawable.ic_stat_pocketterm)
            .setColor(c.getColor(R.color.pocketterm_accent))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(openApp(c, tag) { if (session != null) putExtra(EXTRA_SESSION, session) })
            .build()
        post(c, tag, n)
    }
}
