import Foundation

// The Mac's terminals as the phone reaches them (PocketTermTerminals merges
// them): one TerminalHost per terminal app (kitty, WezTerm, iTerm2, Ghostty) or
// multiplexer (tmux), each with what its scripting can do (TermCap). A window's
// key starts with its host's prefix and fits the push function's session keys,
// `[\w.:/-]{1,64}`:
//
//   kitty      kitty-<pid>/<window id>       (the socket's name, as before)
//   tmux       tmux:<socket name>/<pane n>   (%n is the pane)
//   wezterm    wezterm:<gui pid>/<pane id>
//   ghostty    ghostty:<terminal UUID>
//   iterm      iterm:<session UUID>          (ITERM_SESSION_ID's)
//
// This file is the platform-neutral half (what the phone and the live protocol
// use); the hosts themselves live in PocketTermTerminals (macOS only).

/// What a window's terminal lets the phone do with it.
public enum TermCap: String, CaseIterable, Sendable, Codable {
  /// Its screen can be read (as text, with colors if `ansi`).
  case read
  /// Its screen comes with its colors as ANSI escapes.
  case ansi
  /// Text can be typed without Enter, and Enter and Shift+Enter pressed.
  case type
  /// A line can be typed and run (Enter after it).
  case line
  /// Keys can be pressed: arrows, Esc, Tab, Ctrl+C, digits.
  case keys
  /// It can be closed.
  case close

  public var name: String { rawValue }
}

/// Everything, as an older Mac's windows (kitty's) could.
public let allCaps: Set<TermCap> = Set(TermCap.allCases)

/// One terminal window (a tab, a pane, a split: whatever the app calls the
/// thing a shell runs in), as the phone sees it. `osWindow` and `tabId` say
/// where it sits on the Mac: the app's window (Cmd+N) and the tab in it.
public struct TermWindow: Sendable, Hashable {
  /// The host's prefix, then which window of which instance.
  public var key: String
  public var title: String
  /// The tab's title.
  public var tab: String
  /// The foreground program's working directory.
  public var cwd: String
  /// The foreground program's name: `omp`, `claude`, `zsh`, `nvim`.
  public var program: String
  /// The window its app has focused.
  public var focused: Bool
  /// Its host's id: kitty, tmux, wezterm, iterm, ghostty.
  public var app: String
  public var caps: Set<TermCap>
  /// The terminal app a tmux pane shows in (its client's), by label.
  public var via: String
  /// Its tty (`ttys012`), when the app says; the Mac's own business (never sent).
  public var tty: String
  /// The app window it is in (what Cmd+N opens), unique across apps and
  /// starting with the app's key prefix (`kitty-123/os2`); empty when the
  /// app doesn't tell (an older Mac). A tmux pane a terminal app shows
  /// carries that app's window; a pane no app shows, its tmux session's.
  public var osWindow: String
  /// The tab it is in, unique across apps like `osWindow`; empty when
  /// unknown. Panes split in one tab share it.
  public var tabId: String
  /// The omp profile its foreground omp runs, from its command line; "" for the default, for anything else, or where
  /// no tty tells.
  public var profile: String

  public init(
    key: String, title: String, tab: String, cwd: String, program: String, focused: Bool = false,
    app: String = "kitty", caps: Set<TermCap> = allCaps, via: String = "", tty: String = "",
    osWindow: String = "", tabId: String = "", profile: String = ""
  ) {
    self.key = key
    self.title = title
    self.tab = tab
    self.cwd = cwd
    self.program = program
    self.focused = focused
    self.app = app
    self.caps = caps
    self.via = via
    self.tty = tty
    self.osWindow = osWindow
    self.tabId = tabId
    self.profile = profile
  }

