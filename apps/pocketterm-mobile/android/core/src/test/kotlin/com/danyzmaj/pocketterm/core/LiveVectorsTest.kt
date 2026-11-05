package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Every case of the vectors' `live` section (tool/vectors/README.md), except the terminal slice's TermWindow/TermStatus models. */
class LiveVectorsTest {
    private val live = Vectors.section("live")

    private fun cases(key: String): List<JsonObject> = live[key].arr!!.map { it.obj!! }
    private fun JsonElement?.objs(): List<JsonObject> = this.arr!!.map { it.obj!! }
    private fun JsonElement?.strs(): List<String> = this.arr!!.map { it.str!! }
    private fun note(c: JsonObject) = c["note"].str ?: ""

    /** Same JSON, byte for byte as Dart encodes it. */
    private fun assertJson(expected: JsonElement?, actual: JsonElement?, message: String) =
        assertEquals(jsonEncode(expected ?: JsonNull), jsonEncode(actual ?: JsonNull), message)

    private fun agentOf(c: JsonObject) = Agent.parse(c["agent"])

    @Test
    fun routedKeys() {
        for (c in cases("routedKey")) assertEquals(c["routed"].str, routedKey(c["desktop"].str!!, c["key"].str!!), note(c))
        for (c in cases("splitRoutedKey")) {
            val r = splitRoutedKey(c["input"].str!!)
            val want = c["result"].obj
            if (want == null) assertNull(r, note(c)) else assertEquals(RoutedKey(want["desktop"].str!!, want["key"].str!!), r, note(c))
        }
    }

    @Test
    fun jsonBytesCases() {
        for (c in cases("jsonBytes")) {
            val s = c["input"].str ?: String(c["utf16"].arr!!.map { it.int!!.toChar() }.toCharArray())
            assertEquals(c["utf16"].arr!!.map { it.int!! }, s.map { it.code }, note(c))
            assertEquals(c["bytes"].int, jsonBytes(s), note(c))
        }
    }

    @Test
    fun chunkJsonCases() {
        for (c in cases("chunkJson")) {
            val chunks = chunkJson(c["items"].objs(), maxBytes = c["maxBytes"].int!!)
            assertJson(c["chunks"], chunks.toJsonElement(), note(c))
        }
        assertEquals(live["constants"].obj!!["chunkJsonDefaultMaxBytes"].int, 40000)
    }

    @Test
    fun constants() {
        val k = live["constants"].obj!!
        assertEquals(k["cutNote"].str, cutNote)
        assertEquals(k["maxItemTextBytes"].int, maxItemTextBytes)
        assertEquals(k["maxOutputBytes"].int, maxOutputBytes)
        assertEquals(k["maxArgsBytes"].int, maxArgsBytes)
        assertEquals(k["maxTitleBytes"].int, maxTitleBytes)
        assertEquals(k["logCap"].int, LiveLog(emptyList(), older = false).cap)
        assertEquals(k["viewCap"].int, LiveView(epoch = "e").cap)
        // The cache's default keep: a view of more items than that keeps exactly that many.
        val keep = k["viewCacheKeep"].int!!
        val view = LiveView(epoch = "e", items = (0 until keep + 5).map { LiveItem(id = "$it", kind = ItemKind.user, order = it.toLong()) })
        assertEquals(keep, view.toJson()["items"].arr!!.size)
    }

    /** An input item with its repeated strings expanded. */
    private fun expand(o: JsonObject): JsonObject =
        JsonObject(o.mapValues { (_, v) -> if (v is JsonObject && v["repeat"] != null) Vectors.text(v)!!.toJsonElement() else v })

    @Test
    fun clip() {
        for (c in live["clip"].obj!!["cases"].objs()) {
            val log = LiveLog(emptyList(), older = false)
            if (c["input"] != null) {
                log.upsert(LiveItem.fromJson(expand(c["input"].obj!!)))
                val i = log.items.single()
                for ((field, value) in listOf("text" to i.text, "title" to i.title, "args" to i.args, "output" to i.output)) {
                    assertTrue(Vectors.matches(c[field], value), "${note(c)}: $field")
                }
            } else {
                log.upsert(LiveItem(id = "a", kind = ItemKind.assistant))
                val ops = (0 until 140).map { log.append("a", "$it " + "x".repeat(500) + "\n") }
                val nonNull = ops.filterNotNull()
                assertEquals(c["appendsNonNull"].int, nonNull.size, note(c))
                assertTrue(ops.dropWhile { it != null }.all { it == null }, "later appends return null")
                val last = nonNull.last()
                val want = c["lastNonNullOp"].obj!!
                assertEquals(want["s"].long, last.seq)
                assertEquals(want["id"].str, last.id)
                assertTrue(Vectors.matches(want["a"], last.append!!), "last append")
                assertTrue(Vectors.matches(c["text"], log.items.single().text), "${note(c)}: text")
            }
        }
    }

