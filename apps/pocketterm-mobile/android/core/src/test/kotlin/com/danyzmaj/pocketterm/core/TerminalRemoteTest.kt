package com.danyzmaj.pocketterm.core

import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.milliseconds

class TerminalRemoteTest {
    private lateinit var dir: File
    private val sent = mutableListOf<Pair<String, JsonObject>>()
    private val client = PocketTermServerClient(Backend(url = "http://localhost:1"), MemoryDeviceTokens())

    /** Wall-clock epoch the virtual clock starts at: cache files carry real modification times. */
    private val base = System.currentTimeMillis()

    @BeforeTest
    fun setUp() {
        dir = Files.createTempDirectory("pocketterm_terminal").toFile()
    }

    @AfterTest
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun TestScope.remote(desktopId: String = "abcd1234") = TerminalRemote(
        client,
        dir,
        desktopId = desktopId,
        key = ChannelKey(ByteArray(32) { 7 }),
        scope = backgroundScope,
        from = "phone",
        send = { event, payload -> sent += event to payload },
        clock = { base + testScheduler.currentTime },
    )

    private fun syncs() = sent.filter { it.first == "sync" }.map { it.second }

    private fun runs() = sent.filter { it.first == "run" }.map { it.second }

    private fun item(id: String, text: String, order: Long, seq: Long) =
        LiveItem(id = id, kind = ItemKind.assistant, text = text, order = order, seq = seq).toJson()

    private fun state(epoch: String = "e1", seq: Int = 2, vararg extra: Pair<String, Any?>) = jsonOf(
        "windows" to listOf(mapOf("key" to "kitty-1/1", "title" to "omp", "cwd" to "/Users/me/x", "program" to "omp")),
        "sessions" to listOf(
            mapOf("key" to "kitty-1/1", "id" to "s1", "window" to "kitty-1/1", "title" to "Fix it", "cwd" to "/Users/me/x", "epoch" to epoch, "seq" to seq),
        ),
        "projects" to listOf("/Users/me/x"),
        "roots" to listOf("/Users/me"),
        "home" to "/Users/me",
    ).let { s -> extra.fold(s) { o, (k, v) -> o.plus(k, v) } }

    private fun items(to: String = "phone", seq: Int = 2, last: Boolean = true) = jsonOf(
        "to" to to,
        "session" to "kitty-1/1",
        "epoch" to "e1",
        "seq" to seq,
        "reset" to true,
        "items" to listOf(item("a", "one", 0, 1), item("b", "two", 1, 2)),
        "last" to last,
        "older" to false,
    )

    @Test
    fun `a new remote on the same cache shows the last state and transcript before the Mac answers`() = runTest {
        remote().apply {
            handle("state", state())
            handle("items", items())
            flush()
        }

        val b = remote()
        assertTrue(b.fromCache)
        assertNotNull(b.stateAt)
        assertEquals("/Users/me", b.home)
        assertEquals(listOf("/Users/me/x"), b.projects)
        assertEquals(listOf("/Users/me"), b.roots)
        assertEquals("kitty-1/1", b.windows.single().key)
        assertEquals("Fix it", b.sessions.single().title)
        val v = b.view("kitty-1/1")!!
        assertEquals("e1", v.epoch)
        assertEquals(2, v.seq)
        assertEquals(listOf("one", "two"), v.items.map { it.text })

        // The first state from the Mac replaces the cached one.
        b.handle("state", state())
        assertFalse(b.fromCache)
    }

    @Test
    fun `each computer has its own cache - another's state never shows`() = runTest {
        remote().apply {
            handle("state", state())
            handle("items", items())
            flush()
        }
        val other = remote(desktopId = "zzzz9999")
        assertFalse(other.fromCache)
        assertTrue(other.sessions.isEmpty())
        assertNull(other.view("kitty-1/1"))
    }

    @Test
    fun `where sessions open, the Mac's terminals and Project folders survive the cache, an older Mac has none`() = runTest {
        val a = remote()
        a.handle(
            "state",
            state(
                extra = arrayOf(
                    "opensIn" to "Ghostty (in tmux)",
                    "terminals" to listOf(
                        mapOf("id" to "ghostty", "label" to "Ghostty", "state" to "limited", "note" to "no screen"),
                        mapOf("id" to "tmux", "label" to "tmux", "state" to "ready", "note" to ""),
                    ),
                ),
            ),
        )
        assertEquals("Ghostty (in tmux)", a.opensIn)
        assertEquals(
            listOf(Triple("ghostty", TermState.limited, "no screen"), Triple("tmux", TermState.ready, "")),
            a.terminals.map { Triple(it.id, it.state, it.note) },
        )
        a.flush()

        val b = remote()
        assertEquals("Ghostty (in tmux)", b.opensIn)
        assertEquals(
            listOf(Triple("ghostty", "Ghostty", TermState.limited), Triple("tmux", "tmux", TermState.ready)),
            b.terminals.map { Triple(it.id, it.label, it.state) },
        )

        b.handle("state", state(extra = arrayOf("roots" to emptyList<Any>())))
        assertEquals(emptyList(), b.roots)
        b.handle("state", JsonObject(state() - "roots"))
        assertNull(b.opensIn)
        assertTrue(b.terminals.isEmpty())
        // No Project folders at all, not none added: it can't make a project.
        assertNull(b.roots)
    }

