package com.danyzmaj.pocketterm.core

// Answering an agent's dialogs with the keyboard, and reading its plan review and pickers off
// the plain text of its screen (port of the second half of pocketterm_core/lib/live.dart).
// Dart regexes follow JavaScript: `\s` and `trim` are Unicode-aware, `$` is the input's end
// only. The patterns below spell that out so Java's regex engine reads them the same.

/** Dart's whitespace (String.trim, RegExp `\s`). */
internal fun isDartWhitespace(c: Char): Boolean {
    val v = c.code
    return v in 9..13 || v == 0x20 || v == 0x85 || v == 0xA0 || v == 0x1680 || v in 0x2000..0x200A ||
        v == 0x2028 || v == 0x2029 || v == 0x202F || v == 0x205F || v == 0x3000 || v == 0xFEFF
}

private fun String.dartTrim(): String = trim { isDartWhitespace(it) }
private fun String.dartTrimLeft(): String = trimStart { isDartWhitespace(it) }

/** JavaScript's `\s` as a character-class body. */
private const val WS = "\\t\\n\\u000B\\f\\r \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
private const val S = "[$WS]"
private const val NS = "[^$WS]"

/** One step of answering an agent's dialog with the keyboard: keys (kitty's names) pressed, or text typed. */
sealed class KeyStep

/** Keys pressed, in order. */
data class Keys(val keys: List<String>) : KeyStep()

/** Text typed. */
data class Typed(val text: String) : KeyStep()

/**
 * Wait for the agent to redraw before the next keys: opening or closing a typed answer and
 * moving to the Submit tab take a moment, and keys sent before that are dropped.
 */
data object Settle : KeyStep()

/**
 * The keystrokes that answer [ask] in [agent]'s terminal UI (a question or an approval). A plan
 * review or a picker is answered from where its cursor is now: [menuKeys], or [claudeRowKey] for
 * Claude Code's plan review. Throws [IllegalArgumentException] for answers the dialog can't take.
 */
fun answerKeys(
    ask: LiveAsk,
    answers: List<LiveAnswer> = emptyList(),
    approve: Boolean = false,
    agent: Agent = Agent.omp,
): List<KeyStep> {
    require(!ask.isPlan && !ask.isMenu) { "A plan review or a picker is answered with menuKeys." }
    val questions = ask.questions
    if (questions != null) {
        require(answers.size == questions.size) { "One answer per question." }
        for ((i, q) in questions.withIndex()) {
            val a = answers[i]
            for (p in a.picks) require(p >= 0 && p < q.options.size) { "No option $p in \"${q.question}\"." }
            require(q.multi || a.picks.size + (if (custom(a) == null) 0 else 1) == 1) { "Pick one answer for \"${q.question}\"." }
        }
    }
    return when (agent) {
        Agent.omp -> ompKeys(ask, answers, approve)
        Agent.claude -> claudeKeys(ask, answers, approve)
    }
}

private fun custom(a: LiveAnswer): String? = a.custom?.dartTrim()?.takeIf { it.isNotEmpty() }

/** Steps that run consecutive key presses together, as one keys request. */
private class Steps {
    val steps = mutableListOf<KeyStep>()

    fun press(keys: List<String>) {
        val last = steps.lastOrNull()
        if (last is Keys) steps[steps.size - 1] = Keys(last.keys + keys) else steps.add(Keys(keys.toList()))
    }

    fun add(step: KeyStep) {
        steps.add(step)
    }

    fun settle() {
        if (steps.lastOrNull() !is Settle) steps.add(Settle)
    }
}

/**
 * omp: the ask dialog lists each question's options and then "Other"; its cursor stops at the
 * ends, so going up past the top and then down picks a row wherever the cursor started. Enter on
 * a single-choice row answers and moves on, Space toggles a multiple-choice row and Enter moves
 * on; after several questions a Submit tab takes a last Enter. A typed answer goes through an
 * editor; its Enter closes it, and the next keys wait for that ([Settle]). An approval is omp's
 * Approve/Deny menu, which opens on Approve.
 */
