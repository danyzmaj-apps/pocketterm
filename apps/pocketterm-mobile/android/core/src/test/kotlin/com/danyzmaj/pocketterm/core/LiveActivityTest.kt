package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.nio.file.Files
import java.time.Instant
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LiveActivityTest {
    private fun summary(busy: Boolean = false, ask: LiveAsk? = null) =
        LiveSummary(key = "kitty-1/2", id = "s", title = "Fix it", cwd = "/x/pocketterm", busy = busy, ask = ask, epoch = "e", seq = 0)

    private val question = LiveAsk.questions("q", listOf(LiveQuestion(id = "a", question = "Which?", options = listOf("A", "B"))))

    private val dirs = mutableListOf<File>()

    private fun tempDir(): File = Files.createTempDirectory("pocketterm_activity").toFile().also { dirs += it }

    @AfterTest
    fun cleanUp() {
        dirs.forEach { it.deleteRecursively() }
        pushPlatform = "android"
    }

    @Test
    fun `a session maps to working, done, or needs with what it waits for`() {
        assertEquals(ActivityStatus(ActivityState.working), summaryStatus(summary(busy = true)))
        assertEquals(ActivityStatus(ActivityState.done), summaryStatus(summary()))
        assertEquals(ActivityStatus(ActivityState.needs, ActivityKind.question), summaryStatus(summary(ask = question)))
        assertEquals(
            ActivityStatus(ActivityState.needs, ActivityKind.approval),
            summaryStatus(summary(busy = true, ask = LiveAsk.approval("t", tool = "bash"))),
        )
        assertEquals(ActivityStatus(ActivityState.needs, ActivityKind.plan), summaryStatus(summary(busy = true, ask = LiveAsk.plan("p"))))
    }

    @Test
    fun `a session gone from the Mac has ended`() {
        assertEquals(ActivityStatus(ActivityState.ended, null), summaryStatus(null))
    }

    @Test
    fun `pushes carry the state and, only when it needs you, the kind`() {
        assertEquals(jsonOf("state" to "working"), activityJson(ActivityStatus(ActivityState.working)))
        assertEquals(jsonOf("state" to "needs", "kind" to "plan"), activityJson(ActivityStatus(ActivityState.needs, ActivityKind.plan)))
    }

    private fun TestScope.remote(server: Server, sessions: List<Map<String, Any?>>? = null) =
        TerminalRemote(
            server,
            tempDir(),
            desktopId = "abcd1234",
            key = ChannelKey(ByteArray(32) { 7 }),
            scope = backgroundScope,
            send = { _, _ -> },
            clock = { testScheduler.currentTime },
        ).also { r -> if (sessions != null) r.handle("state", jsonOf("windows" to emptyList<Any>(), "sessions" to sessions)) }

    @Test
    fun `the native side knows a session with its computer and another computer's activities are left alone`() = runTest {
        val native = FakeNative(activities = listOf(LiveActivityRef("abcd1234/kitty-1/1", null), LiveActivityRef("zzzz9999/kitty-1/1", null)))
        val client = Pushes()
        val remote = remote(
            client,
            listOf(
                mapOf("key" to "kitty-1/1", "id" to "s1", "title" to "Old", "cwd" to "/x", "epoch" to "e", "seq" to 0),
                mapOf("key" to "kitty-1/2", "id" to "s2", "title" to "Fix it", "cwd" to "C:\\Users\\me\\app\\", "epoch" to "e", "seq" to 0),
            ),
        )
        val a = LiveActivities(client, remote, native, backgroundScope, clock = { testScheduler.currentTime })
        runCurrent()
        assertTrue(a.following("kitty-1/1"))

        assertTrue(a.follow("kitty-1/2", title = "Fix it"))
        val start = native.calls.last { it.first == "startActivity" }.second
        assertEquals("abcd1234/kitty-1/2" to "app", start["key"] to start["project"])

        a.onNative("activityEnded", mapOf("key" to "zzzz9999/kitty-1/1"))
        assertTrue(a.following("kitty-1/1"))
        a.onNative("activityEnded", mapOf("key" to "abcd1234/kitty-1/1"))
        assertFalse(a.following("kitty-1/1"))

        a.stop("kitty-1/2")
        assertEquals("endActivity" to "abcd1234/kitty-1/2", native.calls.last().first to native.calls.last().second["key"])
    }

    @Test
    fun `one Live Activity more than iOS shows is told apart from them being off and a prompt goes all the same`() = runTest {
        val native = FakeNative(tooMany = true)
        val client = Pushes()
        val remote = remote(client, listOf(mapOf("key" to "kitty-1/2", "id" to "s2", "title" to "Fix it", "cwd" to "/x/app", "epoch" to "e", "seq" to 0)))
        val a = LiveActivities(client, remote, native, backgroundScope, clock = { testScheduler.currentTime })
        runCurrent()
        assertFailsWith<TooManyActivities> { a.follow("kitty-1/2", title = "Fix it") }
        a.prompted("kitty-1/2", title = "Fix it")
        assertFalse(a.following("kitty-1/2"))
    }

    @Test
    fun `an Android phone names a followed session to the server with a tag only that computer's key makes`() = runTest {
        val native = FakeNative(keys = mapOf("zzzz9999" to ChannelKey(ByteArray(32) { 9 }).toBase64()))
        val client = Pushes()
        val remote = remote(client)
        val a = LiveActivities(client, remote, native, backgroundScope, clock = { testScheduler.currentTime })
        runCurrent()
        val fcm = "f".repeat(160)

        pushPlatform = "android"
        a.onNative("activityToken", mapOf("key" to "abcd1234/kitty-1/2", "token" to fcm))
        a.onNative("activityToken", mapOf("key" to "zzzz9999/kitty-1/2", "token" to fcm))
        a.onNative("activityToken", mapOf("key" to "qqqq0000/kitty-1/2", "token" to fcm))
        runCurrent()
        assertEquals(setOf("activity_register"), client.sent.map { it.first }.toSet())
        assertEquals(
            setOf(
                jsonOf("token" to fcm, "session" to "abcd1234/kitty-1/2", "platform" to "android", "ref" to "yMPqtkm1TA3-r0AeuNDSHg"),
                jsonOf(
                    "token" to fcm,
                    "session" to "zzzz9999/kitty-1/2",
                    "platform" to "android",
                    "ref" to sessionTag(ChannelKey(ByteArray(32) { 9 }), "zzzz9999/kitty-1/2"),
                ),
                // No key for that computer: nothing it sends would open, and the server refuses a session without its tag.
                jsonOf("token" to fcm, "session" to "qqqq0000/kitty-1/2", "platform" to "android"),
            ),
            client.sent.map { it.second }.toSet(),
        )
        assertEquals(3, client.sent.size)

        // An iPhone's activity has a token of its own: Apple routes by it, the server needs no tag.
        client.sent.clear()
        pushPlatform = "ios"
        a.onNative("activityToken", mapOf("key" to "abcd1234/kitty-1/2", "token" to "ab".repeat(40)))
        runCurrent()
        assertEquals(jsonOf("token" to "ab".repeat(40), "session" to "abcd1234/kitty-1/2", "platform" to "ios"), client.sent.single().second)
    }
}

