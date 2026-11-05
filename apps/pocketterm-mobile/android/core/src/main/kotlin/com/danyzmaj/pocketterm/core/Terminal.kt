package com.danyzmaj.pocketterm.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

// The Mac's terminals as the phone reaches them: one host per terminal app (kitty, WezTerm,
// iTerm2, Ghostty) or multiplexer (tmux), each with what its scripting can do (TermCap). A
// window's key starts with its host's prefix and fits the push function's session keys,
// `[\w.:/-]{1,64}`:
//
//   kitty      kitty-<pid>/<window id>
//   tmux       tmux:<socket name>/<pane n>
//   wezterm    wezterm:<gui pid>/<pane id>
//   ghostty    ghostty:<terminal UUID>
//   iterm      iterm:<session UUID>

/** What a window's terminal lets the phone do with it. */
enum class TermCap {
    /** Its screen can be read (as text, with colors if [ansi]). */
    read,

    /** Its screen comes with its colors as ANSI escapes. */
    ansi,

    /** Text can be typed without Enter, and Enter and Shift+Enter pressed. */
    type,

    /** A line can be typed and run (Enter after it). */
    line,

    /** Keys can be pressed: arrows, Esc, Tab, Ctrl+C, digits. */
    keys,

    /** It can be closed. */
    close,
}

/** Everything, as an older Mac's windows (kitty's) could. */
val allCaps: Set<TermCap> = linkedSetOf(*TermCap.entries.toTypedArray())

/**
 * One terminal window (a tab, a pane, a split), as the phone sees it. [osWindow] and [tabId]
 * say where it sits on the Mac: the app's window (Cmd+N) and the tab in it.
 */
class TermWindow(
    /** The host's prefix, then which window of which instance. */
    val key: String,
    val title: String,
    /** The tab's title. */
    val tab: String,
    /** The foreground program's working directory. */
    val cwd: String,
    /** The foreground program's name: `omp`, `claude`, `zsh`, `nvim`. */
    val program: String,
    /** The window its app has focused. */
    val focused: Boolean = false,
    /** Its host's id: kitty, tmux, wezterm, iterm, ghostty. */
    val app: String = "kitty",
    val caps: Set<TermCap> = allCaps,
    /** The terminal app a tmux pane shows in (its client's), by label. */
    val via: String = "",
    /** Its tty (`ttys012`), when the app says; the Mac's own business (never sent). */
    val tty: String = "",
    /** The app window it is in, unique across apps (`kitty-123/os2`); empty when unknown. */
    val osWindow: String = "",
    /** The tab it is in, unique across apps like [osWindow]; empty when unknown. */
    val tabId: String = "",
    /** The omp profile its foreground omp runs; '' for the default or where nothing tells. */
    val profile: String = "",
) {
    /** The coding agent running in it, if one is. */
    val agent: Agent? get() = Agent.ofProgram(program)

    fun can(cap: TermCap): Boolean = cap in caps

    fun copyWith(
        via: String? = null,
        caps: Set<TermCap>? = null,
        osWindow: String? = null,
        tabId: String? = null,
        profile: String? = null,
    ) = TermWindow(
        key = key, title = title, tab = tab, cwd = cwd, program = program, focused = focused, app = app,
        caps = caps ?: this.caps, via = via ?: this.via, tty = tty, osWindow = osWindow ?: this.osWindow,
        tabId = tabId ?: this.tabId, profile = profile ?: this.profile,
    )

    fun toJson(): JsonObject = JsonObject(
        linkedMapOf(
            "key" to key.toJsonElement(),
            "title" to title.toJsonElement(),
            "tab" to tab.toJsonElement(),
            "cwd" to cwd.toJsonElement(),
            "program" to program.toJsonElement(),
            "focused" to focused.toJsonElement(),
            "app" to app.toJsonElement(),
            "caps" to TermCap.entries.filter { it in caps }.map { it.name }.toJsonElement(),
        ).apply {
            if (via.isNotEmpty()) put("via", via.toJsonElement())
            if (osWindow.isNotEmpty()) put("osWindow", osWindow.toJsonElement())
            if (tabId.isNotEmpty()) put("tabId", tabId.toJsonElement())
            if (profile.isNotEmpty()) put("profile", profile.toJsonElement())
        },
    )

    companion object {
        /** Throws [IllegalArgumentException] without a string `key`, as Dart's cast does. */
        fun fromJson(j: JsonObject): TermWindow {
            val caps = j["caps"]
            return TermWindow(
                key = j["key"].str ?: throw IllegalArgumentException("TermWindow without a key"),
                title = j["title"].str ?: "",
                tab = j["tab"].str ?: "",
                cwd = j["cwd"].str ?: "",
                program = j["program"].str ?: "",
                focused = j["focused"].bool == true,
                // An older Mac lists only kitty, which can do everything.
                app = j["app"].str ?: "kitty",
                caps = if (caps is JsonArray) {
                    caps.mapNotNullTo(linkedSetOf()) { c -> TermCap.entries.firstOrNull { it.name == c.str } }
                } else {
                    allCaps
                },
                via = j["via"].str ?: "",
                osWindow = j["osWindow"].str ?: "",
                tabId = j["tabId"].str ?: "",
                profile = j["profile"].str ?: "",
            )
        }
    }
}

