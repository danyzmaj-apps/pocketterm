package com.danyzmaj.pocketterm

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import com.danyzmaj.pocketterm.core.FlutterPreferences
import com.danyzmaj.pocketterm.core.PreferenceStore
import com.danyzmaj.pocketterm.core.debugPrint
import org.json.JSONArray

/**
 * The phone's preferences ([PreferenceStore]) in a SharedPreferences file of their own, under the
 * keys the Flutter app used (without its `flutter.` prefix): theme, sort, folded projects, tips seen,
 * voice language, drafts and the rest. [open] migrates the Flutter app's file once.
 *
 * Lists keep their order, so they're kept as JSON behind [LIST_MARK] rather than as a string set.
 */
class AndroidPreferences(private val prefs: SharedPreferences) : PreferenceStore {
    // SharedPreferences throws ClassCastException for a key holding another type: that reads as absent.
    private inline fun <T> typed(read: () -> T): T? = try {
        read()
    } catch (_: ClassCastException) {
        null
    }

    private fun raw(key: String): String? = if (prefs.contains(key)) typed { prefs.getString(key, null) } else null

    override fun getString(key: String): String? = raw(key)?.takeUnless { it.startsWith(LIST_MARK) }

    override fun setString(key: String, value: String) = prefs.edit { putString(key, value) }

    override fun getBool(key: String): Boolean? = if (prefs.contains(key)) typed { prefs.getBoolean(key, false) } else null

    override fun setBool(key: String, value: Boolean) = prefs.edit { putBoolean(key, value) }

    override fun getInt(key: String): Long? =
        if (prefs.contains(key)) typed { prefs.getLong(key, 0) } ?: typed { prefs.getInt(key, 0).toLong() } else null

    override fun setInt(key: String, value: Long) = prefs.edit { putLong(key, value) }

    override fun getStringList(key: String): List<String>? {
        val s = raw(key) ?: return null
        if (!s.startsWith(LIST_MARK)) return null
        return runCatching {
            val a = JSONArray(s.substring(LIST_MARK.length))
            List(a.length()) { a.getString(it) }
        }.getOrNull()
    }

    override fun setStringList(key: String, value: List<String>) =
        prefs.edit { putString(key, LIST_MARK + JSONArray(value).toString()) }

    override fun remove(key: String) = prefs.edit { remove(key) }

    /** Every key kept: drafts and per-server choices are found by prefix. */
    fun keys(): Set<String> = prefs.all.keys.toSet()

    companion object {
        /** The app's own preferences file. */
        const val FILE = "pocketterm_prefs"

        /** Before a list's JSON: no string PocketTerm keeps starts with a NUL. */
        private const val LIST_MARK = "\u0000list:"

        /**
         * The app's preferences, with the Flutter app's (an upgrade from 0.1.x) copied in on the first
         * launch ([FlutterPreferences.migrate]); the Flutter file stays as it was, never read again.
         */
        fun open(context: Context): AndroidPreferences {
            val store = AndroidPreferences(context.getSharedPreferences(FILE, Context.MODE_PRIVATE))
            val flutter = context.getSharedPreferences(FlutterPreferences.FILE, Context.MODE_PRIVATE)
            val copied = FlutterPreferences.migrate(flutter.all, store)
            if (copied > 0) debugPrint("PocketTerm: $copied preferences kept from the Flutter app")
            return store
        }
    }
}
