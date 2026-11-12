package com.danyzmaj.pocketterm

import io.sentry.SentryEvent
import io.sentry.protocol.Device
import io.sentry.protocol.Message
import io.sentry.protocol.Request
import io.sentry.protocol.SentryException
import io.sentry.protocol.SentryStackFrame
import io.sentry.protocol.SentryStackTrace
import io.sentry.protocol.User
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/** A report names no computer, address or person, and carries no long stretch of text. */
class ErrorScrubberTest {
    @Test
    fun `addresses of the person's computers are replaced`() {
        assertEquals(
            "failed to connect to http://<redacted> and wss://<redacted>",
            ErrorScrubber.scrub("failed to connect to http://192.168.1.20:8080/api?x=1 and wss://mac.tail1234.ts.net/ws"),
        )
        assertEquals("<ip>:7681 refused, <ip> unreachable", ErrorScrubber.scrub("10.0.0.5:7681 refused, 100.64.1.2 unreachable"))
        assertEquals("<host> and <host> and <host>", ErrorScrubber.scrub("studio.tail1234.ts.net and Danijels-Mac.local and nas.home.lan"))
        assertEquals("route to [<ip>]:80 and <ip>", ErrorScrubber.scrub("route to [fe80::1c2:3ff:fe4a:5b6c]:80 and 2001:db8:0:0:0:0:2:1"))
        assertEquals("mail <email> now", ErrorScrubber.scrub("mail someone@example.com now"))
    }

    @Test
    fun `ordinary error text stays`() {
        val text = "IllegalStateException at 12:30:45: Foo::bar expected 3 items, got 1.2"
        assertEquals(text, ErrorScrubber.scrub(text))
    }

    @Test
    fun `long text is cut`() {
        assertEquals(ErrorScrubber.MAX_LENGTH, ErrorScrubber.scrub("x".repeat(5000)).length)
    }

    @Test
    fun `an event keeps its exception type and frames and loses what could name someone`() {
        val frames = SentryStackTrace(listOf(SentryStackFrame().apply { function = "connect"; module = "com.danyzmaj.pocketterm.Net" }))
        val exception = SentryException().apply {
            type = "java.net.ConnectException"
            value = "Failed to connect to /192.168.1.20:8080"
            stacktrace = frames
        }
        val event = SentryEvent().apply {
            message = Message().apply { formatted = "lost https://studio.example.com/x"; params = listOf("me@example.com") }
            exceptions = listOf(exception)
            user = User().apply { id = "u" }
            request = Request().apply { url = "http://10.0.0.1" }
            serverName = "Danijels-MacBook"
            setExtra("terminal", "ls -la ~/secret")
            contexts.setDevice(Device().apply { name = "Danijel's Pixel"; id = "b1dce983e1164a52"; model = "Pixel 9" })
        }

        val out = ErrorScrubber.scrub(event)

        assertEquals("lost https://<redacted>", out.message?.formatted)
        assertEquals(listOf("<email>"), out.message?.params)
        val e = out.exceptions!!.single()
        assertEquals("java.net.ConnectException", e.type)
        assertEquals("Failed to connect to /<ip>:8080", e.value)
        assertSame(frames, e.stacktrace)
        assertNull(out.user)
        assertNull(out.request)
        assertNull(out.serverName)
        assertNull(out.getExtra("terminal"))
        assertNull(out.contexts.device?.name)
        assertNull(out.contexts.device?.id)
        assertEquals("Pixel 9", out.contexts.device?.model)
    }
}