/** Where a session the phone starts opens on the Mac (the Mac's setting). */
enum class Placement {
    /** A new tab in the app window that holds the project's tabs; a new window when none does. */
    projectWindow,

    /** A new app window each time. */
    newWindow;

    /** As the phone shows it after "Opens in kitty". */
    val describe: String
        get() = when (this) {
            projectWindow -> "as a tab in the project's window"
            newWindow -> "in a new window"
        }
}

/**
 * A window the phone had opened: its `window` key, and `where` it went on the Mac as the phone
 * says it ("a new tab in the kitty window with wrkly"); empty from a Mac that doesn't say.
 */
data class Opened(val window: String, val where: String)

/** Something a terminal couldn't do, said the way the phone shows it. */
open class TerminalException(override val message: String) : Exception(message) {
    override fun toString() = message
}

/** How a terminal stands, for Settings → Terminal. */
enum class TermState {
    /** Usable: the phone sees its windows and can do what its caps say. */
    ready,

    /** Usable, but its scripting can't do everything ([TermStatus.note] says what's missing). */
    limited,

    /** Installed, and needs one thing done first ([TermStatus.fix]). */
    setup,

    /** Installed and not running: nothing to list now. */
    idle,

    /** Not on this Mac. */
    missing,
}

/** The one-click fixes Settings offers. */
enum class TermFix {
    /** Append kitty's remote control lines to kitty.conf (then restart kitty). */
    kittyConfig,

    /** Open System Settings → Privacy & Security → Automation. */
    automation,

    /** Open the terminal's install page (WezTerm on Windows). */
    install,
}

/** One terminal app's state on the Mac, as Settings and the phone show it. */
class TermStatus(
    val id: String,
    val label: String,
    val state: TermState,
    /** One line: what works, what's missing, what to do. */
    val note: String = "",
    val fix: TermFix? = null,
) {
    val usable: Boolean get() = state == TermState.ready || state == TermState.limited

    fun toJson(): JsonObject = jsonOf("id" to id, "label" to label, "state" to state.name, "note" to note)

    companion object {
        /** As the phone gets it in the bridge's state (no [fix]); an unknown state reads as limited. */
        fun fromJson(j: JsonObject) = TermStatus(
            j["id"].str ?: "",
            j["label"].str ?: "",
            TermState.entries.firstOrNull { it.name == j["state"].str } ?: TermState.limited,
            note = j["note"].str ?: "",
        )
    }
}

// ------------------------------------------------------------ keys

private val ctrlKey = Regex("ctrl\\+([a-z])")

/**
 * What a key sends to the program in the terminal, for hosts that write bytes. kitty's names:
 * `enter`, `esc`, `tab`, `shift+tab`, `space`, `backspace`, arrows, `ctrl+<letter>`, a single
 * character. Shift+Enter goes as Alt+Enter (ESC CR), which omp's and Claude Code's editors read
 * as a new line where the terminal can't send Shift+Enter itself.
 */
fun keyBytes(name: String): String {
    val named = when (name) {
        "enter", "return" -> "\r"
        "esc", "escape" -> "\u001b"
        "tab" -> "\t"
        "shift+tab" -> "\u001b[Z"
        "space" -> " "
        "backspace" -> "\u007f"
        "delete" -> "\u001b[3~"
        "up" -> "\u001b[A"
        "down" -> "\u001b[B"
        "right" -> "\u001b[C"
        "left" -> "\u001b[D"
        "home" -> "\u001b[H"
        "end" -> "\u001b[F"
        "page_up", "pageup" -> "\u001b[5~"
        "page_down", "pagedown" -> "\u001b[6~"
        "shift+enter", "alt+enter" -> "\u001b\r"
        else -> null
    }
    if (named != null) return named
    ctrlKey.matchEntire(name)?.let { return (it.groupValues[1][0].code - 0x60).toChar().toString() }
    if (name.codePointCount(0, name.length) == 1) return name
    throw TerminalException("Unknown key: $name")
}

