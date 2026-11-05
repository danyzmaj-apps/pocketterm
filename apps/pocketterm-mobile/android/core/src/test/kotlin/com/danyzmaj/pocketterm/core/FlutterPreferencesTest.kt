package com.danyzmaj.pocketterm.core

import java.io.ByteArrayOutputStream
import java.io.ObjectOutputStream
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class FlutterPreferencesTest {
    private val list = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

    // As shared_preferences_android's older ListEncoder wrote it: Android's Base64 default (MIME lines).
    private fun javaList(items: List<String>): String {
        val bytes = ByteArrayOutputStream().also { ObjectOutputStream(it).use { s -> s.writeObject(ArrayList(items)) } }.toByteArray()
        return list + Base64.getMimeEncoder().encodeToString(bytes) + "\n"
    }

    @Test
    fun `an upgrade from the Flutter app keeps every preference under its own key, once`() {
        val flutter = mapOf(
            "flutter.theme" to "dawn",
            "flutter.voiceLanguage" to "hr",
            "flutter.projectSort" to "recent",
            "flutter.foldedProjects" to "$list![\"/Users/me/a\",\"/Users/me/b\"]",
            "flutter.coachSeen" to javaList(listOf("follow", "keys")),
            "flutter.push_abc" to true,
            "flutter.count" to 3L,
            "flutter.ratio" to "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu1.5",
            "notFlutters" to "x",
        )
        val prefs = MemoryPreferences()
        assertEquals(7, FlutterPreferences.migrate(flutter, prefs))
        assertEquals("dawn", prefs.getString("theme"))
        assertEquals("hr", prefs.getString("voiceLanguage"))
        assertEquals("recent", prefs.getString("projectSort"))
        assertEquals(listOf("/Users/me/a", "/Users/me/b"), prefs.getStringList("foldedProjects"))
        assertEquals(listOf("follow", "keys"), prefs.getStringList("coachSeen"))
        assertEquals(true, prefs.getBool("push_abc"))
        assertEquals(3L, prefs.getInt("count"))
        assertNull(prefs.getString("ratio"), "no doubles in a PreferenceStore")
        assertNull(prefs.getString("notFlutters"))

        // Once only: a value changed natively since isn't overwritten.
        prefs.setString("theme", "gruvbox")
        assertEquals(0, FlutterPreferences.migrate(flutter, prefs))
        assertEquals("gruvbox", prefs.getString("theme"))
    }

    @Test
    fun `a corrupt list is left behind rather than read wrong`() {
        assertNull(FlutterPreferences.decode("$list!not json"))
        assertNull(FlutterPreferences.decode("$list!" + "[1,2]"))
        assertNull(FlutterPreferences.decode(list + "AAAA"))
        assertEquals(listOf("a"), FlutterPreferences.decode(setOf("a")))
    }
}
