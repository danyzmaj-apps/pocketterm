package com.danyzmaj.pocketterm

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.danyzmaj.pocketterm.core.FlutterPreferences
import com.danyzmaj.pocketterm.state.Drafts
import com.danyzmaj.pocketterm.state.MobileSession
import com.danyzmaj.pocketterm.state.Tips
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * An upgrade from the Flutter app (0.1.x): what its shared_preferences kept in FlutterSharedPreferences
 * (`flutter.` keys, lists in the plugin's encoding) is what the native app reads, once.
 */
// A plain Application: these tests are about storage, not the app's start.
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = android.app.Application::class)
class AndroidPreferencesTest {
    private val context: Context = ApplicationProvider.getApplicationContext()

    private fun flutterFile() = context.getSharedPreferences(FlutterPreferences.FILE, Context.MODE_PRIVATE)

    @Test
    fun `an upgrade keeps the Flutter app's choices under the same keys`() {
        flutterFile().edit()
            .putString("flutter.theme", "tokyoNight")
            .putString("flutter.voiceLanguage", "croatian")
            .putString("flutter.pocketterm_terminal_sort", "activity")
            // shared_preferences_android 2.3+: a list is JSON after its marker.
            .putString("flutter.pocketterm_terminal_folded", "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu![\"/Users/me/b\",\"/Users/me/a\"]")
            .putString("flutter.pocketterm_tips_seen", "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu![]")
            .putBoolean("flutter.pocketterm_push_on_u1", true)
            .putLong("flutter.someCount", 3)
            // Not Dart's: stays behind.
            .putString("other", "x")
            .commit()

        val prefs = AndroidPreferences.open(context)

        assertEquals("tokyoNight", prefs.getString("theme"))
        assertEquals("croatian", prefs.getString("voiceLanguage"))
        assertEquals("activity", prefs.getString(MobileSession.SORT_KEY))
        // Order kept: the folds are a list, not a set.
        assertEquals(listOf("/Users/me/b", "/Users/me/a"), prefs.getStringList(MobileSession.FOLDED_KEY))
        // An empty list is "answered, no tour": it must not read as absent (which asks again).
        assertEquals(emptyList(), prefs.getStringList(Tips.SEEN_KEY))
        assertEquals(true, Tips(prefs).answered)
        assertEquals(true, prefs.getBool("${MobileSession.PUSH_CHOICE_KEY}_u1"))
        assertEquals(3L, prefs.getInt("someCount"))
        assertNull(prefs.getString("other"))
        // A list isn't a string, and the other way round.
        assertNull(prefs.getString(MobileSession.FOLDED_KEY))
        assertNull(prefs.getStringList("theme"))
    }

    @Test
    fun `the migration runs once, so a later change here isn't overwritten by the old file`() {
        flutterFile().edit().putString("flutter.theme", "gruvbox").commit()
        AndroidPreferences.open(context).setString("theme", "dawn")

        assertEquals("dawn", AndroidPreferences.open(context).getString("theme"))
    }

    @Test
    fun `drafts older than 30 days go, fresh ones stay per session`() {
        val prefs = AndroidPreferences.open(context)
        var now = 1_000_000_000_000L
        val drafts = Drafts(prefs) { now }
        drafts.save("abcd1234/kitty-1/1", "half a prompt")
        drafts.save("abcd1234/kitty-1/2", "another")
        now += 29L * 24 * 3600 * 1000
        drafts.save("abcd1234/kitty-1/2", "another, newer")
        now += 2L * 24 * 3600 * 1000

        assertEquals("", drafts.load("abcd1234/kitty-1/1"))
        assertEquals("another, newer", drafts.load("abcd1234/kitty-1/2"))
        assertNull(prefs.getString(Drafts.key("abcd1234/kitty-1/1")))
        drafts.save("abcd1234/kitty-1/2", "  ")
        assertEquals("", drafts.load("abcd1234/kitty-1/2"))
    }
}
