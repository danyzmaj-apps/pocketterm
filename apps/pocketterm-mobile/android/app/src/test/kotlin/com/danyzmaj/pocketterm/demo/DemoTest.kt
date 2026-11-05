package com.danyzmaj.pocketterm.demo

import com.danyzmaj.pocketterm.core.TerminalException
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** "Try the demo": a made-up computer in two projects that answers the phone itself, with no network at all. */
class DemoTest {
    @Test
    fun `the demo shows a made-up computer in two projects and answers itself`() = runTest {
        val dir = Files.createTempDirectory("demo").toFile()
        val demo = DemoComputer(dir, backgroundScope)
        val r = demo.remote

        assertEquals(demoDesktopId, demo.desktops.selected?.id)
        assertEquals(demoDesktopName, demo.desktops.selected?.name)
        assertTrue(r.online, "its state came, so it reads as online")
        assertEquals(listOf("kitty-1/3", "wezterm-2", "tmux-%4"), r.sessions.map { it.key })
        assertEquals(setOf(demoGarden, demoSite), r.sessions.map { it.cwd }.toSet())
        assertTrue(r.windows.any { it.key == demoScreenOnly }, "a window showing only its screen")
        assertEquals(4, r.session("tmux-%4")!!.queue.size)

        // A conversation, and an approval the demo carries on from.
        r.watchSession("wezterm-2")
        runCurrent()
        assertTrue(r.view("wezterm-2")!!.items.last().text.contains("I want to build the site to check it"))
        r.answer("wezterm-2", r.session("wezterm-2")!!.ask!!, approve = true)
        runCurrent()
        assertTrue(r.view("wezterm-2")!!.items.last().text.startsWith("Built in 6.2 s"))
        assertNull(r.session("wezterm-2")!!.ask)

        // A prompt gets the demo's own answer.
        r.prompt("wezterm-2", "Also check the footer")
        runCurrent()
        val texts = r.view("wezterm-2")!!.items.map { it.text }
        assertTrue("Also check the footer" in texts)
        assertTrue(texts.last().startsWith("This is the demo: there's no computer behind it"))

        // A follow-up to the session at work waits in its queue, which can be reordered and held.
        val queued = r.prompt("tmux-%4", "And the docs", followUp = true)
        runCurrent()
        assertEquals("dq5", queued)
        r.moveQueued("tmux-%4", "dq5", 0)
        r.pauseQueue("tmux-%4", paused = true)
        runCurrent()
        val s3 = r.session("tmux-%4")!!
        assertEquals(listOf("dq5", "dq1", "dq2", "dq3", "dq4"), s3.queue.map { it.id })
        assertTrue(s3.paused)

        // Only the screen-only window looks busy; what the demo can't pretend says so.
        assertTrue(r.probe(demoScreenOnly))
        assertFalse(r.probe("kitty-1/1"))
        val refused = assertFailsWith<TerminalException> { r.close("kitty-1/1") }
        assertEquals(demoNoComputer, refused.message)

        demo.dispose()
        assertFalse(dir.exists(), "its cache goes with it")
    }
}