/** [names] as the byte runs to write: one run, except that Esc goes on its own (followed by more bytes it would read as Alt+key). */
fun keyRuns(names: List<String>): List<String> {
    val runs = mutableListOf<String>()
    val current = StringBuilder()
    for (n in names) {
        val b = keyBytes(n)
        if (b == "\u001b") {
            if (current.isNotEmpty()) runs.add(current.toString())
            runs.add(b)
            current.setLength(0)
        } else {
            current.append(b)
        }
    }
    if (current.isNotEmpty()) runs.add(current.toString())
    return runs
}

/** Keys the phone may press itself (the screen page's key row). */
val phoneKeys: Set<String> = linkedSetOf("esc", "tab", "up", "down", "enter", "ctrl+c")

/** UTF-8 bytes of the UTF-16 unit [c] when not part of a pair (a lone surrogate encodes as U+FFFD, 3 bytes, as in Dart). */
private fun utf8Units(c: Int) = if (c < 0x80) 1 else if (c < 0x800) 2 else 3

/** [s]'s length in UTF-8 as Dart's `utf8.encode` counts it (lone surrogates as U+FFFD). */
internal fun utf8Length(s: String): Int {
    var n = 0
    var i = 0
    while (i < s.length) {
        val c = s[i].code
        if (c and 0xFC00 == 0xD800 && i + 1 < s.length && s[i + 1].code and 0xFC00 == 0xDC00) {
            n += 4
            i += 2
        } else {
            n += utf8Units(c)
            i++
        }
    }
    return n
}

/**
 * [text] in pieces of at most [maxBytes] UTF-8 bytes each, in order, cut between characters
 * only: a terminal's scripting takes a bounded amount in one command (tmux refuses one over
 * 16 KB, kitty a message over about 128 KB).
 */
fun textChunks(text: String, maxBytes: Int): List<String> {
    val out = mutableListOf<String>()
    var start = 0
    var bytes = 0
    var i = 0
    while (i < text.length) {
        val c = text[i].code
        val pair = c and 0xFC00 == 0xD800 && i + 1 < text.length && text[i + 1].code and 0xFC00 == 0xDC00
        val n = if (pair) 4 else utf8Units(c)
        if (bytes + n > maxBytes && i > start) {
            out.add(text.substring(start, i))
            start = i
            bytes = 0
        }
        bytes += n
        i += if (pair) 2 else 1
    }
    if (start < text.length) out.add(text.substring(start))
    return out
}

/** The most characters of a window's or tab's title the phone gets. */
const val titleRunes = 200

private val titleEscapes = Regex("""\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[ -/]*[0-~]?""")
private val titleBreaks = Regex("""[\t\n\r]+""")
private val titleControls = Regex("""[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]""")

/**
 * A window's or tab's [title] as the phone shows it: escape sequences and control characters
 * dropped, a tab or line break as a space, bidi overrides dropped (they would turn the text
 * after the title around), and at most [titleRunes] characters.
 */
fun cleanTitle(title: String): String {
    val t = title.replace(titleEscapes, "").replace(titleBreaks, " ").replace(titleControls, "")
    if (t.codePointCount(0, t.length) <= titleRunes) return t
    return t.substring(0, t.offsetByCodePoints(0, titleRunes - 1)) + "\u2026"
}

// ------------------------------------------------------------ screens

/**
 * A sealed message grows by a third and the server closes a socket on a frame over 256 KB, so
 * scrollback keeps only its newest lines up to this many UTF-8 bytes.
 */
const val historyBytes = 60000

private val charsetEscape = Regex("""\x1b[ -/]+[0-~]""")
private val closingPad = Regex("""(?: |\x1b\[[0-9;:]*m)+\z""")
private val sgrEscape = Regex("""\x1b\[[0-9;:]*m""")
private val tailEscape = Regex("""\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)""")

