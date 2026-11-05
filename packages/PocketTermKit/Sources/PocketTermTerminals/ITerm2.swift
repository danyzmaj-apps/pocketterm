#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// iTerm2, through its AppleScript dictionary (macOS asks once whether
/// PocketTerm may control iTerm2). Its sessions (a tab, or a split pane of
/// one) tell an id, a tty and a title; `write text` sends bytes as typed (not
/// as a paste); `contents` is a session's whole text, scrollback then
/// screen, plain. A new tab doesn't take the focus, a new window does.
/// Window keys: `iterm:<session UUID>`, the UUID that ends the
/// `ITERM_SESSION_ID` (`w0t1p0:<UUID>`) of what runs in it. Its window is
/// `iterm:w<window id>` (AppleScript's window id, stable while it's open)
/// and its tab `iterm:w<window id>/t<n>`, the tab's place in that window
/// from 1: AppleScript gives a tab no id, so a tab's id changes when one
/// before it closes or it's dragged elsewhere.
open class ITerm2: TerminalHost, @unchecked Sendable {
  public let appPath: String
  private let appleScript: AppleScript?

  /// `appleScript`: the osascript runner; the terminals' shared one if nil.
  public init(appPath: String = "/Applications/iTerm.app", appleScript: AppleScript? = nil) {
    self.appPath = appPath
    self.appleScript = appleScript
  }

  open var id: String { "iterm" }
  open var label: String { "iTerm2" }
  open var appName: String? { "iTerm2" }
  open var bundleId: String? { "com.googlecode.iterm2" }
  open var caps: Set<TermCap> { itermCaps }
  open var limits: String { "iTerm2 shares its screen without colors." }

  open func owns(_ key: String) -> Bool { key.dartStartsWith("iterm:") }

  public var installed: Bool { directoryExists(appPath) }
  private func running(_ procs: Procs) -> Bool { procs.running("\(appPath)/Contents/MacOS/iTerm2") }

  private func osa(_ script: String, _ args: [String] = []) async throws -> String {
    try await (appleScript ?? sharedAppleScript).run(label, bundleId!, script, args)
  }