    @Test
    fun logScenario() {
        val sc = live["logScenario"].obj!!
        val log = LiveLog(sc["snapshot"].objs().map { LiveItem.fromJson(it) }, older = false, epoch = "e1")
        assertJson(sc["snapshotStored"], log.items.map { it.toJson() }.toJsonElement(), "snapshot")
        val wire = mutableListOf<LiveOp>()
        for (step in sc["steps"].objs()) {
            val a = step["action"].obj!!
            val ops: List<LiveOp?> = when {
                a["upsert"] != null -> listOf(log.upsert(LiveItem.fromJson(a["upsert"].obj!!)))
                a["append"] != null -> listOf(log.append(a["append"].obj!!["id"].str!!, a["append"].obj!!["text"].str!!))
                else -> log.addOlder(a["addOlder"].obj!!["items"].objs().map { LiveItem.fromJson(it) }, more = a["addOlder"].obj!!["more"].bool!!)
            }
            assertJson(step["ops"], ops.map { it?.toJson() }.toJsonElement(), note(step))
            wire += ops.filterNotNull()
        }
        assertEquals(sc["finalSeq"].long, log.seq)
        assertEquals(sc["finalOlder"].bool, log.older)
        assertJson(sc["finalItems"], log.items.map { it.toJson() }.toJsonElement(), "finalItems")
        assertJson(sc["since3"], log.since(3).map { it.toJson() }.toJsonElement(), "since3")

        // The phone: caught up on the snapshot, then fed every op through JSON.
        fun viewAt(epoch: String) = LiveView(epoch = epoch).apply {
            catchUp(epoch = epoch, seq = 1, reset = true, items = sc["snapshotStored"].objs().map { LiveItem.fromJson(it) }, last = true)
        }
        val ops = wire.map { LiveOp.fromJson(jsonDecode(jsonEncode(it.toJson())).obj!!) }
        val all = viewAt("e1")
        val applyAll = sc["viewApplyAll"].obj!!
        assertEquals(applyAll["result"].bool, all.apply("e1", ops))
        assertJson(applyAll["view"], all.toJson(), "viewApplyAll")
        assertEquals(sc["viewApplyWithGap"].obj!!["result"].bool, viewAt("e1").apply("e1", ops.drop(1)))
        assertEquals(sc["viewApplyOtherEpoch"].obj!!["result"].bool, viewAt("e0").apply("e1", ops))
    }

    @Test
    fun viewCatchUp() {
        val v = live["viewCatchUp"].obj!!
        val init = v["initial"].obj!!
        val view = LiveView(epoch = init["epoch"].str!!, seq = init["seq"].long!!, items = init["items"].objs().map { LiveItem.fromJson(it) })
        for (step in v["steps"].objs()) {
            val c = step["catchUp"].obj!!
            view.catchUp(
                epoch = c["epoch"].str!!, seq = c["seq"].long!!, reset = c["reset"].bool!!,
                items = c["items"].objs().map { LiveItem.fromJson(it) }, last = c["last"].bool!!, older = c["older"].bool,
            )
            assertJson(step["view"], view.toJson(), note(step))
        }
    }

    @Test
    fun commands() {
        for (c in cases("liveCommands")) {
            assertJson(c["commands"], liveCommands(c["input"]).map { jsonOf("name" to it.name, "description" to it.description) }.toJsonElement(), note(c))
        }
        val m = live["matchCommands"].obj!!
        val commands = m["commands"].objs().map { LiveCommand(it["name"].str!!, it["description"].str!!) }
        for (c in m["cases"].objs()) {
            assertEquals(c["names"].strs(), matchCommands(commands, c["text"].str!!, max = c["max"].int!!).map { it.name }, note(c))
        }
    }

    private fun stepJson(s: KeyStep): JsonObject = when (s) {
        is Keys -> jsonOf("keys" to s.keys)
        is Typed -> jsonOf("type" to s.text)
        Settle -> jsonOf("settle" to true)
    }

