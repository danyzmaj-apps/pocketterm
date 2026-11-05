#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// Ghostty (1.3 and later), through its AppleScript dictionary (macOS asks
/// once whether PocketTerm may control Ghostty). Its terminals give an id, a
/// title and a folder; its `text:` action writes bytes to one as typed
/// (its `input text` would paste); new windows take a folder and a command
/// and stay behind. It has no tty to tell and no way to read a screen but
/// through the clipboard or a file it opens, so its windows can't be read;
/// the phone's sessions there run in tmux when it's installed. Window keys:
/// `ghostty:<terminal UUID>`; its window `ghostty:w<window id>` and its tab
/// `ghostty:t<tab id>`, the stable ids Ghostty's AppleScript gives them.
open class Ghostty: TerminalHost, @unchecked Sendable {
  public let appPath: String
  private let appleScript: AppleScript?

  /// Ghostty tells no tty, so the ones of windows PocketTerm opened (and of
  /// windows an agent named its tty in, or tied to their tmux client) are
  /// kept here: key → `ttys012`.
  private let ttys = Guarded([String: String]())

  /// `appleScript`: the osascript runner; the terminals' shared one if nil.
  public init(appPath: String = "/Applications/Ghostty.app", appleScript: AppleScript? = nil) {
    self.appPath = appPath
    self.appleScript = appleScript
  }

  open var id: String { "ghostty" }
  open var label: String { "Ghostty" }
  open var appName: String? { "Ghostty" }
  open var bundleId: String? { "com.mitchellh.ghostty" }
  open var caps: Set<TermCap> { ghosttyCaps }
  open var limits: String { "Ghostty can't share its screen." }

  open func owns(_ key: String) -> Bool { key.dartStartsWith("ghostty:") }

  public var installed: Bool { directoryExists(appPath) }
  private func running(_ procs: Procs) -> Bool { procs.running("\(appPath)/Contents/MacOS/") }

  private func osa(_ script: String, _ args: [String] = []) async throws -> String {
    try await (appleScript ?? sharedAppleScript).run(label, bundleId!, script, args)
  }