/**
 * A terminal's [text] as the phone's lines: charset choices (ESC ( B, which WezTerm puts before
 * its SGR resets) dropped, plain spaces among a line's closing escapes dropped (padding),
 * trailing blank lines dropped, and only the newest lines within [historyBytes]; a newest line
 * longer than that (kitty joins a wrapped line's rows) as its end.
 */
fun screenLines(text: String): List<String> {
    val raw = text.replace("\r\n", "\n").replace(charsetEscape, "").split("\n")
    val kept = mutableListOf<String>()
    var bytes = 0
    for (i in raw.indices.reversed()) {
        val line = closingPad.find(raw[i])?.let { m ->
            raw[i].substring(0, m.range.first) + sgrEscape.findAll(m.value).joinToString("") { it.value } + raw[i].substring(m.range.last + 1)
        } ?: raw[i]
        if (kept.isEmpty() && line.replace(sgrEscape, "").isEmpty()) continue
        bytes += utf8Length(line) + 1
        if (bytes > historyBytes) {
            if (kept.isEmpty()) kept.add(tail(line, historyBytes - 1))
            break
        }
        kept.add(line)
    }
    return kept.asReversed().toList()
}

/** The end of [line] within [maxBytes] UTF-8 bytes, cut between characters and not inside an escape sequence. */
private fun tail(line: String, maxBytes: Int): String {
    var at = line.length
    var bytes = 0
    while (at > 0) {
        val c = line[at - 1].code
        val pair = c and 0xFC00 == 0xDC00 && at > 1 && line[at - 2].code and 0xFC00 == 0xD800
        val n = if (pair) 4 else utf8Units(c)
        if (bytes + n > maxBytes) break
        bytes += n
        at -= if (pair) 2 else 1
    }
    for (m in tailEscape.findAll(line)) {
        val end = m.range.last + 1
        if (end <= at) continue
        if (m.range.first < at) at = end
        break
    }
    return line.substring(at)
}

// ------------------------------------------------------------ where an agent runs

private val tmuxSocket = Regex("""[\w.-]{1,40}""")
private val digits = Regex("""\d+""")
private val kittySocket = Regex("""kitty[\w.-]*""")
private val weztermSocket = Regex("""gui-sock-(\d+)\z""")
private val itermSession = Regex("""w\d+t\d+p\d+:([0-9A-Fa-f-]{36})""")

/**
 * The key of the window a coding agent runs in, from the `term` its extension reports (its
 * environment, raw: TERM_PROGRAM, KITTY_*, TMUX, TMUX_PANE, WEZTERM_*, ITERM_SESSION_ID, and
 * `tty`). tmux wins (the pane, not the terminal showing it); then the terminal TERM_PROGRAM
 * names (other terminals' variables leak into apps started from them); then kitty's own
 * variables. Null when it can't be told without asking a terminal (Ghostty).
 */
fun windowOfTerm(term: JsonObject?): String? {
    if (term == null) return null
    fun v(name: String): String? = term[name].str?.takeIf { it.isNotEmpty() }

    val tmux = v("TMUX")
    val pane = v("TMUX_PANE")
    if (tmux != null && pane != null) {
        val socket = tmux.split(',').first().split('/').last()
        val n = pane.replaceFirst("%", "")
        if (tmuxSocket.matches(socket) && digits.matches(n)) return "tmux:$socket/$n"
    }

    fun kitty(): String? {
        val window = v("KITTY_WINDOW_ID") ?: return null
        val listen = v("KITTY_LISTEN_ON")
        val socket = listen?.removePrefix("unix:")?.split('/')?.last() ?: v("KITTY_PID")?.let { "kitty-$it" }
        return if (socket != null && kittySocket.matches(socket)) "$socket/$window" else null
    }

    fun wezterm(): String? {
        val p = v("WEZTERM_PANE")
        val pid = weztermSocket.find(v("WEZTERM_UNIX_SOCKET") ?: "")?.groupValues?.get(1)
        return if (p != null && pid != null) "wezterm:$pid/$p" else null
    }

    fun iterm(): String? = itermSession.matchEntire(v("ITERM_SESSION_ID") ?: "")?.groupValues?.get(1)?.let { "iterm:$it" }

    return when (v("TERM_PROGRAM")) {
        "WezTerm" -> wezterm()
        "iTerm.app" -> iterm()
        "ghostty" -> null
        else -> kitty() ?: wezterm()
    }
}

/** Valid tmux socket names in keys. */
fun tmuxSocketName(name: String): Boolean = tmuxSocket.matches(name)