  /// As the bridge sends it; nil without a `key` (Dart's cast would throw).
  public static func fromJson(_ j: JSONObject) -> TermWindow? {
    guard let key = j["key"]?.string else { return nil }
    return TermWindow(
      key: key,
      title: j["title"]?.string ?? "",
      tab: j["tab"]?.string ?? "",
      cwd: j["cwd"]?.string ?? "",
      program: j["program"]?.string ?? "",
      focused: j["focused"]?.bool == true,
      // An older Mac lists only kitty, which can do everything.
      app: j["app"]?.string ?? "kitty",
      caps: j["caps"]?.array.map { Set($0.compactMap { $0.string.flatMap(TermCap.init(rawValue:)) }) } ?? allCaps,
      via: j["via"]?.string ?? "",
      osWindow: j["osWindow"]?.string ?? "",
      tabId: j["tabId"]?.string ?? "",
      profile: j["profile"]?.string ?? ""
    )
  }

  /// The coding agent running in it, if one is.
  public var agent: Agent? { Agent.ofProgram(program) }

  public func can(_ cap: TermCap) -> Bool { caps.contains(cap) }

  public func copyWith(
    via: String? = nil, caps: Set<TermCap>? = nil, osWindow: String? = nil, tabId: String? = nil,
    profile: String? = nil
  ) -> TermWindow {
    var w = self
    if let via { w.via = via }
    if let caps { w.caps = caps }
    if let osWindow { w.osWindow = osWindow }
    if let tabId { w.tabId = tabId }
    if let profile { w.profile = profile }
    return w
  }

  public func toJson() -> JSONObject {
    var j: JSONObject = [
      "key": .string(key),
      "title": .string(title),
      "tab": .string(tab),
      "cwd": .string(cwd),
      "program": .string(program),
      "focused": .bool(focused),
      "app": .string(app),
      "caps": .array(TermCap.allCases.filter(caps.contains).map { .string($0.name) }),
    ]
    if !via.isEmpty { j["via"] = .string(via) }
    if !osWindow.isEmpty { j["osWindow"] = .string(osWindow) }
    if !tabId.isEmpty { j["tabId"] = .string(tabId) }
    if !profile.isEmpty { j["profile"] = .string(profile) }
    return j
  }
}

/// Where a session the phone starts opens on the Mac (the Mac's setting).
public enum Placement: String, CaseIterable, Sendable, Codable {
  /// A new tab in the app window that holds the project's tabs (the most
  /// of them); a new window when none does.
  case projectWindow
  /// A new app window each time.
  case newWindow

  public var name: String { rawValue }

  /// As the phone shows it after "Opens in kitty": "as a tab in the project's window".
  public var describe: String {
    switch self {
    case .projectWindow: "as a tab in the project's window"
    case .newWindow: "in a new window"
    }
  }
}

/// A window the phone had opened: its `window` key, and `where` it went on
/// the Mac as the phone says it ("a new tab in the kitty window with
/// wrkly"); empty from a Mac that doesn't say.
public struct Opened: Sendable, Hashable {
  public var window: String
  public var `where`: String
  public init(window: String, where: String) {
    self.window = window
    self.where = `where`
  }
}

/// Something a terminal couldn't do, said the way the phone shows it.
/// A class so the macOS Automation errors (`AutomationDenied`,
/// `AutomationPending`) are TerminalExceptions too, as in Dart.
public class TerminalException: Error, CustomStringConvertible, LocalizedError, @unchecked Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
  public var errorDescription: String? { message }
}

/// macOS refused PocketTerm's Apple Events to `app` (Privacy & Security →
/// Automation).
public final class AutomationDenied: TerminalException, @unchecked Sendable {
  public let app: String
  public init(app: String) {
    self.app = app
    super.init(
      "PocketTerm may not control \(app). Allow it in System Settings → Privacy & Security → Automation → PocketTerm.")
  }
}

/// macOS is asking the person whether PocketTerm may control `app`: nothing goes
/// to it until they answer.
public final class AutomationPending: TerminalException, @unchecked Sendable {
  public let app: String
  public init(app: String) {
    self.app = app
    super.init("macOS is asking whether PocketTerm may control \(app): answer it on the computer.")
  }
}

