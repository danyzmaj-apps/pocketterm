package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Port of pocketterm_core/test/live_test.dart (and live_test's part of fuzz_test.dart). */
class LiveTest {
    private fun text(id: String, text: String, kind: ItemKind = ItemKind.assistant) = LiveItem(id = id, kind = kind, text = text)

    /** What a phone ends up with when every op reaches it through JSON. */
    private fun follow(log: LiveLog, ops: List<LiveOp>, view: LiveView? = null): LiveView {
        val v = view ?: LiveView(epoch = log.epoch)
        val wire = ops.map { LiveOp.fromJson(jsonDecode(jsonEncode(it.toJson())).obj!!) }
        assertTrue(v.apply(log.epoch, wire))
        return v
    }

    private fun LiveView.catchUpAll(log: LiveLog) = apply { catchUp(epoch = log.epoch, seq = log.seq, reset = true, items = log.items, last = true) }

    // routed keys

    @Test
    fun routedKeySplitsBack() {
        for (key in listOf("kitty-1/2", "tmux:default/0", "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074")) {
            assertEquals(RoutedKey("ab12cd34", key), splitRoutedKey(routedKey("ab12cd34", key)), key)
        }
    }

    @Test
    fun anythingElseSplitsIntoNothing() {
        for (s in listOf("kitty-1/2", "ab12cd3/kitty-1/2", "ab12cd345/kitty-1/2", "AB12CD34/kitty-1/2", "ab12cd34kitty-1", "ab12cd34/", "")) {
            assertNull(splitRoutedKey(s), s)
        }
    }

    // LiveLog → LiveView

    @Test
    fun followerEndsWithWhatTheMacHas() {
        val log = LiveLog(listOf(text("u1", "hi", ItemKind.user)), older = false)
        val view = LiveView(epoch = log.epoch).catchUpAll(log)
        val ops = listOf(
            log.upsert(text("a1", "")),
            log.append("a1", "Hel")!!,
            log.append("a1", "lo")!!,
            log.upsert(LiveItem(id = "t1", kind = ItemKind.tool, tool = "bash", args = "ls")),
            log.upsert(LiveItem(id = "t1", kind = ItemKind.tool, tool = "bash", args = "ls", output = "a\nb")),
        )
        follow(log, ops, view)
        assertEquals(listOf("u1", "a1", "t1"), view.items.map { it.id })
        assertEquals("Hello", view.items[1].text)
        assertEquals("a\nb", view.items[2].output)
        assertEquals(log.seq, view.seq)
    }

    @Test
    fun replacedItemShowsNewTextAfterTheListWasRead() {
        val log = LiveLog(emptyList(), older = false)
        val view = follow(log, listOf(log.upsert(text("a1", "")), log.append("a1", "Hel")!!))
        assertEquals("Hel", view.items.single().text)
        // The answer's final text, whole: the last streamed bit never went out on its own.
        follow(log, listOf(log.upsert(text("a1", "Hello."))), view)
        assertEquals("Hello.", view.items.single().text)
    }

    @Test
    fun opHoldsItemAsItWas() {
        val log = LiveLog(emptyList(), older = false)
        val upsert = log.upsert(text("a1", "He"))
        val append = log.append("a1", "llo")!!
        // Both are serialized only now, as a batch would be.
        assertEquals("Hello", follow(log, listOf(upsert, append)).items.single().text)
    }

    @Test
    fun missingOpIsDetectedAndCatchUpFillsTheGap() {
        val log = LiveLog(emptyList(), older = false)
        val view = follow(log, listOf(log.upsert(text("a1", "one"))))
        log.upsert(text("a2", "two")) // lost on the way
        val third = log.upsert(text("a3", "three"))
        assertFalse(view.apply(log.epoch, listOf(third)))
        view.catchUp(epoch = log.epoch, seq = log.seq, reset = false, items = log.since(view.seq), last = true)
        assertEquals(listOf("one", "two", "three"), view.items.map { it.text })
        assertEquals(log.seq, view.seq)
        // Ops the catch-up already covered are skipped, not doubled.
        assertTrue(view.apply(log.epoch, listOf(third)))
        assertEquals(3, view.items.size)
    }

    @Test
    fun newEpochRefusedByApplyAndReplacesOnReset() {
        val old = LiveLog(listOf(text("x", "old")), older = false)
        val view = LiveView(epoch = old.epoch).catchUpAll(old)
        val log = LiveLog(listOf(text("y", "new")), older = true)
        assertFalse(view.apply(log.epoch, listOf(log.upsert(text("z", "!")))))
        view.catchUp(epoch = log.epoch, seq = log.seq, reset = true, items = log.items, last = true, older = log.older)
        assertEquals(listOf("y", "z"), view.items.map { it.id })
        assertTrue(view.older)
    }

    @Test
    fun seqMovesOnlyWithTheLastChunk() {
        val log = LiveLog((0 until 4).map { text("$it", "$it") }, older = false)
        val view = LiveView(epoch = log.epoch)
        val items = log.items
        view.catchUp(epoch = log.epoch, seq = log.seq, reset = true, items = items.subList(0, 2), last = false)
        assertEquals(0, view.seq)
        view.catchUp(epoch = log.epoch, seq = log.seq, reset = true, items = items.subList(2, 4), last = true)
        assertEquals(log.seq, view.seq)
        assertEquals(4, view.items.size)
    }

    @Test
    fun olderItemsGoAboveTheOldest() {
        val log = LiveLog(listOf(text("c", "c"), text("d", "d")), older = true)
        val view = LiveView(epoch = log.epoch).catchUpAll(log)
        follow(log, log.addOlder(listOf(text("a", "a"), text("b", "b"), text("c", "dup")), more = false), view)
        assertEquals(listOf("a", "b", "c", "d"), view.items.map { it.id })
        assertEquals("c", view.items[2].text, "an item already there is not replaced by an older copy")
        assertFalse(log.older)
    }

    @Test
    fun logPastCapDropsOldest() {
        val log = LiveLog((0 until 5).map { text("$it", "$it") }, older = false, cap = 3)
        assertEquals(listOf("2", "3", "4"), log.items.map { it.id })
        assertTrue(log.older)
        log.upsert(text("5", "5"))
        assertEquals(listOf("3", "4", "5"), log.items.map { it.id })
    }

    @Test
    fun viewPastCapDropsOldestButKeepsPagedIn() {
        val log = LiveLog((0 until 3).map { text("$it", "$it") }, older = false, cap = 5)
        val view = LiveView(epoch = log.epoch, cap = 3).catchUpAll(log)
        assertFalse(view.older)
        follow(log, listOf(log.upsert(text("3", "3")), log.upsert(text("4", "4"))), view)
        assertEquals(listOf("2", "3", "4"), view.items.map { it.id })
        assertTrue(view.older, "the Mac has the rest")
        follow(log, log.addOlder(listOf(text("a", "a")), more = false), view)
        assertEquals("a", view.items.first().id, "asked for, so it stays")
        follow(log, listOf(log.upsert(text("5", "5"))), view)
        assertEquals(listOf("3", "4", "5"), view.items.map { it.id })
    }

    @Test
    fun diskCacheKeepsNewest() {
        val log = LiveLog((0 until 10).map { text("$it", "$it") }, older = false)
        val view = LiveView(epoch = log.epoch).catchUpAll(log)
        val back = LiveView.fromJson(jsonDecode(jsonEncode(view.toJson(keep = 4))).obj!!)
        assertEquals(listOf("6", "7", "8", "9"), back.items.map { it.id })
        assertTrue(back.older)
        assertEquals(view.seq, back.seq)
        // A cached view still follows the live ops.
        follow(log, listOf(log.upsert(text("10", "x"))), back)
        assertEquals("10", back.items.last().id)
    }

    @Test
    fun jsonBytesIsWhatTextTakesInJson() {
        for (s in listOf("plain", "quote \" and \\ back", "tab\tnl\n\u0000\u001b[31m", "é中文", "😀👍🏽", "שלום", "a\u200db", "\ud800 lone")) {
            assertEquals(jsonByteLength(s.toJsonElement()) - 2, jsonBytes(s), s)
        }
    }

    @Test
    fun hugeItemIsCutTheSameForMacAndPhone() {
        val log = LiveLog(emptyList(), older = false)
        val huge = "中文 ok 😀 \u001b[1m\"".repeat(40000)
        val ops = buildList {
            add(log.upsert(text("u", huge, ItemKind.user)))
            add(log.upsert(text("a", "")))
            for (i in 0 until 300) log.append("a", "$i ${"x".repeat(500)}\n")?.let { add(it) }
            add(log.upsert(LiveItem(id = "t", kind = ItemKind.tool, tool = "bash", args = "y".repeat(100000), output = "z".repeat(100000) + "END")))
        }
        val view = follow(log, ops)
        for (i in log.items) assertTrue(jsonByteLength(i.toJson()) < maxItemTextBytes + 32 * 1024, i.id)
        assertTrue(log.items[0].text.startsWith("中文 ok 😀"))
        assertTrue(log.items[0].text.endsWith(cutNote))
        assertTrue(log.items[1].text.endsWith(cutNote), "streamed text stops at the cap")
        assertTrue(log.items[2].output.endsWith("END"), "a tool's output keeps its end")
        fun texts(i: LiveItem) = jsonEncode(listOf(i.id, i.text, i.args, i.output).toJsonElement())
        assertEquals(log.items.map(::texts), view.items.map(::texts))
        // What a catch-up sends: every chunk under the server's frame once sealed.
        for (chunk in chunkJson(log.items.map { it.toJson() })) {
            assertTrue(jsonByteLength(chunk.toJsonElement()) * 4 / 3 < 256 * 1024)
        }
    }

    // answerKeys

    private val db = LiveQuestion(id = "db", question = "Database?", options = listOf("SQLite", "Postgres", "MySQL"))

    private fun ask(vararg qs: LiveQuestion) = LiveAsk.questions("call", qs.toList())

    private fun flat(steps: List<KeyStep>, wait: String = "wait") = steps.map {
        when (it) {
            is Keys -> it.keys.joinToString(" ")
            is Typed -> "type:${it.text}"
            Settle -> wait
        }
    }

    private fun to(row: Int, rows: Int) = (List(rows) { "up" } + List(row) { "down" }).joinToString(" ")

    @Test
    fun singleChoice() {
        assertEquals(listOf("${to(1, 4)} enter"), flat(answerKeys(ask(db), answers = listOf(LiveAnswer(picks = listOf(1))))))
    }

    @Test
    fun typedAnswer() {
        assertEquals(
            listOf("${to(3, 4)} enter", "wait", "type:DuckDB", "enter", "wait"),
            flat(answerKeys(ask(db), answers = listOf(LiveAnswer(custom = " DuckDB ")))),
        )
    }

    @Test
    fun typedAnswersToSeveralQuestions() {
        val q2 = LiveQuestion(id = "wt", question = "Worktree?", options = listOf("Yes", "No"))
        assertEquals(
            listOf("${to(3, 4)} enter", "wait", "type:a", "enter", "wait", "${to(2, 3)} enter", "wait", "type:b", "enter", "wait", "enter"),
            flat(answerKeys(ask(db, q2), answers = listOf(LiveAnswer(custom = "a"), LiveAnswer(custom = "b")))),
        )
    }

    @Test
    fun multipleChoiceTogglesWithSpace() {
        val q = LiveQuestion(id = "f", question = "Features?", options = listOf("a", "b", "c"), multi = true)
        assertEquals(listOf("${to(0, 4)} space ${to(2, 4)} space enter"), flat(answerKeys(ask(q), answers = listOf(LiveAnswer(picks = listOf(0, 2))))))
    }

    @Test
    fun loneMultipleChoiceWithTypedEndsOnSubmit() {
        val q = LiveQuestion(id = "f", question = "Features?", options = listOf("a"), multi = true)
        assertEquals(
            listOf("${to(0, 2)} space ${to(1, 2)} enter", "wait", "type:z", "enter", "wait", "enter"),
            flat(answerKeys(ask(q), answers = listOf(LiveAnswer(picks = listOf(0), custom = "z")))),
        )
    }

    @Test
    fun severalQuestionsThenSubmit() {
        val q2 = LiveQuestion(id = "os", question = "OS?", options = listOf("mac", "linux"))
        assertEquals(
            listOf("${to(2, 4)} enter ${to(0, 3)} enter", "wait", "enter"),
            flat(answerKeys(ask(db, q2), answers = listOf(LiveAnswer(picks = listOf(2)), LiveAnswer(picks = listOf(0))))),
        )
    }

    @Test
    fun ompApproval() {
        val a = LiveAsk.approval("call", tool = "bash")
        assertEquals(listOf("enter"), flat(answerKeys(a, approve = true)))
        assertEquals(listOf("down enter"), flat(answerKeys(a)))
    }

    @Test
    fun answersTheDialogCannotTakeAreRefused() {
        assertFailsWith<IllegalArgumentException> { answerKeys(ask(db), answers = emptyList()) }
        assertFailsWith<IllegalArgumentException> { answerKeys(ask(db), answers = listOf(LiveAnswer(picks = listOf(3)))) }
        assertFailsWith<IllegalArgumentException> { answerKeys(ask(db), answers = listOf(LiveAnswer(picks = listOf(0, 1)))) }
        assertFailsWith<IllegalArgumentException> { answerKeys(ask(db), answers = listOf(LiveAnswer(custom = "  "))) }
        assertFailsWith<IllegalArgumentException> { answerKeys(LiveAsk.plan("p")) }
    }

    // askOnScreen

    @Test
    fun questionWrappedAndStyled() {
        val q = LiveQuestion(id = "x", question = "Which **storage** backend should the sync layer use?", options = listOf("a"))
        val screen = "│ Which storage backend should\n│ the sync layer use?\n│ > a"
        assertTrue(askOnScreen(LiveAsk.questions("c", listOf(q)), screen.replace("│", "")))
        assertFalse(askOnScreen(LiveAsk.questions("c", listOf(q)), "π > waiting for input"))
    }

    @Test
    fun approvalNeedsBothButtons() {
        val a = LiveAsk.approval("c", tool = "bash")
        assertTrue(askOnScreen(a, "Run bash?\n> Approve\n  Deny"))
        assertFalse(askOnScreen(a, "Approve the plan"))
    }

    @Test
    fun planReviewRecognisedByHeader() {
        val plan = LiveAsk.plan("c", title = "notes")
        assertTrue(askOnScreen(plan, planScreen()))
        assertTrue(askOnScreen(plan, planScreen(help = "↑/↓ scroll · a annotate · ⇥ regions")))
        assertFalse(askOnScreen(plan, "π > waiting for input\n  plan the next release"))
    }

    // plan review

    @Test
    fun readsOptionsPastSliderAndWrappedRow() {
        val review = parsePlanReview(planScreen())
        assertEquals(
            listOf(
                "Approve and execute",
                "Approve and compact context",
                "Approve and keep context (~47k / 1m) — then save every draft note as it changes",
                "Refine plan",
                "Save and quit",
            ),
            review?.options,
        )
        assertEquals(2, review?.current)
    }

    @Test
    fun readsReviewWithoutSlider() {
        val screen = planScreen(slider = false, cursor = 4, long = false)
        assertEquals(5, parsePlanReview(screen)?.options?.size)
        assertEquals(4, parsePlanReview(screen)?.current)
    }

    @Test
    fun reviewNotReadWithoutFocus() {
        assertNull(parsePlanReview(planScreen(help = "↑/↓ scroll · a annotate · ⇥ regions")))
        assertNull(parsePlanReview(planScreen(help = "Applying your selection — this can take a moment.")))
        assertNull(parsePlanReview("π > waiting for input\n↑/↓ select"))
    }

    @Test
    fun menuKeysMove() {
        assertEquals(listOf("down", "down", "enter"), menuKeys(1, 3))
        assertEquals(listOf("up", "up", "up", "enter"), menuKeys(3, 0))
        assertEquals(listOf("enter"), menuKeys(2, 2))
        assertEquals(listOf("up", "up", "up"), menuKeys(4, 1, enter = false))
        assertFailsWith<IllegalArgumentException> { menuKeys(2, -1) }
        assertFailsWith<IllegalArgumentException> { menuKeys(-1, 0) }
        assertEquals(listOf("enter"), menuKeys(0, 0))
    }

    @Test
    fun planAskThroughJson() {
        val ask = LiveAsk.plan("call", title = "notes-plan", options = listOf("Approve and execute", "Refine plan"), selected = 1)
        val back = LiveAsk.fromJson(jsonDecode(jsonEncode(ask.toJson())).obj!!)
        assertTrue(back.isPlan)
        assertEquals("call", back.id)
        assertEquals("notes-plan", back.title)
        assertEquals(ask.options, back.options)
        assertEquals(1, back.selected)
        assertEquals("Plan ready: notes-plan", back.text)
        // The extension sends a plan without options; the Mac reads them off the screen.
        val bare = LiveAsk.fromJson(jsonOf("kind" to "plan", "id" to "x", "title" to "notes-plan"))
        assertTrue(bare.isPlan)
        assertTrue(bare.options.isEmpty())
    }

    // pickers

    private val resume = """
 Resume Session (current folder)

 > █

 ❯ Build kitty socket client and live protoc…
   i want you to review our WHOLE terminal f…
   3 minutes ago  ·  5.2MB  ·  ✔ done

   Check if mobile app rebuild needed
   we did bunch of changes to this app, do i…
   1 day ago  ·  239.3KB  ·  ✔ done

   Fix popup notes
   2 days ago  ·  12.1KB
   …
 [⌦/⌫ delete · ⏎ select · ⇥ all projects · esc cancel]""".removePrefix("\n")

    @Test
    fun resumeOneItemPerBlock() {
        val menu = parseMenu(resume)
        assertEquals("Resume Session (current folder)", menu?.title)
        assertEquals(true, menu?.filter)
        assertEquals(0, menu?.current)
        assertEquals(
            listOf(
                MenuItem("Build kitty socket client and live protoc…", "i want you to review our WHOLE terminal f… · 3 minutes ago · 5.2MB · ✔ done"),
                MenuItem("Check if mobile app rebuild needed", "we did bunch of changes to this app, do i… · 1 day ago · 239.3KB · ✔ done"),
                MenuItem("Fix popup notes", "2 days ago · 12.1KB"),
            ),
            menu?.items,
        )
    }

    @Test
    fun resumeInItsBox() {
        fun row(s: String) = "│ ${s.padEnd(54)}${if (s.startsWith("  ")) "█" else "│"} │"
        val screen = listOf(
            "π  earlier answer in the transcript",
            "╭─ Resume Session (current folder) ───────────────────────╮",
            row("> fix"), row(""), row("  Build kitty socket client"), row("  3 minutes ago  ·  5.2MB"), row(""),
            row("❯ Fix popup notes"), row("  2 days ago  ·  12.1KB"), row(""),
            row("[⌦/⌫ delete · ⏎ select · ⇥ all projects · esc cancel]"),
            "╰${"─".repeat(58)}╯",
        ).joinToString("\n")
        val menu = parseMenu(screen)
        assertEquals("Resume Session (current folder)", menu?.title)
        assertEquals(true, menu?.filter)
        assertEquals(1, menu?.current)
        assertEquals(listOf("Build kitty socket client", "Fix popup notes"), menu?.items?.map { it.label })
        assertEquals("2 days ago · 12.1KB", menu?.items?.last()?.detail)
    }

    @Test
    fun simplePicker() {
        val screen = """
π  Theme changed.

 Select theme

   dark
   light       the default
 ❯ solarized
   nord
   (3/4)  Type to search

 ↑/↓ navigate  ⏎ select  esc cancel""".removePrefix("\n")
        val menu = parseMenu(screen)
        assertEquals("Select theme", menu?.title)
        assertEquals(2, menu?.current)
        assertEquals(true, menu?.filter)
        assertEquals(listOf(MenuItem("dark", ""), MenuItem("light", "the default"), MenuItem("solarized", ""), MenuItem("nord", "")), menu?.items)
    }

    @Test
    fun promptAndPlanReviewAreNotPickers() {
        val prompt = """
π  Done: the popup keeps its notes now.
   > ran 3 tests

╭──────────────────────────────────────────────────────────╮
│ > █                                                        │
╰──────────────────────────────────────────────────────────╯
  opus-4.5 · 12% · ~/Dev/pocketterm""".removePrefix("\n")
        assertNull(parseMenu(prompt))
        assertNull(parseMenu(planScreen()))
    }

    @Test
    fun claudeTranscriptPromptsAreNotPickersItsModelIs() {
        // Its prompt line is ❯ and a no-break space, under the transcript's `❯ ` prompts.
        val idle = "⏺ pong\n\n› Prompt from the pocketterm plugin\n❯ Reply just: Q3OK\n\n⏺ Q3OK\n" +
            "────────────────────────────────────────\n❯\u00a0\n────────────────────────────────────────\n  ⏸ manual mode on · ? for shortcuts"
        assertNull(parseMenu(idle))
        val model = "❯ Reply just: Q3OK\n▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔\n   Select model\n\n" +
            "   ❯ 1.  Default (recommended) ✔  Opus 5.5\n     2.  Sonnet 5.5               Most efficient\n\n   Enter to set as default · Esc to cancel"
        val menu = parseMenu(model)
        assertEquals("Select model", menu?.title)
        assertEquals(0, menu?.current)
        assertEquals(listOf("1. Default (recommended) ✔", "2. Sonnet 5.5"), menu?.items?.map { it.label })
    }

    @Test
    fun pickerOnScreenWhileItsTitleIs() {
        assertTrue(askOnScreen(LiveAsk.menu("m1", title = "Resume Session (current folder)", items = emptyList()), resume))
        assertFalse(askOnScreen(LiveAsk.menu("m1", title = "Select theme", items = emptyList()), resume))
    }

    @Test
    fun pickerThroughJson() {
        val ask = LiveAsk.menu("menu-3", title = "Select model", items = listOf(MenuItem("opus", "Anthropic · 200k"), MenuItem("gpt-5", "")), selected = 1, filter = true)
        val back = LiveAsk.fromJson(jsonDecode(jsonEncode(ask.toJson())).obj!!)
        assertTrue(back.isMenu)
        assertEquals("menu-3", back.id)
        assertEquals("Select model", back.title)
        assertEquals(ask.items, back.items)
        assertEquals(1, back.selected)
        assertTrue(back.filter)
        assertEquals("Select model", back.text)
    }

    // ScreenDiff

    private fun lines(from: Int, to: Int) = (from until to).map { "line $it" }

    @Test
    fun scrolledOutputCostsOnlyNewLines() {
        val a = lines(0, 100)
        val b = lines(5, 100) + lines(100, 105)
        val d = ScreenDiff.between(a, b)!!
        assertEquals(Triple(5, 95, 5), Triple(d.drop, d.keep, d.tail.size))
        assertEquals(b, d.apply(a))
    }

    @Test
    fun redrawnBottomFromFirstChangedLine() {
        val a = lines(0, 50)
        val b = lines(0, 45) + listOf("x", "y")
        val d = ScreenDiff.between(a, b)!!
        assertEquals(listOf("x", "y"), d.tail)
        assertEquals(b, d.apply(a))
    }

    @Test
    fun unrelatedScreenGoesWholeAndWrongBaseIsRefused() {
        assertNull(ScreenDiff.between(lines(0, 10), lines(50, 60)))
        assertNull(ScreenDiff.between(lines(0, 100), lines(10, 110))!!.apply(lines(0, 20)))
    }

    // summaries and commands

    @Test
    fun summaryProfileThroughJson() {
        val s = LiveSummary(key = "k", id = "s", title = "", cwd = "/x", epoch = "e", seq = 1, profile = "personal")
        assertEquals("personal", s.toJson()["profile"].str)
        assertEquals("personal", LiveSummary.fromJson(jsonDecode(jsonEncode(s.toJson())).obj!!).profile)
        assertFalse("profile" in LiveSummary(key = "k", id = "s", title = "", cwd = "/x", epoch = "e", seq = 1).toJson())
        assertEquals("", LiveSummary.fromJson(jsonOf("key" to "k")).profile)
    }

    private val commands = listOf(
        LiveCommand("model", "Switch model for this session"),
        LiveCommand("new", "Start a new session"),
        LiveCommand("compact", "Manually compact the session context"),
        LiveCommand("plan-review", ""),
        LiveCommand("plan", "Toggle plan mode"),
        LiveCommand("skill:Pdf", "Read PDFs"),
    )

    private fun names(text: String, max: Int = 6) = matchCommands(commands, text, max).map { it.name }

    @Test
    fun summaryKeepsCommands() {
        val s = LiveSummary(key = "k", id = "s", title = "", cwd = "/x", epoch = "e", seq = 1, commands = commands)
        assertEquals(commands, LiveSummary.fromJson(jsonDecode(jsonEncode(s.toJson())).obj!!).commands)
        assertTrue(LiveSummary.fromJson(jsonOf("key" to "k")).commands.isEmpty())
    }

    @Test
    fun commandMatching() {
        assertEquals(listOf("plan-review", "plan", "compact", "skill:Pdf"), names("/p"))
        assertEquals(listOf("plan-review", "plan"), names("/PL"))
        assertEquals(listOf("new", "plan-review", "plan"), names("/n"))
        assertEquals(listOf("model", "new", "compact"), names("/", max = 3))
        for (t in listOf("/new ", "/compact keep the API", "new", "/zzz")) assertTrue(names(t).isEmpty(), t)
    }

    @Test
    fun chunkJsonKeepsChunksUnderLimitAndLosesNothing() {
        val items = (0 until 50).map { jsonOf("id" to "$it", "t" to "x".repeat(900)) }
        val chunks = chunkJson(items, maxBytes = 5000)
        assertTrue(chunks.size > 1)
        for (c in chunks) assertTrue(jsonByteLength(c.toJsonElement()) < 5000 + 100)
        assertEquals(items, chunks.flatten())
    }

    // Claude Code dialogs (read off and tried on Claude Code 2.1.296 in kitty)

    private val color = LiveQuestion(id = "", question = "Which color should the button be?", options = listOf("Red", "Blue", "Green"))
    private val sizes = LiveQuestion(id = "", question = "Which sizes do you want?", options = listOf("Small", "Medium", "Large"), multi = true)

    @Test
    fun claudeSingleQuestion() {
        val ask = LiveAsk.questions("t1", listOf(color))
        assertEquals(listOf("2"), flat(answerKeys(ask, answers = listOf(LiveAnswer(picks = listOf(1))), agent = Agent.claude)))
        assertEquals(
            listOf("4", "settle", "type:Purple", "settle", "enter"),
            flat(answerKeys(ask, answers = listOf(LiveAnswer(custom = "Purple")), agent = Agent.claude), "settle"),
        )
    }

    @Test
    fun claudeMultipleChoice() {
        assertEquals(
            listOf("3", "settle", "1 3 down down down down enter", "settle", "1"),
            flat(answerKeys(LiveAsk.questions("t2", listOf(color, sizes)), answers = listOf(LiveAnswer(picks = listOf(2)), LiveAnswer(picks = listOf(0, 2))), agent = Agent.claude), "settle"),
        )
        assertEquals(
            listOf("2 4 down down down", "settle", "type:Huge", "settle", "down enter", "settle", "1"),
            flat(answerKeys(LiveAsk.questions("t3", listOf(sizes)), answers = listOf(LiveAnswer(picks = listOf(1), custom = "Huge")), agent = Agent.claude), "settle"),
        )
    }

    @Test
    fun claudeApproval() {
        val ask = LiveAsk.approval("t4", tool = "Bash", summary = "touch made-by-fake.txt")
        assertEquals(listOf("1"), flat(answerKeys(ask, approve = true, agent = Agent.claude)))
        assertEquals(listOf("esc"), flat(answerKeys(ask, agent = Agent.claude)))
        val screen = """
 Bash command
 Create a marker file
 touch made-by-fake.txt
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /private/tmp/work from this project
   3. No
 Esc to cancel · Tab to amend""".removePrefix("\n")
        assertTrue(askOnScreen(ask, screen, agent = Agent.claude))
        assertFalse(askOnScreen(ask, "❯ say hello\n⏺ Hello.", agent = Agent.claude))
    }

    @Test
    fun claudePlanReview() {
        val screen = """
 Ready to code?
 Here is Claude's plan:
 Paint the button
 1. Pick a color
 2. Paint it
 Claude has written up a plan and is ready to execute. Would you like to proceed?
 ❯ 1. Yes, auto-accept edits
   2. Yes, manually approve edits
   3. Tell Claude what to change
      shift+tab to approve with this feedback
 ctrl+g to edit in True · /tmp/plans/paint.md""".removePrefix("\n")
        val review = assertNotNull(parsePlanReview(screen, agent = Agent.claude))
        assertEquals(listOf("Yes, auto-accept edits", "Yes, manually approve edits", "Tell Claude what to change"), review.options)
        assertEquals(0, review.current)
        assertTrue(askOnScreen(LiveAsk.plan("t5"), screen, agent = Agent.claude))
        val exit = assertNotNull(parsePlanReview(" Exit plan mode?\n Claude wants to exit plan mode\n   1. Yes\n ❯ 2. No", agent = Agent.claude))
        assertEquals(listOf("Yes", "No"), exit.options)
        assertEquals(1, exit.current)
        assertNull(parsePlanReview(screen))
    }

    // fuzz_test.dart: the extension's commands of any shape never throw.

    private fun randomJson(r: Random, depth: Int = 0): JsonElement = when (if (depth > 3) r.nextInt(4) else r.nextInt(7)) {
        0 -> JsonNull
        1 -> r.nextBoolean().toJsonElement()
        2 -> (r.nextInt(2000) - 1000).toJsonElement()
        3 -> listOf("", "name", "description", "model", "😀").random(r).toJsonElement()
        4 -> (0 until r.nextInt(4)).map { randomJson(r, depth + 1) }.toJsonElement()
        else -> JsonObject((0 until r.nextInt(4)).associate { listOf("name", "description", "x").random(r) to randomJson(r, depth + 1) })
    }

    @Test
    fun liveCommandsOfAnyShape() {
        val r = Random(7)
        repeat(2000) { liveCommands(randomJson(r)) }
        assertEquals(listOf(LiveCommand("a", "")), liveCommands(jsonDecode("""[{"name":"a","description":5},{"name":3},"x"]""")))
    }

    /**
     * omp's plan review as kitty's plain text shows it [width] columns wide: the plan in a rounded
     * box, then the "next step" prompt, the model slider, the options (cursor on [cursor]) and the
     * help line. Rows too wide for the terminal wrap onto the next line, as they do in kitty.
     */
    private fun planScreen(
        width: Int = 60,
        cursor: Int = 2,
        slider: Boolean = true,
        long: Boolean = true,
        help: String = "↑/↓ select · ⏎ confirm · ←/→ model · c copy · ⇥ regions · esc cancel",
    ): String {
        val options = listOf(
            "Approve and execute",
            "Approve and compact context",
            if (long) "Approve and keep context (~47k / 1m) — then save every draft note as it changes" else "Approve and keep context (~47k / 1m)",
            "Refine plan",
            "Save and quit",
        )
        val inner = width - 4
        val out = mutableListOf("╭─ Plan Review ${"─".repeat(width - 17)}╮")
        fun row(content: String) {
            val line = "│ ${content.padEnd(inner)} │"
            var i = 0
            while (i < line.length) {
                out.add(line.substring(i, minOf(i + width, line.length)))
                i += width
            }
        }
        listOf("# Notes plan", "", "1. Read the notes store", "2. Save drafts on close", "").forEach(::row)
        out.add("├${"─".repeat(width - 2)}┤")
        row("Plan mode - next step")
        if (slider) {
            row("continue with  ◂  smol │ default │ slow  ▸")
            row("  ↳ Claude Sonnet 4.5")
        }
        options.forEachIndexed { i, o -> row("${if (i == cursor) "❯" else " "} $o") }
        out.add("├${"─".repeat(width - 2)}┤")
        row(help)
        out.add("╰${"─".repeat(width - 2)}╯")
        return out.joinToString("\n")
    }
}
