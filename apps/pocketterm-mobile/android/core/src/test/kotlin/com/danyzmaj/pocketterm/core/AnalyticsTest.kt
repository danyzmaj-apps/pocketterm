package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Usage statistics: off by default, only allowed names and values, nothing without a website id or once turned off. */
class AnalyticsTest : Confined() {
    private val device = AnalyticsDevice(
        platform = "android",
        hostname = "android.pocketterm.app.danyzmaj.com",
        userAgent = "Mozilla/5.0 (Linux; Android 16; Pixel 9) PocketTerm/1.0.0",
        screen = "1080x2400",
        language = "en-US",
        appVersion = "1.0.0",
    )
    private val sent = mutableListOf<JsonObject>()
    private var status = 200

    private fun analytics(prefs: PreferenceStore = MemoryPreferences(), websiteId: String = "site") = Analytics(
        AnalyticsTarget.of(websiteId),
        device,
        prefs,
        scope,
        post = { url, ua, body ->
            assertEquals("https://umami.danyzmaj.com/api/send", url)
            assertEquals(device.userAgent, ua)
            sent.add(jsonDecode(body) as JsonObject)
            status
        },
    )

    private val JsonObject.payload get() = this["payload"]!!.jsonObject
    private val JsonObject.data get() = payload["data"]!!.jsonObject

    @After
    fun tearDown() = closeConfined()

    @Test
    fun `off by default and records nothing`() = test {
        val a = analytics()
        a.screen("home")
        a.event("demo_opened")
        pump()
        assertEquals(false, a.enabled)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun `a build without a website id records nothing even when turned on`() = test {
        val prefs = MemoryPreferences()
        val a = analytics(prefs, websiteId = " ")
        a.setEnabled(true)
        a.screen("home")
        a.event("demo_opened")
        pump()
        assertTrue(sent.isEmpty())
        assertNull(prefs.getString(Analytics.INSTALL_ID_KEY))
    }

    @Test
    fun `only allowed events, keys and values leave the phone`() = test {
        val a = analytics()
        a.setEnabled(true)
        a.screen("session")
        a.event("pairing_failed", "method" to "scan", "code" to "code_used", "host" to "mac.tail1234.ts.net")
        a.event("pairing_failed", "method" to "camera", "code" to "Sign-in failed: http://10.0.0.1")
        a.event("prompt_sent", "mode" to "steer", "attachments" to true, "text" to "rm -rf ~")
        a.event("prompt_sent", "attachments" to "yes")
        a.event("typed_command", "text" to "ls")
        a.screen("/session/abc123")
        until { sent.size == 5 }
        pump()
        assertEquals(5, sent.size)

        val view = sent[0].payload
        assertEquals("event", sent[0]["type"]!!.jsonPrimitive.content)
        assertEquals("site", view["website"]!!.jsonPrimitive.content)
        assertEquals("android.pocketterm.app.danyzmaj.com", view["hostname"]!!.jsonPrimitive.content)
        assertEquals("/session", view["url"]!!.jsonPrimitive.content)
        assertNull(view["name"])

        val failed = sent[1].data
        assertEquals(setOf("platform", "app_version", "method", "code"), failed.keys)
        assertEquals("code_used", failed["code"]!!.jsonPrimitive.content)
        assertEquals("android", failed["platform"]!!.jsonPrimitive.content)
        assertEquals("/session", sent[1].payload["url"]!!.jsonPrimitive.content, "an event names the screen it happened on")
        assertEquals(setOf("platform", "app_version"), sent[2].data.keys, "unknown values go")
        assertEquals(true, sent[3].data["attachments"]!!.jsonPrimitive.boolean)
        assertEquals("steer", sent[3].data["mode"]!!.jsonPrimitive.content)
        assertEquals(setOf("platform", "app_version"), sent[4].data.keys, "a boolean property takes no string")
    }

    @Test
    fun `events carry one random install id until turned off, then a new one`() = test {
        val prefs = MemoryPreferences()
        val a = analytics(prefs)
        a.setEnabled(true)
        a.event("demo_opened")
        a.event("demo_opened")
        until { sent.size == 2 }
        val first = sent[0].payload["id"]!!.jsonPrimitive.content
        assertEquals(first, sent[1].payload["id"]!!.jsonPrimitive.content)
        assertNotNull(java.util.UUID.fromString(first))

        a.setEnabled(false)
        assertNull(prefs.getString(Analytics.INSTALL_ID_KEY))
        a.setEnabled(true)
        a.event("demo_opened")
        until { sent.size == 3 }
        assertNotEquals(first, sent[2].payload["id"]!!.jsonPrimitive.content)
    }

    @Test
    fun `turning it off drops what waits and sends nothing more`() = test {
        val a = analytics()
        a.setEnabled(true)
        status = 503
        a.event("demo_opened")
        until { sent.size == 1 }
        a.event("notifications_set", "on" to true)
        pump()
        assertEquals(1, sent.size, "after a failure it waits before trying again")
        assertEquals(2, a.queued)

        a.setEnabled(false)
        assertEquals(0, a.queued)
        status = 200
        a.flush()
        a.event("demo_opened")
        a.screen("home")
        pump()
        assertEquals(1, sent.size)
    }

    @Test
    fun `the queue keeps the newest events and goes out on flush`() = test {
        val a = analytics()
        a.setEnabled(true)
        status = 503
        repeat(Analytics.MAX_QUEUE + 20) { a.event("session_opened", "view" to "screen") }
        pump()
        assertEquals(Analytics.MAX_QUEUE, a.queued)
        status = 200
        a.flush()
        until { a.queued == 0 }
    }

    @Test
    fun `a request Umami refuses is dropped, not retried`() = test {
        val a = analytics()
        a.setEnabled(true)
        status = 400
        a.event("demo_opened")
        until { a.queued == 0 }
        assertEquals(1, sent.size)
    }

    @Test
    fun `transport names only the kind of address`() {
        assertEquals("tailnet", AnalyticsEvents.transport("studio.tail1234.ts.net"))
        assertEquals("local", AnalyticsEvents.transport("127.0.0.1"))
        assertEquals("local", AnalyticsEvents.transport("10.0.2.2"))
        assertEquals("other", AnalyticsEvents.transport("pocketterm.example.com"))
    }
}