private fun ompKeys(ask: LiveAsk, answers: List<LiveAnswer>, approve: Boolean): List<KeyStep> {
    if (ask.isApproval) return listOf(Keys(if (approve) listOf("enter") else listOf("down", "enter")))
    val questions = ask.questions!!
    val s = Steps()
    var onSubmitTab = false
    for ((i, q) in questions.withIndex()) {
        val a = answers[i]
        val rows = q.options.size + 1
        fun rowKeys(row: Int) = List(rows) { "up" } + List(row) { "down" }
        val custom = custom(a)
        if (q.multi) for (p in a.picks) s.press(rowKeys(p) + "space")
        if (custom != null) {
            s.press(rowKeys(q.options.size) + "enter")
            s.add(Settle)
            s.add(Typed(custom))
            s.press(listOf("enter"))
            s.add(Settle)
            // A lone multiple-choice question goes to its Submit tab after a typed answer.
            if (q.multi && questions.size == 1) onSubmitTab = true
        } else if (q.multi) {
            s.press(listOf("enter"))
        } else {
            s.press(rowKeys(a.picks.single()) + "enter")
        }
    }
    if (questions.size > 1 || onSubmitTab) {
        s.settle()
        s.press(listOf("enter"))
    }
    return s.steps
}

/** Claude Code numbers the rows of its dialogs from 1: a row's digit picks it (or toggles it, in a multiple-choice question) wherever the cursor is. */
fun claudeRowKey(row: Int): String = "${row + 1}"

/**
 * Claude Code: a question lists its options, then "Type something", then (multiple choice) a
 * Submit row. A single-choice row's digit answers and moves on; the typed row's digit opens it
 * for typing, and Enter answers. Multiple choice: digits toggle rows without moving the cursor
 * from the first, ↓ takes it to the typed row (whose text ticks it) and on to Submit, where Enter
 * moves on. Several questions, or a multiple-choice one, end on a review tab whose first row
 * submits. An approval opens on Yes; Esc refuses.
 */
private fun claudeKeys(ask: LiveAsk, answers: List<LiveAnswer>, approve: Boolean): List<KeyStep> {
    if (ask.isApproval) return listOf(Keys(listOf(if (approve) claudeRowKey(0) else "esc")))
    val questions = ask.questions!!
    val s = Steps()
    for ((i, q) in questions.withIndex()) {
        val a = answers[i]
        val n = q.options.size
        val custom = custom(a)
        if (i > 0) s.settle()
        if (!q.multi) {
            if (custom == null) {
                s.press(listOf(claudeRowKey(a.picks.single())))
                continue
            }
            s.press(listOf(claudeRowKey(n)))
            s.add(Settle)
            s.add(Typed(custom))
            s.add(Settle)
            s.press(listOf("enter"))
            continue
        }
        for (p in a.picks) s.press(listOf(claudeRowKey(p)))
        if (custom == null) {
            s.press(List(n + 1) { "down" } + "enter")
            continue
        }
        s.press(listOf(claudeRowKey(n)) + List(n) { "down" })
        s.add(Settle)
        s.add(Typed(custom))
        s.add(Settle)
        s.press(listOf("down", "enter"))
    }
    if (questions.size > 1 || questions.single().multi) {
        s.settle()
        s.press(listOf(claudeRowKey(0)))
    }
    return s.steps
}

private val FLAT_MARKS = Regex("[$WS*_`#>]+")

/**
 * How to tell [ask] is [agent]'s dialog on the screen: some of its words in the screen's text,
 * compared without spacing or Markdown marks (the terminal wraps and styles them).
 */
