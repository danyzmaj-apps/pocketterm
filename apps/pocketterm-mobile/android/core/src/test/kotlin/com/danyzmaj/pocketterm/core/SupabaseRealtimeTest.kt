package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * [RealtimeLive]: PROTOCOL.md's frames in and out of Supabase Realtime's Phoenix channels, with the
 * Phoenix side scripted ([Phoenix]) and the project's answers too ([Project]), on virtual time.
 */
class SupabaseRealtimeTest {
    /** The Realtime connection: what [RealtimeLive] sent, and what Realtime says ([say]). */
    private class Phoenix : LiveSocket {
        val sent = mutableListOf<String>()
        private val incoming = Channel<String>(Channel.UNLIMITED)
        override val frames: Flow<String> = incoming.receiveAsFlow()
        override var closeCode: Int? = null
        var closed = false

        fun say(vararg pairs: Pair<String, Any?>) {
            incoming.trySend(jsonEncode(jsonOf(*pairs)))
        }

        /** Realtime hangs up. */
        fun hangUp() = incoming.close()

        override fun add(frame: String) {
            sent.add(frame)
        }

        override suspend fun close(code: Int) {
            closed = true
            closeCode = code
            incoming.close()
        }
    }

    /** The project: counts sign-in checks, and answers live token requests with [answers] in turn. */
    private class Project : SupabaseServerClient(Backend(url = "https://abcd.supabase.co", kind = BackendKind.supabase), MemoryDeviceTokens()) {
        var rechecks = 0
        val answers = ArrayDeque<() -> LiveToken>()
        var asked = 0

        override suspend fun recheck() {
            rechecks++
        }

        override suspend fun liveToken(): LiveToken {
            asked++
            // None scripted: the project never answers (runTest runs what's left on the clock at the end).
            return answers.removeFirstOrNull()?.invoke() ?: awaitCancellation()
        }
    }

    private class Run(val scope: TestScope) {
        val phoenix = Phoenix()
        val project = Project()
        val dispatcher = StandardTestDispatcher(scope.testScheduler)
        val out = mutableListOf<String>()
        var done = false

        fun live(expiresInMs: Long = 10.minutes.inWholeMilliseconds): RealtimeLive {
            val token = LiveToken("tok-1", Instant.ofEpochMilli(scope.testScheduler.currentTime + expiresInMs), "key")
            val live = RealtimeLive(project, phoenix, token, clock = { scope.testScheduler.currentTime }, dispatcher = dispatcher)
            scope.backgroundScope.launch(dispatcher) {
                live.frames.collect { out.add(it) }
                done = true
            }
            scope.runCurrent()
            return live
        }

        /** [RealtimeLive.add], then what follows from it. */
        fun RealtimeLive.put(vararg pairs: Pair<String, Any?>) {
            add(jsonEncode(jsonOf(*pairs)))
            scope.runCurrent()
        }

        fun say(vararg pairs: Pair<String, Any?>) {
            phoenix.say(*pairs)
            scope.runCurrent()
        }

        val testScheduler get() = scope.testScheduler

        fun runCurrent() = scope.runCurrent()

        fun advanceTimeBy(ms: Long) = scope.advanceTimeBy(ms)
    }

    private fun realtime(body: suspend Run.() -> Unit) = runTest { Run(this).body() }

    private val joinFrame =
        """{"topic":"realtime:abcd1234","event":"phx_join","payload":{"config":{"broadcast":{"self":false,"ack":false},""" +
            """"presence":{"key":"","enabled":false},"private":true},"access_token":"tok-1"},"ref":"1","join_ref":"1"}"""

    @Test
    fun `a join is a private channel joined with the device's token, and joined once Realtime says ok`() = realtime {
        val live = live()
        live.put("t" to "join", "topic" to "abcd1234")
        assertEquals(listOf(joinFrame), phoenix.sent)
        // Not joined yet: a send is refused here, as the PocketTerm server refuses it.
        live.put("t" to "send", "topic" to "abcd1234", "event" to "e2e", "payload" to jsonOf("x" to 1))
        assertEquals(listOf("""{"t":"error","error":"not_joined","message":"Join abcd1234 first."}"""), out)
        assertEquals(1, phoenix.sent.size)

        say("topic" to "realtime:abcd1234", "event" to "phx_reply", "payload" to jsonOf("status" to "ok", "response" to jsonOf()), "ref" to "1", "join_ref" to "1")
        assertEquals("""{"t":"joined","topic":"abcd1234"}""", out.last())
    }

