package com.danyzmaj.pocketterm

import android.util.Base64
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject

/**
 * Pushes from the user's own server, through the relay
 * (apps/pocketterm-relay) and FCM. They are data-only and name no computer
 * and no session: a computer is named by its push tag t, a session by its
 * tag ref (PocketTermShared.pushTag, sessionTag), which only its key makes.
 * - kind terminal {enc, t}: the computer whose tag is t sealed {title, body, session?, state?, ts, id}
 *   with its channel key, AAD "pocketterm/v1|push|<computer id>" (PocketTermShared.open).
 *   The server, the relay and Google only ever see ciphertext. Without that
 *   computer's key, if it doesn't open, or if it is old or came before
 *   (PocketTermShared.isFreshPush), a generic "PocketTerm" alert shows, as on
 *   the iPhone.
 * - kind activity {enc, t}: a followed session's {session, state, since, kind?, ts, id},
 *   sealed the same way with AAD "pocketterm/v1|activity|<computer id>". It is dropped unless fresh
 *   (isFreshPush), its session is one of that computer's ("<id>/…") and its since is no
 *   older than the last one applied for that session: a replay can't roll it back.
 * - kind activity {ref, state: ended}: the server ends the followed session whose tag is ref
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
                val m = opened(data["enc"], data["t"], "push")?.second?.takeIf {
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
            if (data["state"] != "ended") return
            val ref = data["ref"] ?: return
            val keys = PocketTermShared.channelKeys(this)
            val session = SessionActivities.keys(this).firstOrNull { key ->
                val k = keys[key.substringBefore('/')]
                k != null && PocketTermShared.sessionTag(k, key) == ref
            } ?: return
            SessionActivities.pushed(this, session, "ended", null, null)
            return
        }
        val (desktop, m) = opened(data["enc"], data["t"], "activity") ?: return
        if (!PocketTermShared.isFreshPush(this, if (m.has("ts")) m.optLong("ts") else null, m.optString("id"))) return
        val session = m.optString("session")
        if (!session.startsWith("$desktop/") || session.length == desktop.length + 1) return
        val since = if (m.has("since")) m.optLong("since") else null
        if (!newest(session, since)) return
        SessionActivities.pushed(this, session, m.optString("state"), since, m.optString("kind").ifEmpty { null })
    }

    /** Whether [since] is no older than the last update applied for [session]; records it if so. */
    @Synchronized
    private fun newest(session: String, since: Long?): Boolean {
        val prefs = getSharedPreferences("pocketterm.activitySince", MODE_PRIVATE)
        val last = prefs.getLong(session, Long.MIN_VALUE)
        if (since == null) return last == Long.MIN_VALUE
        if (since < last) return false
        prefs.edit().putLong(session, since).apply()
        return true
    }

    /**
     * What the computer whose push tag is [tag] sealed for [what] (push, activity), opened with its key, and that
     * computer's id; null if anything is off.
     */
    private fun opened(enc: String?, tag: String?, what: String): Pair<String, JSONObject>? = runCatching {
        if (enc == null || tag == null) return null
        val (desktop, key) = PocketTermShared.computer(tag, PocketTermShared.channelKeys(this)) ?: return null
        val plain = PocketTermShared.open(Base64.decode(enc, Base64.DEFAULT), key, "pocketterm/v1|$what|$desktop")
            ?: return null
        desktop to JSONObject(String(plain, Charsets.UTF_8))
    }.getOrNull()
}
