package com.danyzmaj.pocketterm

import android.util.Base64
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/**
 * Pushes from the user's own server, through the relay
 * (apps/pocketterm-relay) and FCM. They are data-only:
 * - kind terminal {enc, d}: the computer d sealed {title, body, session?, state?}
 *   with its channel key, AAD "pocketterm/v1|push|<d>" (PocketTermShared.open).
 *   The server, the relay and Google only ever see ciphertext. Without that
 *   computer's key, or if it doesn't open, a generic "PocketTerm" alert shows,
 *   as on the iPhone.
 * - kind activity {session, state, since, akind?}: a followed session's state,
 *   unencrypted like an iPhone's Live Activity push (no title, no text).
 */
class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        PocketTermShared.setFcmToken(this, token)
        // The server needs the new one: for the phone, and for each followed session.
        NativeEvents.emit("pushToken")
        for (key in SessionActivities.keys(this)) {
            NativeEvents.emit("activityToken", mapOf("key" to key, "token" to token))
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        when (data["kind"]) {
            "activity" -> SessionActivities.pushed(this, JSONObject(data.toMap()))
            "terminal" -> {
                val m = opened(data["enc"], data["d"])
                if (m == null) {
                    Notifications.terminal(this, null, "PocketTerm", "Terminal")
                } else {
                    Notifications.terminal(
                        this,
                        m.optString("session").ifEmpty { null },
                        m.optString("title"),
                        m.optString("body"),
                    )
                }
            }
        }
    }

    /** The sealed alert [enc] from computer [desktop], opened with its key; null if anything is off. */
    private fun opened(enc: String?, desktop: String?): JSONObject? = runCatching {
        if (enc == null || desktop == null) return null
        val key = PocketTermShared.channelKey(this, desktop) ?: return null
        val plain = PocketTermShared.open(Base64.decode(enc, Base64.DEFAULT), key, "pocketterm/v1|push|$desktop")
            ?: return null
        JSONObject(String(plain, Charsets.UTF_8))
    }.getOrNull()
}
