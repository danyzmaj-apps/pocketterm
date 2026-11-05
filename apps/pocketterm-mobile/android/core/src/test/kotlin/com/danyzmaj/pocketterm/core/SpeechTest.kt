package com.danyzmaj.pocketterm.core

import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals

class SpeechTest {
    @Test
    fun `Auto tries the phone languages it knows in the phone's order, then English`() {
        val en = SpeechLanguage.english
        val hr = SpeechLanguage.croatian
        assertEquals(listOf(hr, en), SpeechLanguage.byLocales(listOf(Locale("hr", "HR"), Locale("en", "US"))))
        assertEquals(listOf(en, hr), SpeechLanguage.byLocales(listOf(Locale("en", "GB"), Locale("hr"))))
        assertEquals(listOf(hr, en), SpeechLanguage.byLocales(listOf(Locale("de"), Locale("hr"))))
        assertEquals(listOf(en), SpeechLanguage.byLocales(listOf(Locale("de"), Locale("sl"))))
        assertEquals(listOf(en), SpeechLanguage.byLocales(emptyList()))
    }

    @Test
    fun `native events and checks read leniently, anything unknown ending or unavailable`() {
        assertEquals(SpeechEvent.Heard("hi"), SpeechEvent.fromMap(mapOf("type" to "heard", "text" to "hi")))
        assertEquals(SpeechEvent.Level(1.0), SpeechEvent.fromMap(mapOf("type" to "level", "level" to 3)))
        assertEquals(
            SpeechEvent.Ended(SpeechEnd.error, "no", SpeechStatus.noLanguage),
            SpeechEvent.fromMap(mapOf("type" to "ended", "why" to "boom", "message" to "no", "status" to "noLanguage")),
        )
        val check = SpeechCheck.fromMap(mapOf("status" to "noLanguage"))
        assertEquals(true, check.unsupported)
        assertEquals(SpeechCheck(SpeechStatus.unavailable), SpeechCheck.fromMap(emptyMap()))
    }
}
