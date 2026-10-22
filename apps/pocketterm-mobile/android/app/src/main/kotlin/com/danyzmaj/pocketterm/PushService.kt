package com.danyzmaj.pocketterm

import android.util.Base64
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/**
 * Pushes from the user's own server, through the relay
 * (apps/pocketterm-relay) and FCM. They are data-only:
 * - kind terminal {enc, d}: the computer d sealed {title, body, session?, state?, ts, id}
 *   with its channel key, AAD "pocketterm/v1|push|<d>" (PocketTermShared.open).
 *   The server, the relay and Google only ever see ciphertext. Without that
 *   computer's key, if it doesn't open, or if it is old or came before
 *   (PocketTermShared.isFreshPush), a generic "PocketTerm" alert shows, as on
 *   the iPhone.
 * - kind activity {enc, d}: a followed session's {session, state, since, kind?},
 *   sealed the same way with AAD "pocketterm/v1|activity|<d>".
 * - kind activity {session, state: ended}: the server ends a followed session
 *   (it ended, or its computer went quiet or left); it carries nothing else.
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
            "activity" -> activity(data)
            "terminal" -> {
                val m = opened(data["enc"], data["d"], "push")?.takeIf {
                    PocketTermShared.isFreshPush(this, if (it.has("ts")) it.optLong("ts") else null, it.optString("id"))
                }
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

    private fun activity(data: Map<String, String>) {
        if (data["enc"] == null) {
            // Only an end comes unsealed: nobody on the way can make up a state.
            val session = data["session"] ?: return
            if (data["state"] == "ended") SessionActivities.pushed(this, session, "ended", null, null)
            return
        }
        val m = opened(data["enc"], data["d"], "activity") ?: return
        SessionActivities.pushed(
            this,
            m.optString("session").ifEmpty { return },
            m.optString("state"),
            if (m.has("since")) m.optLong("since") else null,
            m.optString("kind").ifEmpty { null },
        )
    }

    /** What computer [desktop] sealed for [what] (push, activity), opened with its key; null if anything is off. */
    private fun opened(enc: String?, desktop: String?, what: String): JSONObject? = runCatching {
        if (enc == null || desktop == null) return null
        val key = PocketTermShared.channelKey(this, desktop) ?: return null
        val plain = PocketTermShared.open(Base64.decode(enc, Base64.DEFAULT), key, "pocketterm/v1|$what|$desktop")
            ?: return null
        JSONObject(String(plain, Charsets.UTF_8))
    }.getOrNull()
}