  private static let terminalKey = TermRegex(#"^ghostty:([0-9A-Fa-f-]{36})\z"#)

  private func terminal(_ key: String) throws -> String {
    guard let id = Self.terminalKey.firstMatch(key)?[1] else { throw TerminalException("That window is gone.") }
    return id
  }

  /// Runs `body` on the terminal of `key`, with `t` set to it. A Ghostty
  /// that has quit isn't started again for a window it no longer has.
  private func on(_ key: String, _ body: String, _ args: [String] = []) async throws -> String {
    do {
      return try await osa(
        #"""
        on run argv
          if application id "com.mitchellh.ghostty" is not running then error "Ghostty isn't running." number -600
          tell application "Ghostty"
            set t to first terminal whose id is (item 1 of argv)
        \#(body)
          end tell
          return ""
        end run
        """#,
        [try terminal(key)] + args)
    } catch let e as AutomationDenied {
      throw e
    } catch let e as TerminalException {
      if e.message.dartContains("-1719") || e.message.dartContains("-1728") || e.message == "\(label) isn't running." {
        throw TerminalException("That window is gone.")
      }
      throw e
    }
  }

  /// A terminal a record, ended by RS and a newline, its fields apart by US:
  /// a title or a folder's name may hold a tab or a line break. Nothing when
  /// Ghostty isn't running: it quit since the process snapshot that said it
  /// was, and a `tell` would start it again, with no window.
  static let list = #"""
    if application id "com.mitchellh.ghostty" is not running then return ""
    set sep to ASCII character 31
    set eol to (ASCII character 30) & linefeed
    set out to ""
    tell application "Ghostty"
      set focusedId to ""
      try
        set focusedId to id of focused terminal of selected tab of front window
      end try
      repeat with w in windows
        repeat with b in tabs of w
          repeat with t in terminals of b
            set out to out & (id of t) & sep & (name of t) & sep & (working directory of t) & sep & (name of b) & sep & ((id of t) is focusedId) & sep & (id of w) & sep & (id of b) & eol
          end repeat
        end repeat
      end repeat
      set out to out & "front" & sep & frontmost
    end tell
    return out
    """#

  open func status(_ procs: Procs) async throws -> TermStatus {
    if !installed { return TermStatus(id, label, .missing) }
    if !running(procs) { return TermStatus(id, label, .idle, note: "Not running") }
    do {
      let n = try await windows(procs).count
      return TermStatus(id, label, .limited, note: "\(plural(n, "window")) · \(limits)")
    } catch let e as AutomationDenied {
      return TermStatus(id, label, .setup, note: e.message, fix: .automation)
    } catch let e as AutomationPending {
      return TermStatus(id, label, .setup, note: e.message)
    } catch let e as TerminalException {
      // Before 1.3 Ghostty had no scripting.
      return TermStatus(id, label, .limited, note: "Needs Ghostty 1.3 or later (\(e.message))")
    }
  }

  /// Its terminals; those whose tty is known (`launch`, `learn`) with it
  /// and their foreground program, and that program's folder where Ghostty
  /// tells none (a window opened with a command, or before its shell's
  /// first prompt).
  open func windows(_ procs: Procs) async throws -> [TermWindow] {
    if !running(procs) { return [] }
    let all = parseGhosttyList(try await osa(Self.list))
    let listed = Set(all.map(\.key))
    let known = ttys.with { t in
      t = t.filter { listed.contains($0.key) }
      return t
    }
    var front: [String: Proc] = [:]
    for w in all {
      if let tty = known[w.key], let p = procs.foreground(tty) { front[w.key] = p }
    }
    let cwds = await Procs.cwds(all.filter { $0.cwd.isEmpty }.compactMap { front[$0.key]?.pid })
    return all.map { w in
      guard let tty = known[w.key] else { return w }
      var w = w
      if w.cwd.isEmpty { w.cwd = front[w.key].flatMap { cwds[$0.pid] } ?? "" }
      w.program = front[w.key]?.program ?? ""
      w.tty = tty
      return w
    }
  }

  /// Through Ghostty's `text:` action: bytes to the program as if typed.
  private func write(_ key: String, _ bytes: String) async throws {
    _ = try await on(key, "    perform action (item 2 of argv) on t", ["text:\(ghosttyText(bytes))"])
  }

  /// The most UTF-8 bytes of text one script types: its argument, four
  /// bytes per control character once escaped, stays well within a
  /// command line's 1 MB.
  public static let typeBytes = 32000

  /// In pieces of `typeBytes`, a script each.
  open func type(_ key: String, _ text: String) async throws {
    for chunk in textChunks(text, Self.typeBytes) { try await write(key, chunk) }
  }

  open func pressKeys(_ key: String, _ names: [String]) async throws {
    for (i, run) in try keyRuns(names).enumerated() {
      if i > 0 { try await Task.sleep(for: .milliseconds(40)) }
      try await write(key, run)
    }
  }

  open func lines(_ key: String, history: Bool) async throws -> [String] {
    throw TerminalException("\(label) can't share its screen.")
  }

  open func plainScreen(_ key: String) async throws -> String {
    throw TerminalException("\(label) can't share its screen.")
  }

  open func colors(_ key: String) async throws -> JSONObject? { nil }

  /// The ttys of Ghostty's terminals now (`ghosttySurfaceTtys`).
  public func surfaceTtys(_ procs: Procs) -> Set<String> {
    ghosttySurfaceTtys(procs, procs.pidOf("\(appPath)/Contents/MacOS/"))
  }

  /// `key`'s tty is `tty` (an agent there said so, or its tmux client runs there).
  public func learn(_ key: String, _ tty: String) { ttys.with { $0[key] = dartReplaceFirst(tty, "/dev/", "") } }

  /// The window on `tty`, when it's one whose tty is known.
  public func byTty(_ tty: String) -> String? {
    let t = dartReplaceFirst(tty, "/dev/", "")
    return ttys.get.first { $0.value == t }?.key
  }

  /// What runs on its tty ends first where the tty is known (Ghostty would
  /// ask on the Mac whether to close a window something runs in; with
  /// nothing left it closes it itself). Ghostty comes to the front when it
  /// closes a window while in the background (or starts, below): the app
  /// that was in front gets it back.
  open func close(_ key: String) async throws {
    try await keepFront(app: bundleId) {
      let tty = ttys.with { $0.removeValue(forKey: key) }
      if let tty {
        func onTty() async -> [Int32] {
          let out = await outputOf("/bin/ps", ["-t", tty, "-o", "pid="]) ?? ""
          return TermRegex.whitespace.split(out).compactMap { Int32($0) }
        }
        for pid in await onTty() { kill(pid, SIGHUP) }
        var i = 0
        while i < 20, !(await onTty()).isEmpty {
          try await Task.sleep(for: .milliseconds(100))
          i += 1
        }
        try await Task.sleep(for: .milliseconds(200))
      }
      do {
        _ = try await on(key, "    close t")
      } catch let e as TerminalException {
        // Closed by itself once its shell ended.
        if tty == nil || e.message != "That window is gone." { throw e }
      }
    }
  }

  /// With `into` (`ghostty:w<id>`), a new tab in `cwd` in that window;
  /// otherwise, or if that window is gone, a new window (it stays behind the
  /// app in front); running the shell, or `command` in place of it. Ghostty
  /// comes to the front for a new window (the app that was in front gets it
  /// back), not for a tab.
  open func launch(_ cwd: String, command: [String]?, into: String?) async throws -> String {
    if !directoryExists(cwd) { throw TerminalException("No such folder: \(cwd)") }
    let before = surfaceTtys(await Procs.snapshot())
    let window = into.flatMap { $0.dartStartsWith("ghostty:w") ? ($0 as NSString).substring(from: 9) : nil } ?? ""
    let out = try await keepFront(app: bundleId) {
      try await osa(
        #"""
        on run argv
          set sep to ASCII character 9
          tell application "Ghostty"
            set cfg to new surface configuration
            set initial working directory of cfg to (item 1 of argv)
            if (item 2 of argv) is not "" then set command of cfg to (item 2 of argv)
            repeat with w in windows
              if (id of w) is (item 3 of argv) then
                set b to new tab in w with configuration cfg
                return id of focused terminal of b
              end if
            end repeat
            set w to new window with configuration cfg
            return id of focused terminal of selected tab of w
          end tell
        end run
        """#,
        [cwd, command.map { $0.map(shellQuote).joined(separator: " ") } ?? "", window])
    }
    let key = "ghostty:\(out)"
    // Its tty: the one new among Ghostty's terminals (not known as another
    // window's) whose processes are in `cwd`; another window starting
    // meanwhile adds one too.
    for _ in 0..<50 {
      let procs = await Procs.snapshot()
      let added = surfaceTtys(procs).subtracting(before).subtracting(ttys.get.values)
      let tty =
        added.isEmpty
        ? nil
        : ghosttyNewTty(added, procs, await Procs.cwds(procs.all.filter { added.contains($0.tty) }.map(\.pid)), cwd)
      if let tty {
        ttys.with { $0[key] = tty }
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    return key
  }

  /// The terminal in folder `cwd` an `agent` on `tty` runs in, when its tty
  /// isn't one known: the one terminal there (the same folder by another
  /// path, through a symlink, counts: a shell tells the path it was given,
  /// an agent the real one); else, of those not `claimed` by other sessions
  /// and not known to be on another tty, the one left, or the one whose
  /// title is the session's (what `agent` sets: its `title`, or the folder's
  /// name while it has none). None there: the one whose title is the
  /// session's among those Ghostty tells no folder for (opened with a
  /// command, or before their shell's first prompt) and whose tty isn't
  /// known. More than one: nil.
  public func byFolder(
    _ cwd: String, _ procs: Procs, tty: String = "", title: String = "", agent: Agent = .omp,
    claimed: Set<String> = []
  ) async -> String? {
    if cwd.isEmpty { return nil }
    let all: [TermWindow]
    do {
      all = try await windows(procs)
    } catch {
      return nil
    }
    let t = dartReplaceFirst(tty, "/dev/", "")
    let real = realPath(cwd) ?? cwd
    let here = all.filter { w in
      (w.cwd == cwd || w.cwd == "/private\(cwd)" || (!w.cwd.isEmpty && (realPath(w.cwd) ?? w.cwd) == real))
        && (w.tty.isEmpty || t.isEmpty || w.tty == t)
    }
    if here.count == 1 { return here[0].key }
    let name = dartTrim(title).isEmpty ? Paths.basename(cwd) : dartTrim(title)
    func named(_ w: TermWindow) -> Bool { !claimed.contains(w.key) && agent.sessionOfTitle(w.title) == name }
    if here.isEmpty {
      let folderless = all.filter { $0.cwd.isEmpty && $0.tty.isEmpty && named($0) }
      return folderless.count == 1 ? folderless[0].key : nil
    }
    let open = here.filter { !claimed.contains($0.key) }
    if open.count == 1 { return open[0].key }
    let titled = open.filter(named)
    return titled.count == 1 ? titled[0].key : nil
  }
}

private let ghosttyCaps: Set<TermCap> = [.type, .line, .keys, .close]

/// The ttys of the terminals of the Ghostty at pid `ghostty`: each one's
/// first process, a child of Ghostty, or (Ghostty 1.3 double-forks it) an
/// orphan whose parent is gone, which is Ghostty's `login -flp <user>` or
/// the command it ran as a login one (`-zsh`, `-/bin/sleep 9`). A process
/// whose parent is still there (another terminal's shell, a tmux pane) never
/// counts.
public func ghosttySurfaceTtys(_ procs: Procs, _ ghostty: Int?) -> Set<String> {
  guard let ghostty else { return [] }
  let alive = Set(procs.all.map(\.pid))
  func orphanRoot(_ p: Proc) -> Bool {
    p.ppid > 1 && !alive.contains(p.ppid) && (p.args.dartStartsWith("/usr/bin/login -f") || p.args.dartStartsWith("-"))
  }
  return Set(procs.all.filter { !$0.tty.isEmpty && ($0.ppid == ghostty || orphanRoot($0)) }.map(\.tty))
}

/// Of the new terminals' `ttys`, the one a launch in `folder` made: the one
/// whose processes (`procs`, with their working directories `cwds`) are in
/// `folder` (by its real path, as a process tells it); with no working
/// directory known (no lsof), the only one. Else nil: none yet, or
/// another window starting meanwhile can't be told apart.
public func ghosttyNewTty(_ ttys: Set<String>, _ procs: Procs, _ cwds: [Int: String], _ folder: String) -> String? {
  func real(_ path: String) -> String { realPath(path) ?? path }
  let on = procs.all.filter { ttys.contains($0.tty) }
  if !on.contains(where: { cwds[$0.pid] != nil }) { return ttys.count == 1 ? ttys.first : nil }
  let want = real(folder)
  var here = Set<String>()
  for p in on {
    if let cwd = cwds[p.pid], cwd == want || real(cwd) == want { here.insert(p.tty) }
  }
  return here.count == 1 ? here.first : nil
}

private let leadingBreak = TermRegex(#"^(\r\n|\n|\r)"#)

/// The listing script's output: a record per terminal (id, title, folder,
/// tab title, focused, window id, tab id; apart by US, each ended by RS and
/// a line break), then `front<US>true|false`.
public func parseGhosttyList(_ out: String) -> [TermWindow] {
  let records = out.components(separatedBy: "\u{1e}").map { dartTrimRight(leadingBreak.replaceFirst($0, "")) }
  let front = records.contains("front\u{1f}true")
  return records.compactMap { r in
    let f = r.components(separatedBy: "\u{1f}")
    guard f.count == 7, f[0] != "front" else { return nil }
    return TermWindow(
      key: "ghostty:\(f[0])",
      title: cleanTitle(f[1]),
      tab: cleanTitle(f[3]),
      cwd: f[2],
      program: "",
      focused: front && f[4] == "true",
      app: "ghostty",
      caps: ghosttyCaps,
      osWindow: "ghostty:w\(f[5])",
      tabId: "ghostty:t\(f[6])"
    )
  }
}

/// `bytes` as the argument of Ghostty's `text:` action, which reads it as
/// a Zig string literal's body: a backslash and a quote escaped, anything
/// below space (and DEL) as `\xNN`.
public func ghosttyText(_ bytes: String) -> String {
  var out = ""
  for c in bytes.unicodeScalars {
    switch c.value {
    case 0x5c: out += #"\\"#
    case 0x22: out += #"\""#
    case let v where v < 0x20 || v == 0x7f:
      let hex = String(v, radix: 16)
      out += "\\x" + (hex.count < 2 ? "0" + hex : hex)
    default: out.unicodeScalars.append(c)
    }
  }
  return out
}
#endif