    @Test
    fun `send broadcasts on the joined channel, and broadcasts there come in as messages`() = realtime {
        val live = live()
        live.put("t" to "join", "topic" to "abcd1234")
        say("topic" to "realtime:abcd1234", "event" to "phx_reply", "payload" to jsonOf("status" to "ok"), "ref" to "1")
        live.put("t" to "send", "topic" to "abcd1234", "event" to "e2e", "payload" to jsonOf("v" to 1, "n" to "abc"))
        assertEquals(
            """{"topic":"realtime:abcd1234","event":"broadcast","payload":{"type":"broadcast","event":"e2e","payload":{"v":1,"n":"abc"}},"ref":"2","join_ref":"1"}""",
            phoenix.sent.last(),
        )

        say("topic" to "realtime:abcd1234", "event" to "broadcast", "payload" to jsonOf("type" to "broadcast", "event" to "e2e", "payload" to jsonOf("c" to "x")), "ref" to null)
        assertEquals("""{"t":"msg","topic":"abcd1234","event":"e2e","payload":{"c":"x"}}""", out.last())
        // One on a topic not joined, or without an event, is nobody's.
        val before = out.size
        say("topic" to "realtime:zzzz9999", "event" to "broadcast", "payload" to jsonOf("type" to "broadcast", "event" to "e2e", "payload" to jsonOf()))
        say("topic" to "realtime:abcd1234", "event" to "broadcast", "payload" to jsonOf("type" to "broadcast"))
        assertEquals(before, out.size)
    }

    @Test
    fun `leave leaves the channel, ping is the heartbeat and its answer a pong`() = realtime {
        val live = live()
        live.put("t" to "join", "topic" to "abcd1234")
        live.put("t" to "leave", "topic" to "abcd1234")
        assertEquals("""{"topic":"realtime:abcd1234","event":"phx_leave","payload":{},"ref":"2","join_ref":"1"}""", phoenix.sent.last())
        // Left: a second leave sends nothing, and a send is refused.
        live.put("t" to "leave", "topic" to "abcd1234")
        assertEquals(2, phoenix.sent.size)
        live.put("t" to "send", "topic" to "abcd1234", "event" to "e2e", "payload" to jsonOf())
        assertEquals("""{"t":"error","error":"not_joined","message":"Join abcd1234 first."}""", out.last())

        live.put("t" to "ping")
        assertEquals("""{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"3"}""", phoenix.sent.last())
        say("topic" to "phoenix", "event" to "phx_reply", "payload" to jsonOf("status" to "ok", "response" to jsonOf()), "ref" to "3")
        assertEquals("""{"t":"pong"}""", out.last())
        // An answer to nothing it asked says nothing.
        val before = out.size
        say("topic" to "phoenix", "event" to "phx_reply", "payload" to jsonOf("status" to "ok"), "ref" to "3")
        say("topic" to "phoenix", "event" to "phx_reply", "payload" to jsonOf("status" to "ok"), "ref" to "99")
        assertEquals(before, out.size)
        // Frames it doesn't read go nowhere.
        live.put("t" to "nope")
        live.add("not json")
        runCurrent()
        assertEquals(3, phoenix.sent.size)
        assertFalse(done)
    }

    @Test
    fun `a join Realtime refuses asks whether the sign-in holds and closes, so the channel connects again`() = realtime {
        val live = live()
        live.put("t" to "join", "topic" to "abcd1234")
        say("topic" to "realtime:abcd1234", "event" to "phx_reply", "payload" to jsonOf("status" to "error", "response" to jsonOf("reason" to "Unauthorized")), "ref" to "1")
        assertEquals(1, project.rechecks)
        assertTrue(done)
        assertTrue(phoenix.closed)
        assertEquals(1000, live.closeCode, "an ordinary close: not signed out")
        assertTrue(out.none { it.contains("joined") })
    }

    @Test
    fun `a channel Realtime closes or errors, or a system error, closes it after a check`() = realtime {
        for (event in listOf("phx_close", "phx_error", "system")) {
            val r = Run(scope)
            with(r) {
                val live = live()
                live.put("t" to "join", "topic" to "abcd1234")
                say("topic" to "realtime:abcd1234", "event" to "phx_reply", "payload" to jsonOf("status" to "ok"), "ref" to "1")
                // On a topic it never joined, or a system message that's fine, nothing happens.
                say("topic" to "realtime:zzzz9999", "event" to event, "payload" to jsonOf("status" to "ok"))
                assertFalse(done, event)
                say("topic" to "realtime:abcd1234", "event" to event, "payload" to jsonOf("status" to "error", "message" to "Token has expired"))
                assertEquals(1, project.rechecks, event)
                assertTrue(done, event)
            }
        }
    }