fun askOnScreen(ask: LiveAsk, screen: String, agent: Agent = Agent.omp): Boolean {
    fun flat(s: String) = FLAT_MARKS.replace(s, "").lowercase()
    val text = flat(screen)
    if (ask.isPlan) return (agent == Agent.omp && text.contains("planmode-nextstep")) || parsePlanReview(screen, agent) != null
    if (ask.isMenu) return parseMenu(screen)?.title == ask.title
    if (ask.isApproval) {
        return when (agent) {
            Agent.omp -> text.contains("approve") && text.contains("deny")
            // "Do you want to proceed?" (or "… to create notes.txt?") over "❯ 1. Yes".
            Agent.claude -> text.contains("doyouwant") && text.contains("❯1.yes")
        }
    }
    val q = flat(ask.questions!!.first().question)
    return text.contains(if (q.length > 24) q.substring(0, 24) else q)
}

/** A plan review read off a screen: its options and the one its cursor is on. */
data class PlanReview(val options: List<String>, val current: Int)

/**
 * [agent]'s plan review (the last step of plan mode), read off the plain text of its screen: its
 * options and the one its cursor (❯) is on. Null unless a review is up with its options focused.
 */
fun parsePlanReview(screen: String, agent: Agent = Agent.omp): PlanReview? = when (agent) {
    Agent.omp -> ompPlanReview(screen)
    Agent.claude -> claudePlanReview(screen)
}

private val CLAUDE_PLAN_HEADER = Regex("Would you like to proceed\\?|Exit plan mode\\?")
private val CLAUDE_ROW = Regex("^$S*(❯$S*)?(\\d+)\\.$S+($NS.*?)$S*\\z")

/**
 * Claude Code's plan review: the numbered rows under its last "Would you like to proceed?"
 * ("Exit plan mode?" when no plan was written). Lines between them (a row's hint) are skipped; a
 * number out of turn ends them.
 */
private fun claudePlanReview(screen: String): PlanReview? {
    val lines = screen.split("\n")
    val header = lines.indexOfLast { CLAUDE_PLAN_HEADER.containsMatchIn(it) }
    if (header < 0) return null
    val options = mutableListOf<String>()
    var current = -1
    for (l in lines.drop(header + 1)) {
        val m = CLAUDE_ROW.find(l) ?: continue
        if (m.groupValues[2].toInt() != options.size + 1) break
        if (m.groups[1] != null) current = options.size
        options.add(m.groupValues[3])
    }
    if (current < 0) return null
    return PlanReview(options, current)
}

private val PLAN_HEADER = Regex("plan mode$S*[-–—]$S*next step", RegexOption.IGNORE_CASE)
private val PLAN_HELP = Regex("(?<![A-Za-z0-9_])select(?![A-Za-z0-9_])", RegexOption.IGNORE_CASE)
private val LEFT_EDGE = Regex("^$S*[│┃║|]")
private val RIGHT_EDGE = Regex("$S*[│┃║|]$S*\\z")
private val CURSOR = Regex("^($S*)[❯›>]$S+(?=$NS)")
private val RULE = Regex("^[─━═┄┈╌\\-+├┤┼┬┴╭╮╰╯]+\\z")
private val SPACES = Regex("$S+")

private fun indent(s: String) = s.length - s.dartTrimLeft().length

/**
 * omp's plan review, read off the plain text of its screen: the options listed between its
 * "Plan mode - next step" header and the help line under them ("↑/↓ select · ⏎ confirm · …"), and
 * the one its cursor (❯) is on. The model slider above them ("continue with ◂ smol default slow ▸"
 * and its "↳ model" line) is skipped, and a row the terminal wrapped is joined again. Null unless
 * a review is up with its options focused, the only time ↑/↓ move between them.
 */