    @Test
    fun answerKeysCases() {
        for (c in live["answerKeys"].obj!!["cases"].objs()) {
            val ask = LiveAsk.fromJson(c["ask"].obj!!)
            val answers = c["answers"].objs().map { LiveAnswer.fromJson(it) }
            val run = { answerKeys(ask, answers = answers, approve = c["approve"].bool == true, agent = agentOf(c)) }
            if (c["steps"].str == "error") {
                assertFailsWith<IllegalArgumentException>(note(c)) { run() }
            } else {
                assertJson(c["steps"], run().map { stepJson(it) }.toJsonElement(), note(c))
            }
        }
    }

    @Test
    fun menuKeysAndRows() {
        for (c in cases("menuKeys")) {
            val run = { menuKeys(c["current"].int!!, c["target"].int!!, enter = c["enter"].bool != false) }
            if (c["keys"].str == "error") assertFailsWith<IllegalArgumentException>(note(c)) { run() }
            else assertEquals(c["keys"].strs(), run(), note(c))
        }
        for (c in cases("claudeRowKey")) assertEquals(c["key"].str, claudeRowKey(c["row"].int!!), note(c))
    }

    @Test
    fun planReviews() {
        for (c in cases("parsePlanReview")) {
            val r = parsePlanReview(c["screen"].str!!, agent = agentOf(c))
            val want = c["result"].obj
            if (want == null) assertNull(r, note(c))
            else assertEquals(PlanReview(want["options"].strs(), want["current"].int!!), r, note(c))
        }
    }

    @Test
    fun menus() {
        for (c in cases("parseMenu")) {
            val r = parseMenu(c["screen"].str!!)
            val want = c["result"].obj
            if (want == null) {
                assertNull(r, note(c))
            } else {
                assertNotNull(r, note(c))
                assertEquals(
                    Menu(want["title"].str!!, want["items"].objs().map { MenuItem(it["label"].str!!, it["detail"].str!!) }, want["current"].int!!, want["filter"].bool!!),
                    r, note(c),
                )
            }
        }
    }

    @Test
    fun asksOnScreen() {
        for (c in cases("askOnScreen")) {
            assertEquals(c["onScreen"].bool, askOnScreen(LiveAsk.fromJson(c["ask"].obj!!), c["screen"].str!!, agent = agentOf(c)), note(c))
        }
    }

    @Test
    fun screenDiffs() {
        val sd = live["screenDiff"].obj!!
        for (c in sd["between"].objs()) {
            val a = c["a"].strs()
            val d = ScreenDiff.between(a, c["b"].strs())
            assertJson(c["diff"], d?.toJson(), note(c))
            if (d != null) assertJson(c["applied"], d.apply(a).toJsonElement(), note(c))
        }
        for (c in sd["apply"].objs()) {
            assertJson(c["result"], ScreenDiff.fromJson(c["diff"].obj!!).apply(c["a"].strs()).toJsonElement(), note(c))
        }
    }

    @Test
    fun models() {
        val m = live["models"].obj!!
        val parsers: Map<String, (JsonElement?) -> JsonElement> = mapOf(
            "LiveItem" to { j -> LiveItem.fromJson(j.obj!!).toJson() },
            "LiveQueued" to { j -> LiveQueued.fromJson(j.obj!!).toJson() },
            "LiveOp" to { j -> LiveOp.fromJson(j.obj!!).toJson() },
            "LiveAsk" to { j -> LiveAsk.fromJson(j.obj!!).toJson() },
            "LiveAnswer" to { j -> LiveAnswer.fromJson(j.obj!!).toJson() },
            "LiveSummary" to { j -> LiveSummary.fromJson(j.obj!!).toJson() },
            "ScreenDiff" to { j -> ScreenDiff.fromJson(j.obj!!).toJson() },
            "AgentIntegration" to { j -> AgentIntegration.toJsonAll(AgentIntegration.parseAll(j)) },
        )
        // TermWindow and TermStatus belong to the terminal slice (TerminalVectorsTest).
        assertEquals(parsers.keys + setOf("LiveView", "TermWindow", "TermStatus", "note"), m.keys)
        for ((name, parse) in parsers) {
            for (c in m[name].objs()) {
                assertJson(c["output"], parse(c["input"]), "$name: ${note(c)}")
                if (name == "LiveAsk") assertEquals(c["text"].str, LiveAsk.fromJson(c["input"].obj!!).text, note(c))
            }
        }
        for (c in m["LiveView"].objs()) {
            val v = LiveView.fromJson(c["input"].obj!!)
            assertJson(c["output"], c["keep"].int?.let { v.toJson(keep = it) } ?: v.toJson(), "LiveView: ${note(c)}")
        }
    }