    @Test
    fun `where PocketTerm stands in each agent survives the cache - unknown ones and an older Mac's give none`() = runTest {
        val a = remote()
        a.handle("state", state(extra = arrayOf("agents" to mapOf("omp" to "installed", "claude" to "off", "codex" to "installed", "other" to "weird"))))
        assertEquals(mapOf(Agent.omp to AgentIntegration.installed, Agent.claude to AgentIntegration.off), a.agents)
        a.flush()

        val b = remote()
        assertEquals(mapOf(Agent.omp to AgentIntegration.installed, Agent.claude to AgentIntegration.off), b.agents)
        b.handle("state", state(extra = arrayOf("agents" to mapOf("omp" to "bogus", "claude" to "missing"))))
        assertEquals(mapOf(Agent.claude to AgentIntegration.missing), b.agents)
        b.handle("state", state())
        assertTrue(b.agents.isEmpty())
    }

    @Test
    fun `watching asks for what the cached view misses`() = runTest {
        remote().apply {
            handle("items", items())
            flush()
        }
        remote().watchSession("kitty-1/1")
        assertEquals(jsonOf("from" to "phone", "session" to "kitty-1/1", "epoch" to "e1", "since" to 2), syncs().single())
    }

    @Test
    fun `a gap in live ops syncs from what the view has`() = runTest {
        val r = remote()
        r.watchSession("kitty-1/1")
        assertEquals(0, syncs().single()["since"].int)
        r.handle("items", items())
        sent.clear()

        // seq 3 never came.
        r.handle("live", jsonOf("session" to "kitty-1/1", "epoch" to "e1", "ops" to listOf(mapOf("s" to 4, "id" to "b", "a" to "!"))))
        assertEquals(jsonOf("from" to "phone", "session" to "kitty-1/1", "epoch" to "e1", "since" to 2), syncs().single())
    }

    @Test
    fun `live ops during a sync wait for it, then apply`() = runTest {
        val r = remote()
        r.watchSession("kitty-1/1")
        r.handle("live", jsonOf("session" to "kitty-1/1", "epoch" to "e1", "ops" to listOf(mapOf("s" to 3, "id" to "b", "a" to " more"))))
        r.handle("items", items())
        assertEquals("two more", r.view("kitty-1/1")!!.items.last().text)
        assertEquals(3, r.view("kitty-1/1")!!.seq)
        assertEquals(1, syncs().size)
    }

    @Test
    fun `a new epoch in the state syncs the watched session`() = runTest {
        val r = remote()
        r.watchSession("kitty-1/1")
        r.handle("items", items())
        sent.clear()
        r.handle("state", state(epoch = "e2", seq = 1))
        assertEquals("e1", syncs().single()["epoch"].str)
    }

    @Test
    fun `items for another phone are ignored`() = runTest {
        val r = remote()
        r.handle("items", items(to = "other"))
        assertNull(r.view("kitty-1/1"))
    }

    @Test
    fun `a screen diff on a version the phone missed asks for the whole screen`() = runTest {
        val r = remote()
        r.watchWindow("w")
        sent.clear()
        r.handle("screen", jsonOf("window" to "w", "v" to 1, "lines" to listOf("a", "b", "c")))
        r.handle("screen", jsonOf("window" to "w", "v" to 2, "diff" to ScreenDiff(drop = 1, keep = 2, tail = listOf("d")).toJson()))
        assertEquals(listOf("b", "c", "d"), r.screen("w")!!.lines)
        assertEquals(1, r.screen("w")!!.base)
        assertTrue(syncs().isEmpty())

        // Version 3 went missing.
        r.handle("screen", jsonOf("window" to "w", "v" to 4, "diff" to ScreenDiff(drop = 0, keep = 3, tail = listOf("e")).toJson()))
        assertEquals(listOf("b", "c", "d"), r.screen("w")!!.lines)
        assertEquals(jsonOf("from" to "phone", "window" to "w"), syncs().single())
    }

    @Test
    fun `a whole screen that scrolled keeps count of the lines gone`() = runTest {
        val r = remote()
        r.handle("screen", jsonOf("window" to "w", "v" to 1, "lines" to listOf("a", "b", "c", "d")))
        r.handle("screen", jsonOf("window" to "w", "v" to 2, "lines" to listOf("c", "d", "e", "f")))
        assertEquals(2, r.screen("w")!!.base)
    }

    @Test
    fun `closing a watch goes back to the one under it`() = runTest {
        val r = remote()
        val unwatchSession = r.watchSession("s")
        val unwatchWindow = r.watchWindow("w")
        assertEquals(null to "w", r.watchedSession to r.watchedWindow)
        unwatchWindow()
        assertEquals("s" to null, r.watchedSession to r.watchedWindow)
        unwatchSession()
        assertEquals(null to null, r.watchedSession to r.watchedWindow)
    }