/// How a terminal stands, for Settings → Terminal.
public enum TermState: String, CaseIterable, Sendable, Codable {
  /// Usable: the phone sees its windows and can do what its caps say.
  case ready
  /// Usable, but its scripting can't do everything (`TermStatus.note` says what's missing).
  case limited
  /// Installed, and needs one thing done first (`TermStatus.fix`).
  case setup
  /// Installed and not running: nothing to list now.
  case idle
  /// Not on this Mac.
  case missing

  public var name: String { rawValue }
}

/// The one-click fixes Settings offers.
public enum TermFix: String, CaseIterable, Sendable, Codable {
  /// Append kitty's remote control lines to kitty.conf (then restart kitty).
  case kittyConfig
  /// Open System Settings → Privacy & Security → Automation.
  case automation
  /// Open the terminal's install page (WezTerm on Windows).
  case install

  public var name: String { rawValue }
}

/// How one terminal stands: Settings shows it, the phone gets it in the bridge's state.
public struct TermStatus: Sendable, Hashable {
  public var id: String
  public var label: String
  public var state: TermState
  /// One line: what works, what's missing, what to do.
  public var note: String
  public var fix: TermFix?

  public init(_ id: String, _ label: String, _ state: TermState, note: String = "", fix: TermFix? = nil) {
    self.id = id
    self.label = label
    self.state = state
    self.note = note
    self.fix = fix
  }

  /// As the phone gets it in the bridge's state (without `fix`, which only
  /// Settings on the Mac offers); an unknown state reads as limited.
  public init(json j: JSONObject) {
    self.init(
      j["id"]?.string ?? "",
      j["label"]?.string ?? "",
      j["state"]?.string.flatMap(TermState.init(rawValue:)) ?? .limited,
      note: j["note"]?.string ?? ""
    )
  }

  public var usable: Bool { state == .ready || state == .limited }

  public func toJson() -> JSONObject {
    ["id": .string(id), "label": .string(label), "state": .string(state.name), "note": .string(note)]
  }
}

// ------------------------------------------------------------ keys

/// What a key sends to the program in the terminal, for hosts that write
/// bytes. kitty's names: `enter`, `esc`, `tab`, `shift+tab`, `space`,
/// `backspace`, arrows, `ctrl+<letter>`, a single character. Shift+Enter
/// goes as Alt+Enter (ESC CR), which omp's and Claude Code's editors read as
/// a new line where the terminal can't send Shift+Enter itself.
public func keyBytes(_ name: String) throws -> String {
  switch name {
  case "enter", "return": return "\r"
  case "esc", "escape": return "\u{1b}"
  case "tab": return "\t"
  case "shift+tab": return "\u{1b}[Z"
  case "space": return " "
  case "backspace": return "\u{7f}"
  case "delete": return "\u{1b}[3~"
  case "up": return "\u{1b}[A"
  case "down": return "\u{1b}[B"
  case "right": return "\u{1b}[C"
  case "left": return "\u{1b}[D"
  case "home": return "\u{1b}[H"
  case "end": return "\u{1b}[F"
  case "page_up", "pageup": return "\u{1b}[5~"
  case "page_down", "pagedown": return "\u{1b}[6~"
  case "shift+enter", "alt+enter": return "\u{1b}\r"
  default: break
  }
  if let letter = ctrlKey.firstMatch(name)?[1], let c = letter.unicodeScalars.first {
    return String(UnicodeScalar(UInt8(c.value - 0x60)))
  }
  if name.unicodeScalars.count == 1 { return name }
  throw TerminalException("Unknown key: \(name)")
}

