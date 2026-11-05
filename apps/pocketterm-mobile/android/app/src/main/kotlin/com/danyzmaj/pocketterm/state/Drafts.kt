package com.danyzmaj.pocketterm.state

import com.danyzmaj.pocketterm.AndroidPreferences
import com.danyzmaj.pocketterm.core.jsonDecodeOrNull
import com.danyzmaj.pocketterm.core.jsonEncode
import com.danyzmaj.pocketterm.core.jsonOf
import com.danyzmaj.pocketterm.core.long
import com.danyzmaj.pocketterm.core.obj
import com.danyzmaj.pocketterm.core.str

/**
 * Unsent prompt text, per session, kept across leaving the page and app restarts until it's sent or
 * deleted. Text only: attachments are too large to keep. Stored as `pocketterm_draft_<routedKey>`
 * (so sessions of two computers don't share one) holding `{"t": text, "at": ms since epoch}`, as the
 * Flutter app did.
 */
class Drafts(private val prefs: AndroidPreferences, private val clock: () -> Long = System::currentTimeMillis) {
    /** [routedKey]'s draft, or '' when there's none. Drops stale drafts on the way. */
    fun load(routedKey: String): String {
        val old = clock() - KEEP_MS
        var text = ""
        for (k in prefs.keys()) {
            if (!k.startsWith(PREFIX)) continue
            val d = jsonDecodeOrNull(prefs.getString(k) ?: "").obj
            val t = d?.get("t").str
            val at = d?.get("at").long
            if (t == null || at == null || at < old) {
                prefs.remove(k)
            } else if (k == key(routedKey)) {
                text = t
            }
        }
        return text
    }

    /** Keeps [text] as [routedKey]'s draft; blank removes it. */
    fun save(routedKey: String, text: String) {
        if (text.isBlank()) {
            prefs.remove(key(routedKey))
        } else {
            prefs.setString(key(routedKey), jsonEncode(jsonOf("t" to text, "at" to clock())))
        }
    }

    companion object {
        private const val PREFIX = "pocketterm_draft_"

        /** Drafts untouched this long are dropped. */
        private const val KEEP_MS = 30L * 24 * 3600 * 1000

        fun key(routedKey: String) = "$PREFIX$routedKey"
    }
}