    @Test
    fun `session files untouched for 14 days are pruned on load`() = runTest {
        remote().apply {
            handle("items", items())
            flush()
        }
        val file = File(dir, "terminal/abcd1234/sessions").listFiles()!!.single { it.isFile }
        file.setLastModified(System.currentTimeMillis() - 15.days.inWholeMilliseconds)
        assertNull(remote().view("kitty-1/1"))
        assertFalse(file.exists())
    }

    @Test
    fun `a window launched under an ended session's key starts with no transcript`() = runTest {
        // The ended session's transcript, kept on disk too.
        remote().apply {
            handle("items", items())
            flush()
        }
        val r = remote()
        r.handle("state", state(extra = arrayOf("sessions" to emptyList<Any>())))
        assertNotNull(r.view("kitty-1/1"))

        val launched = async { r.launch("/Users/me/x", startAgent = true) }
        runCurrent()
        val run = runs().last()
        assertEquals("launch", run["op"].str)
        // tmux numbers its panes from %0 again: the Mac answers with the same key.
        r.handle("ran", jsonOf("id" to run["id"], "window" to "kitty-1/1", "where" to "a new kitty window"))
        assertEquals(Opened(window = "kitty-1/1", where = "a new kitty window"), launched.await())

        assertNull(r.view("kitty-1/1"))
        r.flush()
        assertNull(remote().view("kitty-1/1"))
    }

    @Test
    fun `a prompt the computer did not answer goes again under the same id, so it never runs twice`() = runTest {
        val r = remote()
        r.handle("state", state())
        r.answerWait = 50.milliseconds

        assertFailsWith<TerminalException> { r.prompt("kitty-1/1", "fix it") }
        val first = runs().last()["id"].str
        // Sent again (the person taps Send once more): same id; the computer answers it as a repeat.
        val again = async { r.prompt("kitty-1/1", "fix it") }
        runCurrent()
        assertEquals(first, runs().last()["id"].str)
        r.handle("ran", jsonOf("id" to first, "repeat" to true))
        again.await()
        // Answered: the same text later is a new prompt.
        val next = async { r.prompt("kitty-1/1", "fix it") }
        runCurrent()
        assertNotEquals(first, runs().last()["id"].str)
        r.handle("ran", jsonOf("id" to runs().last()["id"]))
        next.await()
        // Another prompt after an unanswered one is new too.
        assertFailsWith<TerminalException> { r.prompt("kitty-1/1", "one") }
        val one = runs().last()["id"].str
        assertFailsWith<TerminalException> { r.prompt("kitty-1/1", "two") }
        assertNotEquals(one, runs().last()["id"].str)
    }

    @Test
    fun `create sends root, name and agent, and takes the window`() = runTest {
        val r = remote()
        r.handle("state", state())
        assertEquals(listOf("/Users/me"), r.roots)

        val made = async { r.create("/Users/me", "new", startAgent = false) }
        runCurrent()
        val run = runs().last()
        assertEquals("create", run["op"].str)
        assertEquals("/Users/me", run["root"].str)
        assertEquals("new", run["name"].str)
        assertEquals(false, run["agent"].bool)
        r.handle("ran", jsonOf("id" to run["id"], "window" to "kitty-1/2"))
        assertEquals(Opened(window = "kitty-1/2", where = ""), made.await(), "an older Mac doesn't say where")
    }

    @Test
    fun `probe asks whether a window's screen changes and takes the answer, switch names the agent`() = runTest {
        val r = remote()
        r.handle("state", state())

        val busy = async { r.probe("kitty-1/1") }
        runCurrent()
        assertEquals("probe", runs().last()["op"].str)
        assertEquals("kitty-1/1", runs().last()["window"].str)
        r.handle("ran", jsonOf("id" to runs().last()["id"], "busy" to true))
        assertTrue(busy.await())

        val idle = async { r.probe("kitty-1/1") }
        runCurrent()
        r.handle("ran", jsonOf("id" to runs().last()["id"], "busy" to false))
        assertFalse(idle.await())

        val switched = async { r.switchToConversation("kitty-1/1", Agent.claude) }
        runCurrent()
        assertEquals(listOf("switch", "kitty-1/1", "claude"), listOf("op", "window", "agent").map { runs().last()[it].str })
        r.handle("ran", jsonOf("id" to runs().last()["id"]))
        switched.await()

        val failed = async { runCatching { r.switchToConversation("kitty-1/1", Agent.omp) } }
        runCurrent()
        assertEquals("omp", runs().last()["agent"].str)
        r.handle("ran", jsonOf("id" to runs().last()["id"], "error" to "omp didn't quit."))
        val e = failed.await().exceptionOrNull()
        assertTrue(e is TerminalException)
        assertEquals("omp didn't quit.", e.message)
    }
}