private fun ompPlanReview(screen: String): PlanReview? {
    val lines = screen.split("\n")
    val header = lines.indexOfLast { PLAN_HEADER.containsMatchIn(it) }
    if (header < 0) return null
    val help = (header + 1 until lines.size).firstOrNull { PLAN_HELP.containsMatchIn(lines[it]) } ?: return null
    // Inside the review's box every row starts with its edge; a row too wide for the terminal
    // goes on, without one, on the next line.
    val boxed = LEFT_EDGE.containsMatchIn(lines[header])
    data class Row(val edge: Boolean, val text: String)
    val rows = lines.subList(header + 1, help).map { l ->
        Row(LEFT_EDGE.containsMatchIn(l), RIGHT_EDGE.replaceFirst(LEFT_EDGE.replaceFirst(l, ""), ""))
    }
    val at = rows.indexOfFirst { CURSOR.containsMatchIn(it.text) }
    if (at < 0) return null
    // Where the labels start: past the cursor on its row, past the indent on the others.
    val column = CURSOR.find(rows[at].text)!!.range.last + 1

    val options = mutableListOf<String>()
    var current = -1
    var afterOption = false
    for ((i, r) in rows.withIndex()) {
        val t = r.text.dartTrim()
        if (t.isEmpty() || RULE.containsMatchIn(t)) {
            afterOption = false
            continue
        }
        if (if (boxed) !r.edge else i != at && indent(r.text) != column) {
            if (afterOption) options[options.size - 1] += if (boxed) r.text else " ${r.text}"
            continue
        }
        afterOption = false
        if (t.startsWith("↳") || t.contains("continue with") || t.contains("◂") || t.contains("▸")) continue
        if (i == at) {
            current = options.size
            options.add(r.text.substring(column))
        } else if (indent(r.text) == column) {
            options.add(r.text.substring(column))
        } else {
            continue
        }
        afterOption = true
    }
    if (current < 0) return null
    return PlanReview(options.map { SPACES.replace(it, " ").dartTrim() }, current)
}

/**
 * The keys that move a menu's cursor (a picker's, the plan review's) from row [current] to
 * [target], then (with [enter]) pick it. Never above row 0: the plan review's ↑ there leaves its
 * options for the plan's text.
 */
fun menuKeys(current: Int, target: Int, enter: Boolean = true): List<String> {
    require(current >= 0 && target >= 0) { "No row $target." }
    return List(maxOf(0, target - current)) { "down" } + List(maxOf(0, current - target)) { "up" } + (if (enter) listOf("enter") else emptyList())
}

private val MENU_CURSOR = Regex("^$S*❯ ")

/** Claude Code's prompt line: ❯ and a no-break space. It shows only while no picker is up; the `❯ ` rows above it are prompts in its transcript. */
private val CLAUDE_PROMPT = Regex("^$S*❯\u00a0")
private val MENU_LEFT = Regex("^$S*[│┃║]")
private val MENU_RIGHT = Regex("($S*[│┃║█])+$S*\\z")
private val MENU_CHROME = Regex("^[$WS─━═╭╮┌┐╔╗├┤╰╯└┘]+|[$WS─━═╭╮┌┐╔╗├┤╰╯└┘]+\\z")
private val MENU_STATUS = Regex(
    "^(\\(\\d+/\\d+[^)]*\\)$S*)?(type to search|search:|no match|no items|no sessions)",
    RegexOption.IGNORE_CASE,
)
private val MENU_GAP = Regex("$S{2,}")

/** A numbered row's number (Claude Code's pickers: `1.  Default`), whose gap is part of the label, not the one before its detail. */
private val MENU_NUMBER = Regex("^(\\d+\\.)$S+")

/** A vertical rule inside a row: another pane beside the list. */
private val PANE_SPLIT = Regex("[│┃║]")

/** A picker read off a screen: its title, rows, the cursor's row, and whether typing filters it. */
data class Menu(val title: String, val items: List<MenuItem>, val current: Int, val filter: Boolean)