    @Test
    fun `pt left on a joined topic asks whether this device was signed out, and goes no further`() = realtime {
        val live = live()
        live.put("t" to "join", "topic" to "abcd1234")
        say("topic" to "realtime:abcd1234", "event" to "phx_reply", "payload" to jsonOf("status" to "ok"), "ref" to "1")
        val before = out.size
        say("topic" to "realtime:abcd1234", "event" to "broadcast", "payload" to jsonOf("type" to "broadcast", "event" to "pt.left", "payload" to jsonOf()))
        assertEquals(1, project.rechecks)
        assertEquals(before, out.size)
        assertFalse(done)
    }

    @Test
    fun `the token is renewed a minute before it runs out, on every joined channel`() = realtime {
        val live = live()
        live.put("t" to "join", "topic" to "abcd1234")
        live.put("t" to "join", "topic" to "efgh5678")
        project.answers.add { LiveToken("tok-2", Instant.ofEpochMilli(testScheduler.currentTime + 10.minutes.inWholeMilliseconds), "key") }
        project.answers.add { LiveToken("tok-3", Instant.ofEpochMilli(testScheduler.currentTime + 10.minutes.inWholeMilliseconds), "key") }
        advanceTimeBy(9.minutes.inWholeMilliseconds - 1)
        runCurrent()
        assertEquals(0, project.asked)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(1, project.asked)
        assertEquals(
            listOf(
                """{"topic":"realtime:abcd1234","event":"access_token","payload":{"access_token":"tok-2"},"ref":"3","join_ref":"1"}""",
                """{"topic":"realtime:efgh5678","event":"access_token","payload":{"access_token":"tok-2"},"ref":"4","join_ref":"2"}""",
            ),
            phoenix.sent.drop(2),
        )
        // A join after that goes with the new token; the next renewal comes 9 minutes on.
        live.put("t" to "join", "topic" to "ijkl9012")
        assertTrue(phoenix.sent.last().contains("\"access_token\":\"tok-2\""))
        advanceTimeBy(9.minutes.inWholeMilliseconds + 1)
        runCurrent()
        assertEquals(2, project.asked)
    }

    @Test
    fun `a token that runs out soon is renewed after 10 seconds at the least`() = realtime {
        live(expiresInMs = 30.seconds.inWholeMilliseconds)
        project.answers.add { LiveToken("tok-2", Instant.ofEpochMilli(testScheduler.currentTime + 10.minutes.inWholeMilliseconds), "key") }
        advanceTimeBy(10.seconds.inWholeMilliseconds - 1)
        runCurrent()
        assertEquals(0, project.asked)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(1, project.asked)
    }

    @Test
    fun `a renewal the server can't answer is tried again in 15 seconds, one it refuses closes it with 4003`() = realtime {
        val live = live()
        live.put("t" to "join", "topic" to "abcd1234")
        project.answers.add { throw ServerException(0, "offline", "Offline.") }
        project.answers.add { throw ServerException(401, "unauthorized", "Signed out.") }
        advanceTimeBy(9.minutes.inWholeMilliseconds + 1)
        runCurrent()
        assertEquals(1, project.asked)
        assertFalse(done)
        advanceTimeBy(15.seconds.inWholeMilliseconds)
        runCurrent()
        assertEquals(2, project.asked)
        assertTrue(done)
        assertEquals(4003, live.closeCode, "this device was signed out")
        assertTrue(phoenix.closed)
    }

    @Test
    fun `once Realtime hangs up its frames are done and the token is renewed no more`() = realtime {
        val live = live()
        phoenix.hangUp()
        runCurrent()
        assertTrue(done)
        assertNull(live.closeCode)
        advanceTimeBy(30.minutes.inWholeMilliseconds)
        runCurrent()
        assertEquals(0, project.asked)
    }

    @Test
    fun `closed, it sends Realtime nothing more`() = realtime {
        val live = live()
        live.close()
        runCurrent()
        assertTrue(done)
        live.put("t" to "join", "topic" to "abcd1234")
        assertTrue(phoenix.sent.isEmpty())
        assertEquals(1000, live.closeCode)
    }
}