private let ctrlKey = TermRegex(#"^ctrl\+([a-z])\z"#)

/// `names` as the byte runs to write: one run, except that Esc goes on its
/// own (followed by more bytes it would read as Alt+key).
public func keyRuns(_ names: [String]) throws -> [String] {
  var runs: [String] = []
  var current = ""
  for n in names {
    let b = try keyBytes(n)
    if b == "\u{1b}" {
      if !current.isEmpty { runs.append(current) }
      runs.append(b)
      current = ""
    } else {
      current += b
    }
  }
  if !current.isEmpty { runs.append(current) }
  return runs
}

/// Keys the phone may press itself (the screen page's key row).
public let phoneKeys: Set<String> = ["esc", "tab", "up", "down", "enter", "ctrl+c"]

/// `text` in pieces of at most `maxBytes` UTF-8 bytes each, in order, cut
/// between characters only: a terminal's scripting takes a bounded amount
/// in one command (tmux refuses one over 16 KB, kitty a message over about
/// 128 KB; a command line is at most 1 MB on a Mac, 32K characters on
/// Windows).
public func textChunks(_ text: String, _ maxBytes: Int) -> [String] {
  var out: [String] = []
  var current = String.UnicodeScalarView()
  var bytes = 0
  for s in text.unicodeScalars {
    let n = UTF8.width(s)
    if bytes + n > maxBytes && !current.isEmpty {
      out.append(String(current))
      current = String.UnicodeScalarView()
      bytes = 0
    }
    bytes += n
    current.append(s)
  }
  if !current.isEmpty { out.append(String(current)) }
  return out
}

/// The most characters of a window's or tab's title the phone gets.
public let titleRunes = 200

private let titleEscapes = TermRegex(
  #"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[ -/]*[0-~]?"#)
private let titleBreaks = TermRegex(#"[\t\n\r]+"#)
private let titleControls = TermRegex(#"[\x{00}-\x{1f}\x{7f}-\x{9f}\x{202a}-\x{202e}\x{2066}-\x{2069}]"#)

/// A window's or tab's `title` as the phone shows it: escape sequences and
/// control characters dropped (kitty and WezTerm let some through), a tab
/// or line break as a space, bidi overrides dropped (they would turn the
/// text after the title around), and at most `titleRunes` characters (a
/// program may set a title of any length).
public func cleanTitle(_ title: String) -> String {
  let t = titleControls.replaceAll(titleBreaks.replaceAll(titleEscapes.replaceAll(title, ""), " "), "")
  let runes = t.unicodeScalars
  if runes.count <= titleRunes { return t }
  return String(String.UnicodeScalarView(runes.prefix(titleRunes - 1))) + "\u{2026}"
}

// ------------------------------------------------------------ screens

/// A sealed message grows by a third and the server closes a socket on a
/// frame over 256 KB, so scrollback keeps only its newest lines up to this
/// many UTF-8 bytes.
public let historyBytes = 60000

private let screenCharset = TermRegex(#"\x1b[ -/]+[0-~]"#)
private let screenPad = TermRegex(#"(?: |\x1b\[[0-9;:]*m)+\z"#)
private let screenSgr = TermRegex(#"\x1b\[[0-9;:]*m"#)
private let screenEscape = TermRegex(#"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"#)

/// A terminal's `text` as the phone's lines: charset choices (ESC ( B,
/// which WezTerm puts before its SGR resets) dropped, plain spaces among a
/// line's closing escapes dropped (padding), trailing blank lines dropped,
/// and only the newest lines within `historyBytes`; a newest line longer
/// than that (kitty joins a wrapped line's rows) as its end.
public func screenLines(_ text: String) -> [String] {
  let raw = screenCharset.replaceAll(text.replacingOccurrences(of: "\r\n", with: "\n"), "")
    .components(separatedBy: "\n")
  var kept: [String] = []
  var bytes = 0
  for rawLine in raw.reversed() {
    let line = screenPad.replaceFirstMapped(rawLine) { m in
      screenSgr.allMatches(m[0] ?? "").map { $0[0] ?? "" }.joined()
    }
    if kept.isEmpty && screenSgr.replaceAll(line, "").isEmpty { continue }
    bytes += line.utf8.count + 1
    if bytes > historyBytes {
      if kept.isEmpty { kept.append(screenTail(line, historyBytes - 1)) }
      break
    }
    kept.append(line)
  }
  return kept.reversed()
}

/// The end of `line` within `maxBytes` UTF-8 bytes, cut between characters
/// and not inside an escape sequence.
private func screenTail(_ line: String, _ maxBytes: Int) -> String {
  let scalars = Array(line.unicodeScalars)
  var at = scalars.count
  var bytes = 0
  while at > 0 {
    let n = UTF8.width(scalars[at - 1])
    if bytes + n > maxBytes { break }
    bytes += n
    at -= 1
  }
  // Regex offsets are UTF-16: find the cut there.
  var at16 = scalars[..<at].reduce(0) { $0 + UTF16.width($1) }
  for m in screenEscape.matchRanges(line) {
    if m.upperBound <= at16 { continue }
    if m.lowerBound < at16 { at16 = m.upperBound }
    break
  }
  return (line as NSString).substring(from: at16)
}

// ------------------------------------------------------------ where an agent runs

private let tmuxSocketPattern = TermRegex(#"^[A-Za-z0-9_.-]{1,40}\z"#)
private let digits = TermRegex(#"^[0-9]+\z"#)
private let unixPrefix = TermRegex("^unix:")
private let kittySocket = TermRegex(#"^kitty[A-Za-z0-9_.-]*\z"#)
private let weztermSocket = TermRegex(#"gui-sock-([0-9]+)\z"#)
private let itermSession = TermRegex(#"^w[0-9]+t[0-9]+p[0-9]+:([0-9A-Fa-f-]{36})\z"#)

/// The key of the window a coding agent runs in, from the `term` its
/// extension reports (its environment, raw: TERM_PROGRAM, KITTY_*, TMUX,
/// TMUX_PANE, WEZTERM_*, ITERM_SESSION_ID, and `tty`).
/// tmux wins (the pane, not the terminal showing it); then the terminal
/// TERM_PROGRAM names (other terminals' variables leak into apps started
/// from them); then kitty's own variables. Nil when it can't be told
/// without asking a terminal (Ghostty: `Terminals.locate`).
public func windowOfTerm(_ term: JSONObject?) -> String? {
  guard let term else { return nil }
  func v(_ name: String) -> String? {
    guard let s = term[name]?.string, !s.isEmpty else { return nil }
    return s
  }

  if let tmux = v("TMUX"), let pane = v("TMUX_PANE") {
    let first = tmux.components(separatedBy: ",")[0]
    let socket = first.components(separatedBy: "/").last!
    let n = dartReplaceFirst(pane, "%", "")
    if tmuxSocketPattern.hasMatch(socket) && digits.hasMatch(n) { return "tmux:\(socket)/\(n)" }
  }
  func kitty() -> String? {
    guard let window = v("KITTY_WINDOW_ID") else { return nil }
    let socket: String?
    if let listen = v("KITTY_LISTEN_ON") {
      socket = unixPrefix.replaceFirst(listen, "").components(separatedBy: "/").last!
    } else if let pid = v("KITTY_PID") {
      socket = "kitty-\(pid)"
    } else {
      socket = nil
    }
    guard let socket, kittySocket.hasMatch(socket) else { return nil }
    return "\(socket)/\(window)"
  }
  func wezterm() -> String? {
    let pid = weztermSocket.firstMatch(v("WEZTERM_UNIX_SOCKET") ?? "")?[1] ?? nil
    guard let pane = v("WEZTERM_PANE"), let pid else { return nil }
    return "wezterm:\(pid)/\(pane)"
  }
  func iterm() -> String? {
    guard let id = itermSession.firstMatch(v("ITERM_SESSION_ID") ?? "")?[1] ?? nil else { return nil }
    return "iterm:\(id)"
  }

  switch v("TERM_PROGRAM") {
  case "WezTerm": return wezterm()
  case "iTerm.app": return iterm()
  case "ghostty": return nil
  default: return kitty() ?? wezterm()
  }
}

/// Valid tmux socket names in keys.
public func tmuxSocketName(_ name: String) -> Bool { tmuxSocketPattern.hasMatch(name) }

// ------------------------------------------------------------ processes

/// One process as `ps` lists it.
public struct Proc: Sendable, Hashable {
  public var pid: Int
  public var ppid: Int
  public var pgid: Int
  public var tpgid: Int
  /// `ttys012`, or empty.
  public var tty: String
  public var stat: String
  public var args: String

  public init(pid: Int, ppid: Int, pgid: Int, tpgid: Int, tty: String, stat: String, args: String) {
    self.pid = pid
    self.ppid = ppid
    self.pgid = pgid
    self.tpgid = tpgid
    self.tty = tty
    self.stat = stat
    self.args = args
  }

  /// What runs, by name: `omp`, `claude`, `zsh`, `tmux`; a script's name
  /// for an interpreter (`node …/x.js` is x).
  public var program: String { programOf(args) }
}

private let leadingDash = TermRegex("^-")
private let scriptExtension = TermRegex(#"\.(m?js|ts|py|rb|pl)\z"#)
private let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl"]

/// The program `args` (ps's `args`) runs.
public func programOf(_ args: String) -> String {
  let words = TermRegex.whitespace.split(dartTrim(args))
  guard let firstWord = words.first, !firstWord.isEmpty else { return "" }
  func base(_ w: String) -> String { leadingDash.replaceFirst(w.components(separatedBy: "/").last!, "") }
  let first = base(firstWord)
  if interpreters.contains(first) {
    for w in words.dropFirst() where !w.dartStartsWith("-") {
      return scriptExtension.replaceFirst(base(w), "")
    }
  }
  return first
}

private let exeWord = TermRegex(#"^.*?\.exe\b"#, caseInsensitive: true)
private let exeSuffix = TermRegex(#"\.exe\z"#, caseInsensitive: true)
private let pathSeparator = TermRegex(#"[\\/]"#)

/// The program a window `title` names, for terminals that tell no tty: its
/// first word (or its path, up to `.exe`), the last part of that path,
/// without `.exe`, lowercased.
public func programOfTitle(_ title: String) -> String {
  let t = dartTrim(title)
  let word = exeWord.firstMatch(t)?[0] ?? TermRegex.whitespace.split(t)[0]
  return exeSuffix.replaceFirst(pathSeparator.split(word).last!, "").lowercased()
}

/// A snapshot of the computer's processes (one `ps`), to tell a tty's
/// foreground program and whether an app runs. Taking one is macOS-only
/// (`Procs.snapshot()` in PocketTermTerminals).
public struct Procs: Sendable {
  public let all: [Proc]
  public init(_ all: [Proc]) { self.all = all }

  /// The foreground program on `tty` (`ttys012` or `/dev/ttys012`): the
  /// leader of its foreground process group.
  public func foreground(_ tty: String) -> Proc? {
    let t = dartReplaceFirst(tty, "/dev/", "")
    if t.isEmpty { return nil }
    let on = all.filter { $0.tty == t }
    return on.first { $0.pid == $0.tpgid } ?? on.first { $0.pgid == $0.tpgid } ?? on.last { $0.stat.contains("+") }
  }

  public func byPid(_ pid: Int) -> Proc? { all.first { $0.pid == pid } }

  /// Whether a process whose command starts with `exe` runs.
  public func running(_ exe: String) -> Bool { all.contains { $0.args.dartStartsWith(exe) } }

  /// The pid of the first process whose command starts with `exe`.
  public func pidOf(_ exe: String) -> Int? { all.first { $0.args.dartStartsWith(exe) }?.pid }
}

private let psLine = TermRegex(
  #"^[\s]*([0-9]+)[\s]+([0-9]+)[\s]+([0-9]+)[\s]+(-?[0-9]+)[\s]+([^\s]+)[\s]+([^\s]+)[\s]+(.*)\z"#
    .replacingOccurrences(of: #"\s"#, with: jsSpaceChars))

/// `ps -Ao pid=,ppid=,pgid=,tpgid=,tty=,stat=,args=` as `Proc`s.
public func parsePs(_ out: String) -> [Proc] {
  dartLines(out).compactMap { l in
    guard let m = psLine.firstMatch(l), let pid = Int(m[1]!), let ppid = Int(m[2]!), let pgid = Int(m[3]!),
      let tpgid = Int(m[4]!)
    else { return nil }
    return Proc(
      pid: pid, ppid: ppid, pgid: pgid, tpgid: tpgid,
      tty: m[5] == "?" || m[5] == "??" ? "" : m[5]!,
      stat: m[6]!, args: m[7]!)
  }
}

/// `lsof -a -d cwd -Fpn -p …` as pid → directory.
public func parseLsofCwd(_ out: String) -> [Int: String] {
  var cwds: [Int: String] = [:]
  var pid: Int?
  for l in dartLines(out) {
    if l.dartStartsWith("p") { pid = Int((l as NSString).substring(from: 1)) }
    if l.dartStartsWith("n"), let pid { cwds[pid] = (l as NSString).substring(from: 1) }
  }
  return cwds
}

/// For a program whose output PocketTerm reads (`ps`, `lsof`): UTF-8,
/// whatever locale PocketTerm has. An app started from Finder or the Dock
/// has none (no `LANG`), and then `ps` writes a name's other letters as
/// `M-` escapes and `lsof` as `\xNN`.
public let utf8Output: [String: String] = ["LC_ALL": "en_US.UTF-8"]

private let utf8Name = TermRegex("utf-?8", caseInsensitive: true)

/// What a program PocketTerm starts for the person (a tmux server, and so
/// every shell in it) needs besides `env` to read and write UTF-8:
/// `LC_CTYPE=UTF-8` when `env` (this process's when nil) has no UTF-8
/// locale, as an app started from Finder or the Dock has none; else nothing.
public func utf8Locale(_ env: [String: String]? = nil) -> [String: String] {
  let e = env ?? ProcessInfo.processInfo.environment
  let locale = [e["LC_ALL"], e["LC_CTYPE"], e["LANG"]].compactMap { $0 }.first { !$0.isEmpty }
  if let locale, utf8Name.hasMatch(locale) { return [:] }
  return ["LC_CTYPE": "UTF-8"]
}

/// The home folder (`HOME`); empty if unset.
public func homeDir(env: [String: String]? = nil) -> String {
  (env ?? ProcessInfo.processInfo.environment)["HOME"] ?? ""
}

/// A shell word for `s`.
public func shellQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

// ------------------------------------------------------------ Dart string helpers

/// The characters of JavaScript's (and so Dart's) `\s`, for patterns: ICU's
/// `\s` lacks some of them, and its `\w`/`\d` are Unicode where Dart's are ASCII.
package let jsSpaceChars = #"\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}"#

private let dartTrimSet: CharacterSet = {
  var s = CharacterSet(charactersIn: "\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{20}\u{85}\u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
  s.insert(charactersIn: "\u{2000}"..."\u{200A}")
  return s
}()

/// Dart's `String.trim()`.
package func dartTrim(_ s: String) -> String { s.trimmingCharacters(in: dartTrimSet) }

extension String {
  /// Dart's `startsWith`: by UTF-16 code units (Swift's `hasPrefix` goes by characters).
  package func dartStartsWith(_ prefix: String) -> Bool { utf16.starts(with: prefix.utf16) }
  /// Dart's `endsWith`.
  package func dartEndsWith(_ suffix: String) -> Bool { utf16.reversed().starts(with: suffix.utf16.reversed()) }
  /// Dart's `contains` with a plain string.
  package func dartContains(_ other: String) -> Bool { other.isEmpty || range(of: other, options: .literal) != nil }
}

/// Dart's `String.replaceFirst` with a plain string.
package func dartReplaceFirst(_ s: String, _ from: String, _ to: String) -> String {
  guard let r = s.range(of: from, options: .literal) else { return s }
  return s.replacingCharacters(in: r, with: to)
}

/// Dart's `LineSplitter().convert`: lines split at `\n`, `\r\n` or `\r`, no
/// empty last line for a final break.
package func dartLines(_ s: String) -> [String] {
  var lines = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    .components(separatedBy: "\n")
  if lines.last == "" { lines.removeLast() }
  return lines
}

/// A regular expression as the Dart code uses them, on NSRegularExpression
/// (UTF-16 offsets, as Dart's). Patterns are written for ICU: `\z` for
/// Dart's `$` (ICU's also matches before a final line break), ASCII classes
/// for `\w` and `\d`, `jsSpaceChars` for `\s`.
package struct TermRegex: @unchecked Sendable {
  package let re: NSRegularExpression

  package init(_ pattern: String, caseInsensitive: Bool = false) {
    // swiftlint:disable:next force_try
    re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
  }

  /// Dart's `RegExp(r'\s+')`.
  package static let whitespace = TermRegex("[\(jsSpaceChars)]+")

  private func all(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

  private static func groups(_ m: NSTextCheckingResult, _ s: String) -> [String?] {
    let ns = s as NSString
    return (0..<m.numberOfRanges).map { i in
      let r = m.range(at: i)
      return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
  }

  package func hasMatch(_ s: String) -> Bool { re.firstMatch(in: s, range: all(s)) != nil }

  /// The first match's groups (0 is the whole match); nil when none.
  package func firstMatch(_ s: String) -> [String?]? {
    re.firstMatch(in: s, range: all(s)).map { Self.groups($0, s) }
  }

  /// Every match's groups.
  package func allMatches(_ s: String) -> [[String?]] {
    re.matches(in: s, range: all(s)).map { Self.groups($0, s) }
  }

  /// Every match's UTF-16 range.
  package func matchRanges(_ s: String) -> [Range<Int>] {
    re.matches(in: s, range: all(s)).map { $0.range.location..<($0.range.location + $0.range.length) }
  }

  /// Dart's `replaceAll(pattern, literal)`.
  package func replaceAll(_ s: String, _ with: String) -> String {
    re.stringByReplacingMatches(in: s, range: all(s), withTemplate: NSRegularExpression.escapedTemplate(for: with))
  }

  /// Dart's `replaceFirst(pattern, literal)`.
  package func replaceFirst(_ s: String, _ with: String) -> String {
    replaceFirstMapped(s) { _ in with }
  }

  /// Dart's `replaceFirstMapped`.
  package func replaceFirstMapped(_ s: String, _ f: ([String?]) -> String) -> String {
    guard let m = re.firstMatch(in: s, range: all(s)) else { return s }
    return (s as NSString).replacingCharacters(in: m.range, with: f(Self.groups(m, s)))
  }

  /// Dart's `replaceAllMapped`.
  package func replaceAllMapped(_ s: String, _ f: ([String?]) -> String) -> String {
    let ns = s as NSString
    var out = ""
    var last = 0
    for m in re.matches(in: s, range: all(s)) {
      out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
      out += f(Self.groups(m, s))
      last = m.range.location + m.range.length
    }
    return out + ns.substring(from: last)
  }

  /// Dart's `split(pattern)` for a pattern that never matches empty: every
  /// piece, empty ones included.
  package func split(_ s: String) -> [String] {
    let ns = s as NSString
    var out: [String] = []
    var last = 0
    for m in re.matches(in: s, range: all(s)) {
      out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
      last = m.range.location + m.range.length
    }
    out.append(ns.substring(from: last))
    return out
  }
}