/**
 * A picker the agent's terminal UI shows (/resume, /model, /tree, a hook's selector …), read off
 * the plain text of its screen: the rows around the last cursor (❯) at the cursor's label column,
 * a `title` above them (its box's top border, or a line of its own) and whether typing filters
 * them (a `>` search line above, or "Type to search" under them). Rows apart by blank lines are
 * one item each (first line its label, the rest its detail); otherwise every line is one, with
 * what's indented deeper or set apart by a wide gap as its detail. Box edges, scrollbars, padding
 * and lone "…" lines are left out; a footer of keys ends the rows. Null for anything else: the
 * plan review, or Claude Code's prompt under a transcript whose prompts read `❯ …` too.
 */
fun parseMenu(screen: String): Menu? {
    if (PLAN_HEADER.containsMatchIn(screen)) return null
    val lines = screen.split("\n").map { MENU_RIGHT.replaceFirst(MENU_LEFT.replaceFirst(it, ""), "") }
    val at = lines.indexOfLast { MENU_CURSOR.containsMatchIn(it) }
    if (at < 0 || lines.drop(at + 1).any { CLAUDE_PROMPT.containsMatchIn(it) }) return null
    val column = MENU_CURSOR.find(lines[at])!!.range.last + 1
    var filter = false
    fun inList(i: Int): Boolean {
        val t = lines[i].dartTrim()
        if (t.isEmpty() || i == at) return true
        if (MENU_STATUS.containsMatchIn(t)) {
            filter = filter or t.lowercase().contains("search")
            return false
        }
        return indent(lines[i]) >= column
    }

    var top = at
    while (top > 0 && inList(top - 1)) top--
    var bottom = at
    while (bottom + 1 < lines.size && inList(bottom + 1)) bottom++
    data class Row(val i: Int, val text: String)
    val rows = (top..bottom).filter { lines[it].dartTrim() != "…" }.map { Row(it, lines[it]) }
    fun isItem(r: Row) = r.i == at || (r.text.dartTrim().isNotEmpty() && indent(r.text) == column)
    val first = rows.indexOfFirst(::isItem)
    val last = rows.indexOfLast(::isItem)
    val blocks = rows.subList(first, last + 1).any { it.text.dartTrim().isEmpty() }

    val items = mutableListOf<MutableList<String>>()
    var current = -1
    var gap = true
    for (r in rows) {
        val t = r.text.dartTrim()
        if (t.isEmpty()) {
            gap = true
            continue
        }
        if (isItem(r) && (!blocks || gap || items.isEmpty())) {
            var row = r.text.substring(column).dartTrim()
            MENU_NUMBER.find(row)?.let { m -> row = "${m.groupValues[1]} " + row.substring(m.range.last + 1) }
            val split = MENU_GAP.find(row)
            items.add(if (split == null) mutableListOf(row) else mutableListOf(row.substring(0, split.range.first), row.substring(split.range.last + 1)))
        } else if (items.isNotEmpty()) {
            items.last().add(t)
        } else {
            continue
        }
        if (r.i == at) current = items.size - 1
        gap = false
    }
    if (current < 0) return null
    // Panes side by side (/model's providers | models): a list of the left pane alone would
    // mislead, so leave it to the screen.
    if (rows.any { PANE_SPLIT.containsMatchIn(it.text.substring(minOf(column, it.text.length))) }) return null

    // The title: the first line above the rows that isn't blank or the search line.
    var title = ""
    for (i in top - 1 downTo 0) {
        val t = lines[i].dartTrim()
        if (t.isEmpty()) continue
        if (t.startsWith(">")) {
            filter = true
            continue
        }
        title = MENU_CHROME.replace(t, "")
        break
    }
    fun flat(s: String) = SPACES.replace(s, " ").dartTrim()
    return Menu(
        title = flat(title),
        items = items.map { MenuItem(label = flat(it.first()), detail = it.drop(1).joinToString(" · ") { s -> flat(s) }) },
        current = current,
        filter = filter,
    )
}