  private static let sessionKey = TermRegex(#"^iterm:([0-9A-Fa-f-]{36})\z"#)

  private func session(_ key: String) throws -> String {
    guard let id = Self.sessionKey.firstMatch(key)?[1] else { throw TerminalException("That window is gone.") }
    return id
  }

  /// Runs `body` on the session of `key`, with `s` set to it; what `body`
  /// returns, else empty. Every session's id comes in one Apple Event and is
  /// looked through here, outside the `tell` (inside it, each `item` and
  /// `count` goes to iTerm2 as an event of its own: seconds with a dozen
  /// sessions open); the session is then addressed by its window's id and
  /// its place there, and checked once more by its id. An iTerm2 that has
  /// quit isn't started again for a window it no longer has.
  private func on(_ key: String, _ body: String, _ args: [String] = []) async throws -> String {
    do {
      return try await osa(
        #"""
        on run argv
          if application id "com.googlecode.iterm2" is not running then error "iTerm2 isn't running." number -600
          repeat 3 times
            tell application id "com.googlecode.iterm2"
              set wids to id of windows
              set ids to id of sessions of tabs of windows
              set wids2 to id of windows
            end tell
            -- Paired by place: a window brought to the front in between reorders them, so read again.
            if wids is wids2 then exit repeat
          end repeat
          set found to missing value
          repeat with wi from 1 to count of ids
            set tw to item wi of ids
            repeat with ti from 1 to count of tw
              set tt to item ti of tw
              repeat with si from 1 to count of tt
                if (item si of tt) is (item 1 of argv) then set found to {item wi of wids, ti, si}
              end repeat
            end repeat
          end repeat
          if found is missing value then error "That window is gone." number -1728
          tell application id "com.googlecode.iterm2"
            set s to session (item 3 of found) of tab (item 2 of found) of window id (item 1 of found)
            if (id of s) is not (item 1 of argv) then error "That window is gone." number -1728
        \#(body)
          end tell
          return ""
        end run
        """#,
        [try session(key)] + args)
    } catch let e as AutomationDenied {
      throw e
    } catch let e as TerminalException {
      if e.message.dartContains("-1719") || e.message.dartContains("-1728") || e.message == "\(label) isn't running." {
        throw TerminalException("That window is gone.")
      }
      throw e
    }
  }

  /// A session a record, ended by RS and a newline, its fields apart by US
  /// (a title or a folder's name may hold a tab or a line break): id, title
  /// (the one its program set, `session.terminalWindowName`; empty if none),
  /// name (iTerm2's, as its tab shows it), tab title, tty, folder (iTerm2's
  /// `session.path`), focused, window id, tab number in that window (from
  /// 1); then `front<US>true|false`. Each property of every session comes in
  /// one Apple Event and the records are made outside the `tell` (`on` says
  /// why); a variable can't be asked of many sessions at once, so the title
  /// and the folder take an event per session, each addressed by its
  /// window's place and its own. A window opened, closed or brought to the
  /// front between those events leaves them out of step, and they're read
  /// again. Nothing when iTerm2 isn't running: it quit since the process
  /// snapshot that said it was, and a `tell` would start it again.
  static let list = #"""
    if application id "com.googlecode.iterm2" is not running then return ""
    set sep to ASCII character 31
    set eol to (ASCII character 30) & linefeed
    repeat 3 times
      tell application id "com.googlecode.iterm2"
        set focusedId to ""
        try
          set focusedId to id of current session of current window
        end try
        set ids to id of sessions of tabs of windows
        set wids to id of windows
        set nms to name of sessions of tabs of windows
        set ttys to tty of sessions of tabs of windows
        set tts to title of tabs of windows
        set isFront to frontmost
      end tell
      try
        set out to ""
        repeat with wi from 1 to count of ids
          set wid to item wi of ids
          if (count of wid) is not (count of item wi of tts) then error "out of step"
          repeat with ti from 1 to count of wid
            set bid to item ti of wid
            set bnm to item ti of item wi of nms
            set bty to item ti of item wi of ttys
            if (count of bid) is not (count of bnm) or (count of bid) is not (count of bty) then error "out of step"
            repeat with si from 1 to count of bid
              set ttl to missing value
              set cwd to missing value
              tell application id "com.googlecode.iterm2"
                tell session si of tab ti of window wi
                  try
                    set ttl to (variable named "session.terminalWindowName")
                  end try
                  try
                    set cwd to (variable named "session.path")
                  end try
                end tell
              end tell
              if ttl is missing value then set ttl to ""
              if cwd is missing value then set cwd to ""
              set out to out & (item si of bid) & sep & ttl & sep & (item si of bnm) & sep & (item ti of item wi of tts) & sep & (item si of bty) & sep & cwd & sep & ((item si of bid) is focusedId) & sep & (item wi of wids) & sep & ti & eol
            end repeat
          end repeat
        end repeat
        tell application id "com.googlecode.iterm2"
          set ids2 to id of sessions of tabs of windows
          set wids2 to id of windows
        end tell
        if ids2 is ids and wids2 is wids and (count of ids) is (count of wids) and (count of ids) is (count of nms) and (count of ids) is (count of ttys) and (count of ids) is (count of tts) then
          return out & "front" & sep & isFront
        end if
      end try
    end repeat
    error "iTerm2's windows kept changing while they were read."
    """#

  open func status(_ procs: Procs) async throws -> TermStatus {
    if !installed { return TermStatus(id, label, .missing) }
    if !running(procs) { return TermStatus(id, label, .idle, note: "Not running") }
    do {
      let n = try await windows(procs).count
      return TermStatus(id, label, .ready, note: "\(plural(n, "window")) · \(limits)")
    } catch let e as AutomationDenied {
      return TermStatus(id, label, .setup, note: e.message, fix: .automation)
    } catch let e as AutomationPending {
      return TermStatus(id, label, .setup, note: e.message)
    } catch let e as TerminalException {
      return TermStatus(id, label, .limited, note: e.message)
    }
  }

  /// Its sessions, with their foreground program and that program's folder
  /// (iTerm2's own idea of the folder where it has none).
  open func windows(_ procs: Procs) async throws -> [TermWindow] {
    if !running(procs) { return [] }
    let all = parseITermList(try await osa(Self.list)) { procs.foreground($0)?.program ?? "" }
    let cwds = await Procs.cwds(all.compactMap { procs.foreground($0.tty)?.pid })
    return all.map { w in
      var w = w
      let fg = procs.foreground(w.tty)
      w.cwd = fg.flatMap { cwds[$0.pid] } ?? w.cwd
      w.program = fg?.program ?? ""
      return w
    }
  }

  /// The session's text: its screen (the last of its rows), or with
  /// `history` its scrollback too.
  open func lines(_ key: String, history: Bool) async throws -> [String] {
    let (all, rows) = try await text(key)
    return screenLines((history ? all : Array(all.dropFirst(max(0, all.count - rows)))).joined(separator: "\n"))
  }

  open func plainScreen(_ key: String) async throws -> String {
    let (all, rows) = try await text(key)
    return dartTrimRight(all.dropFirst(max(0, all.count - rows)).joined(separator: "\n"))
  }

  /// `key`'s `contents` line by line (its scrollback, then its screen, every
  /// row of it), and how many rows its screen has. iTerm2 hands over the
  /// whole scrollback each time: there's no asking for part of it.
  private func text(_ key: String) async throws -> ([String], Int) {
    let out = try await on(key, "            return ((rows of s) as text) & linefeed & (contents of s)")
    var all = out.components(separatedBy: "\n")
    let rows = all.removeFirst()
    if let last = all.last, last.isEmpty { all.removeLast() }
    return (all, Int(rows) ?? all.count)
  }

  /// Its default colors and its 16 ANSI ones (the 240 above them are
  /// xterm's, as in iTerm2), from iTerm2's 16-bit channels.
  open func colors(_ key: String) async throws -> JSONObject? {
    let out = try await on(
      key,
      #"""
                  set out to ""
                  repeat with c in {foreground color of s, background color of s, ANSI black color of s, ANSI red color of s, ANSI green color of s, ANSI yellow color of s, ANSI blue color of s, ANSI magenta color of s, ANSI cyan color of s, ANSI white color of s, ANSI bright black color of s, ANSI bright red color of s, ANSI bright green color of s, ANSI bright yellow color of s, ANSI bright blue color of s, ANSI bright magenta color of s, ANSI bright cyan color of s, ANSI bright white color of s}
                    set out to out & (item 1 of c) & "," & (item 2 of c) & "," & (item 3 of c) & linefeed
                  end repeat
                  return out
      """#)
    return parseITermColors(out)
  }

  /// Through `write text` without its newline: bytes to the program as if
  /// typed.
  private func write(_ key: String, _ bytes: String) async throws {
    _ = try await on(key, "            tell s to write text (item 2 of argv) newline no", [bytes])
  }

  /// The most UTF-8 bytes of text one script types: its argument stays well
  /// within a command line's 1 MB.
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

  /// iTerm2 ends what runs in it without asking.
  open func close(_ key: String) async throws { _ = try await on(key, "            close s") }

  private static let windowKey = TermRegex(#"^iterm:w([0-9]+)\z"#)

  /// With `into` (`iterm:w<id>`), a new tab in `cwd` in that window;
  /// otherwise, or if that window is gone, a new window (iTerm2 comes to the
  /// front for it, and the app that was in front gets it back); running the
  /// login shell, or `command` in place of it. An iTerm2 that wasn't running
  /// is started in the background, and the one window it opens with is used.
  ///
  /// iTerm2 splits a session's command into words itself, and gets quotes
  /// wrong, so the shell line runs from a script of its own that removes
  /// itself. A folder that's gone by then leaves the shell in the home
  /// folder: a session that ends at once has iTerm2 stop everything for a
  /// warning until someone clicks it away.
  open func launch(_ cwd: String, command: [String]?, into: String?) async throws -> String {
    if !directoryExists(cwd) { throw TerminalException("No such folder: \(cwd)") }
    let fresh = !running(await Procs.snapshot())
    let script = try Self.launcher(cwd, command)
    let out: String
    do {
      out = try await keepFront(app: bundleId) {
        if fresh {
          _ = try? await runProcess("/usr/bin/open", ["-g", "-a", appPath])
          for _ in 0..<40 {
            do {
              if !parseITermList(try await osa(Self.list)).isEmpty { break }
            } catch let e as AutomationDenied {
              throw e
            } catch let e as AutomationPending {
              throw e
            } catch is TerminalException {
              // Still starting.
            }
            try await Task.sleep(for: .milliseconds(125))
          }
        }
        return try await osa(
          #"""
          on run argv
            set sep to ASCII character 9
            tell application id "com.googlecode.iterm2"
              if (item 3 of argv) is "reuse" and (count of windows) is 1 then
                set w to first window
                if (count of tabs of w) is 1 and (count of sessions of first tab of w) is 1 then return ((id of w) as text) & sep & (id of first session of first tab of w) & sep & "reused"
              end if
              repeat with w in windows
                if ((id of w) as text) is (item 2 of argv) then
                  tell w to set b to (create tab with default profile command (item 1 of argv))
                  return ((id of w) as text) & sep & (id of current session of b) & sep
                end if
              end repeat
              set w to (create window with default profile command (item 1 of argv))
              return ((id of w) as text) & sep & (id of current session of w) & sep
            end tell
          end run
          """#,
          [
            "/bin/sh \(script)",
            Self.windowKey.firstMatch(into ?? "")?[1] ?? "",
            fresh && command == nil ? "reuse" : "",
          ])
      }
    } catch {
      try? FileManager.default.removeItem(atPath: script)
      throw error
    }
    let parts = out.components(separatedBy: "\t")
    guard parts.count == 3 else { throw TerminalException("iTerm2: \(out)") }
    let key = "iterm:\(parts[1])"
    if parts[2] == "reused" {
      try? FileManager.default.removeItem(atPath: script)
      try await type(key, " cd -- \(shellQuote(cwd)) && clear\r")
    }
    return key
  }

  private static let plainPath = TermRegex(#"^[A-Za-z0-9_./-]+\z"#)

  /// The script a new session runs: into `cwd`, then the login shell (or
  /// `command`) in place of it; it removes itself first. Its path.
  private static func launcher(_ cwd: String, _ command: [String]?) throws -> String {
    var dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
    if !plainPath.hasMatch(dir) { throw TerminalException("iTerm2 can't start a script from \(dir) (TMPDIR).") }
    let path = "\(dir)/pocketterm-iterm-\(String(UInt32.random(in: 0...UInt32.max), radix: 16)).sh"
    let body =
      "rm -f -- \"$0\"\ncd -- \(shellQuote(cwd))\nexec \(command.map { $0.map(shellQuote).joined(separator: " ") } ?? #""${SHELL:-/bin/zsh}" -l"#)\n"
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
    guard fd >= 0 else { throw TerminalException("Couldn\u{2019}t create \(path): \(String(cString: strerror(errno)))") }
    defer { Darwin.close(fd) }
    let bytes = Array(body.utf8)
    guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else {
      throw TerminalException("Couldn\u{2019}t write \(path)")
    }
    return path
  }
}

private let itermCaps: Set<TermCap> = [.read, .type, .line, .keys, .close]
private let leadingBreak = TermRegex(#"^(\r\n|\n|\r)"#)
private let uuid = TermRegex(#"^[0-9A-Fa-f-]{36}\z"#)

/// The listing script's output (see `ITerm2`) as windows, without their
/// program (`ITerm2.windows` adds it). A session's title is the one its
/// program set, else iTerm2's name for it; that name and the tab's title
/// lose the ` (job)` iTerm2 adds when the job is `program` (of a tty).
public func parseITermList(_ out: String, program: ((String) -> String)? = nil) -> [TermWindow] {
  let records = out.components(separatedBy: "\u{1e}").map { dartTrimRight(leadingBreak.replaceFirst($0, "")) }
  let front = records.contains("front\u{1f}true")
  var windows: [TermWindow] = []
  for r in records {
    let f = r.components(separatedBy: "\u{1f}")
    guard f.count == 9, uuid.hasMatch(f[0]) else { continue }
    let tty = dartReplaceFirst(f[4], "/dev/", "")
    let job = program?(tty) ?? ""
    let set = cleanTitle(f[1])
    windows.append(
      TermWindow(
        key: "iterm:\(f[0])",
        title: set.isEmpty ? itermTitle(cleanTitle(f[2]), job) : set,
        tab: itermTitle(cleanTitle(f[3]), job),
        cwd: f[5],
        program: "",
        focused: front && f[6] == "true",
        app: "iterm",
        caps: itermCaps,
        tty: tty,
        osWindow: "iterm:w\(f[7])",
        tabId: "iterm:w\(f[7])/t\(f[8])"
      ))
  }
  return windows
}

/// iTerm2's name for a session or tab, `title`, without the ` (job)` it adds
/// by default when that's `program` (a login shell's `-zsh` too).
public func itermTitle(_ title: String, _ program: String) -> String {
  if program.isEmpty { return title }
  let job = TermRegex(#" \(-?"# + NSRegularExpression.escapedPattern(for: program) + #"\)\z"#)
  guard let r = job.matchRanges(title).first, r.lowerBound > 0 else { return title }
  return (title as NSString).substring(to: r.lowerBound)
}

private let rgbLine = TermRegex(
  "^[\(jsSpaceChars)]*([0-9]+)[\(jsSpaceChars)]*,[\(jsSpaceChars)]*([0-9]+)[\(jsSpaceChars)]*,[\(jsSpaceChars)]*([0-9]+)[\(jsSpaceChars)]*\\z"
)

/// The colors script's output (a line `r,g,b` of 16-bit channels each:
/// foreground, background, the 16 ANSI colors) as `{fg, bg, palette}`;
/// what's missing or unreadable as xterm's.
public func parseITermColors(_ out: String) -> JSONObject {
  let rgb = out.components(separatedBy: "\n").compactMap { line -> Int? in
    guard let m = rgbLine.firstMatch(line) else { return nil }
    return channel(m[1]!) << 16 | channel(m[2]!) << 8 | channel(m[3]!)
  }
  func xterm(_ i: Int) -> Int { Int(TermColors.xterm(i).argb & 0xFFFFFF) }
  return [
    "fg": .int(rgb.count > 0 ? rgb[0] : 0xDDDDDD),
    "bg": .int(rgb.count > 1 ? rgb[1] : 0x000000),
    "palette": .array((0..<256).map { i in .int(i < 16 && rgb.count > i + 2 ? rgb[i + 2] : xterm(i)) }),
  ]
}

/// A 16-bit color channel as 8 bits.
private func channel(_ digits: String) -> Int { Int((Double(min(max(Int(digits) ?? 0, 0), 65535)) / 257).rounded()) }
#endif