/** A server client that records the pushes it is asked for. */
private class Pushes(
    inner: Server = PocketTermServerClient(Backend(url = "http://localhost:1"), MemoryDeviceTokens()),
) : Server by inner {
    val sent = mutableListOf<Pair<String, JsonObject>>()

    override suspend fun push(action: String, body: JsonObject): JsonObject {
        sent += action to body
        return jsonOf("ok" to true)
    }
}

/** The platform side, recording its calls. */
private class FakeNative(
    private val activities: List<LiveActivityRef> = emptyList(),
    private val keys: Map<String, String> = emptyMap(),
    private val tooMany: Boolean = false,
) : Native {
    val calls = mutableListOf<Pair<String, Map<String, Any?>>>()

    override val events: Flow<NativeEvent> = emptyFlow()

    override suspend fun takeTappedSession(): String? = null

    override suspend fun registerPush(): String? = null

    override suspend fun notificationsAllowed(): Boolean = true

    override suspend fun openSettings(notifications: Boolean) {}

    override suspend fun channelKeys(): Map<String, String> = keys

    override suspend fun setChannelKey(desktop: String, key: String) {}

    override suspend fun removeAllChannelKeys() {}

    override suspend fun startActivity(key: String, title: String, project: String, state: String, since: Instant, kind: String?): Boolean {
        calls += "startActivity" to mapOf("key" to key, "title" to title, "project" to project, "state" to state, "kind" to kind)
        if (tooMany) throw TooManyActivities()
        return true
    }

    override suspend fun updateActivity(key: String, state: String, since: Instant, kind: String?) {
        calls += "updateActivity" to mapOf("key" to key, "state" to state, "kind" to kind)
    }

    override suspend fun endActivity(key: String, immediate: Boolean) {
        calls += "endActivity" to mapOf("key" to key, "immediate" to immediate)
    }

    override suspend fun liveActivities(): List<LiveActivityRef> = activities

    override suspend fun getBackend(): SavedBackend? = null

    override suspend fun setBackend(url: String?, kind: String?) {}

    override suspend fun deviceToken(): String? = null

    override suspend fun setDeviceToken(value: String?) {}

    override suspend fun deviceName(): String = "Phone"

    override suspend fun setKeepAwake(on: Boolean) {}

    override suspend fun setAppIcon(icon: String) {}
}