    @Test
    fun agents() {
        val a = live["agent"].obj!!
        for (c in a["agents"].objs()) {
            val agent = Agent.entries.single { it.name == c["name"].str }
            assertEquals(c["label"].str, agent.label)
            assertEquals(c["command"].str, agent.command)
            assertEquals(c["steers"].bool, agent.steers)
            assertEquals(c["resume"].str, agent.resume)
            assertEquals(c["pickUp"].str, agent.pickUp)
            for ((p, v) in c["commandIn"].obj!!) assertEquals(v.str, agent.commandIn(p), "commandIn $p")
            for ((p, v) in c["labelIn"].obj!!) assertEquals(v.str, agent.labelIn(p), "labelIn $p")
            for ((p, v) in c["resumeIn"].obj!!) assertEquals(v.str, agent.resumeIn(p), "resumeIn $p")
            for ((p, v) in c["pickUpIn"].obj!!) assertEquals(v.str, agent.pickUpIn(p), "pickUpIn $p")
        }
        assertEquals(a["agents"].arr!!.size, Agent.entries.size)
        for (c in a["parse"].objs()) assertEquals(c["agent"].str, Agent.parse(c["input"]).name, note(c))
        for (c in a["ofProgram"].objs()) assertEquals(c["agent"].str, Agent.ofProgram(c["input"].str!!)?.name, note(c))
        for (c in a["sessionOfTitle"].objs()) assertEquals(c["session"].str, agentOf(c).sessionOfTitle(c["title"].str!!), note(c))
        for (c in a["isOmpProfile"].objs()) assertEquals(c["ok"].bool, isOmpProfile(c["input"].str!!), note(c))
        for (c in a["ompProfileOfArgs"].objs()) assertEquals(c["profile"].str, ompProfileOfArgs(c["args"].str!!), note(c))
    }

    private fun items(e: JsonElement?) = e.objs().map { LiveItem.fromJson(it).toJson() }.toJsonElement()

    @Test
    fun channelFrames() {
        for (f in live["frames"].obj!!["channel"].objs()) {
            val p = f["payload"].obj!!
            val parsed = f["parsed"].obj ?: continue
            val got = linkedMapOf<String, JsonElement>()
            when (f["event"].str) {
                "state" -> {
                    got["sessions"] = p["sessions"].objs().map { LiveSummary.fromJson(it).toJson() }.toJsonElement()
                    got["agents"] = AgentIntegration.toJsonAll(AgentIntegration.parseAll(p["agents"]))
                    // windows/terminals: TermWindow/TermStatus, checked by the terminal slice.
                    assertEquals(setOf("windows", "sessions", "agents", "terminals"), parsed.keys, note(f))
                    assertJson(parsed["sessions"], got["sessions"], note(f))
                    assertJson(parsed["agents"], got["agents"], note(f))
                    continue
                }
                "items" -> got["items"] = items(p["items"])
                "live" -> got["ops"] = p["ops"].objs().map { LiveOp.fromJson(it).toJson() }.toJsonElement()
                else -> error("unexpected parsed channel frame ${f["event"]}")
            }
            assertJson(parsed, JsonObject(got), note(f))
        }
        // The screen frame's diff and lines read back as the phone uses them.
        val screens = live["frames"].obj!!["channel"].objs().filter { it["event"].str == "screen" }
        val whole = screens.first { it["payload"].obj!!["lines"] != null }["payload"].obj!!["lines"].strs()
        val diff = ScreenDiff.fromJson(screens.first { it["payload"].obj!!["diff"] != null }["payload"].obj!!["diff"].obj!!)
        assertEquals(listOf("\u001b[31mb\u001b[0m", "c", "d"), diff.apply(whole))
    }

    @Test
    fun localFrames() {
        var parsedCount = 0
        for (f in live["frames"].obj!!["local"].objs()) {
            val frame = f["frame"].obj!!
            val parsed = f["parsed"].obj ?: continue
            parsedCount++
            val got = linkedMapOf<String, JsonElement>()
            for (k in parsed.keys) {
                got[k] = when (k) {
                    "commands" -> liveCommands(frame["commands"]).map { jsonOf("name" to it.name, "description" to it.description) }.toJsonElement()
                    "ask" -> frame["ask"].obj?.let { LiveAsk.fromJson(it).toJson() } ?: JsonNull
                    "item" -> LiveItem.fromJson(frame["item"].obj!!).toJson()
                    else -> error("unexpected parsed key $k")
                }
            }
            assertJson(parsed, JsonObject(got), note(f))
        }
        assertTrue(parsedCount > 0)
    }
}
