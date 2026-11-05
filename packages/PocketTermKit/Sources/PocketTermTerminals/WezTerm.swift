#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// WezTerm, through `wezterm cli` against each running GUI's socket
/// (`~/.local/share/wezterm/gui-sock-<pid>`). Window keys:
/// `wezterm:<gui pid>/<pane id>`; its window `wezterm:<gui pid>/w<window id>`
/// and its tab `wezterm:<gui pid>/t<tab id>`, as `cli list` tells them.
open class WezTerm: TerminalHost, @unchecked Sendable {
  private let given: String?
  private let dir: String

  private struct State {
    var found: String?
    /// The release the installed wezterm told, by its path and modification time.
    var asked: (exe: String, at: Date, release: Int?)?
  }

  private let state = Guarded(State())

  public init(executable: String? = nil, socketDir: String? = nil, home: String? = nil) {
    given = executable
    dir = socketDir ?? "\(home ?? homeDir())/.local/share/wezterm"
  }

  /// Looked for again while it isn't found: WezTerm installed while
  /// PocketTerm runs (Settings or the setup checklist installs it) counts.
  private var exe: String? {
    if let given { return given }
    if let found = state.get.found { return found }
    let found = findExecutable("wezterm", extra: ["/Applications/WezTerm.app/Contents/MacOS/wezterm"])
    state.with { $0.found = found }
    return found
  }

  open var id: String { "wezterm" }
  open var label: String { "WezTerm" }
  open var appName: String? { "WezTerm" }
  open var bundleId: String? { "com.github.wez.wezterm" }
  open var caps: Set<TermCap> { allCaps }
  open var limits: String { "" }

  open func owns(_ key: String) -> Bool { key.dartStartsWith("wezterm:") }

  public var installed: Bool {
    guard let exe else { return false }
    return fileExists(exe)
  }

  private static let guiSocket = TermRegex(#"^gui-sock-([0-9]+)\z"#)

  /// GUI pid → its socket, in the folder's order, for each socket whose GUI
  /// still runs (when `procs` tell).
  private func sockets(_ procs: Procs?) -> [(pid: String, socket: String)] {
    guard directoryExists(dir) else { return [] }
    var out: [(pid: String, socket: String)] = []
    for name in listNames(dir) ?? [] {
      guard let pid = Self.guiSocket.firstMatch(name)?[1] else { continue }
      if let procs, procs.byPid(Int(pid) ?? -1) == nil { continue }
      out.append((pid, Paths.join(dir, name)))
    }
    return out
  }

  /// What a WezTerm too old for a command PocketTerm sends says.
  public static let tooOld = "WezTerm is too old: update it."

  /// The most UTF-8 bytes of text one `send-text` carries: it goes on the
  /// command line.
  public static let typeBytes = 8000

  private static let logPrefix = TermRegex(
    "^[0-9:.]+[\(jsSpaceChars)]+ERROR[\(jsSpaceChars)]+[^\(jsSpaceChars)]+[\(jsSpaceChars)]+>[\(jsSpaceChars)]*")
  private static let reason = TermRegex(#"reason: "(?:Error: )?((?:[^"\\]|\\.)*)""#)

  /// `wezterm cli` with `args` on the GUI behind `socket`; killed when it
  /// hasn't answered in five seconds.
  private func cli(_ socket: String, _ args: [String]) async throws -> String {
    guard let exe else { throw TerminalException("WezTerm is not installed.") }
    let p: Subprocess
    do {
      p = try Subprocess.start(exe, ["cli", "--no-auto-start"] + args, environment: ["WEZTERM_UNIX_SOCKET": socket])
    } catch {
      throw TerminalException("WezTerm: \(error.message)")
    }
    guard let code = await p.exitCode(within: .seconds(5)) else {
      p.kill()
      throw TerminalException("WezTerm did not answer.")
    }
    if code != 0 {
      let e = dartTrim(await p.stderr())
      if e.dartContains("no such pane") || e.dartContains("is not valid")
        || (e.dartContains("pane") && e.dartContains("not found"))
      {
        throw TerminalException("That window is gone.")
      }
      // A command or flag this WezTerm doesn't have: the GUI is fine.
      if e.dartContains("unrecognized subcommand") || e.dartContains("unexpected argument") {
        throw TerminalException(Self.tooOld)
      }
      // Its GUI quit and left the socket behind.
      if e.dartContains("failed to connect") { throw TerminalException("WezTerm isn't running.") }
      // Its last line, without the log's time and level, or the reason the
      // GUI gave.
      let last = Self.logPrefix.replaceFirst(e.components(separatedBy: "\n").last!, "")
      let reason = Self.reason.firstMatch(last)?[1]
      throw TerminalException("WezTerm: \(reason ?? last)")
    }
    // Anything malformed reads as U+FFFD rather than failing the answer.
    return await p.stdout()
  }

  private static let keyPattern = TermRegex(#"^wezterm:([0-9]+)/([0-9]+)\z"#)
  private static let windowPattern = TermRegex(#"^wezterm:([0-9]+)/w([0-9]+)\z"#)

  private func parse(_ key: String) throws -> (socket: String, pane: String) {
    guard let m = Self.keyPattern.firstMatch(key), let pid = m[1], let pane = m[2],
      let socket = sockets(nil).first(where: { $0.pid == pid })?.socket
    else { throw TerminalException("That window is gone.") }
    return (socket, pane)
  }

  open func status(_ procs: Procs) async throws -> TermStatus {
    if !installed { return TermStatus(id, label, .missing) }
    if let release = await release(), release < Self.minRelease {
      return TermStatus(
        id, label, .setup, note: "WezTerm \(release) is too old for PocketTerm: update it to \(Self.minRelease) or later"
      )
    }
    if sockets(procs).isEmpty { return TermStatus(id, label, .idle, note: "Not running") }
    let n = try await windows(procs).count
    return TermStatus(id, label, .ready, note: plural(n, "window"))
  }

  /// The oldest WezTerm release (its date) whose `wezterm cli` has all
  /// PocketTerm uses: kill-pane came in 20230326-111934-3666303c.
  public static let minRelease = 20_230_326

  /// The release date of the installed wezterm, asked once per version of
  /// the file (an update in place is asked again); nil when it doesn't say.
  private func release() async -> Int? {
    guard let exe else { return nil }
    guard let modified = (try? FileManager.default.attributesOfItem(atPath: exe))?[.modificationDate] as? Date else {
      return nil
    }
    if let asked = state.get.asked, asked.exe == exe, asked.at == modified { return asked.release }
    let out = (try? await runProcess(exe, ["--version"], timeout: .seconds(5)))??.out
    let release = out.flatMap(weztermRelease)
    state.with { $0.asked = (exe, modified, release) }
    return release
  }

  open func windows(_ procs: Procs) async throws -> [TermWindow] {
    var out: [TermWindow] = []
    for (pid, socket) in sockets(procs) {
      let json: String
      do {
        json = try await cli(socket, ["list", "--format", "json"])
      } catch is TerminalException {
        continue
      }
      out += parseWezTermList(pid, json, procs: procs)
    }
    // The foreground program's own folder, where the shell's report is older.
    let cwds = await Procs.cwds(out.compactMap { procs.foreground($0.tty)?.pid })
    return out.map { w in
      guard let pid = procs.foreground(w.tty)?.pid, let cwd = cwds[pid] else { return w }
      var w = w
      w.cwd = cwd
      return w
    }
  }

  open func lines(_ key: String, history: Bool) async throws -> [String] {
    let (socket, pane) = try parse(key)
    return screenLines(
      try await cli(
        socket, ["get-text", "--pane-id", pane, "--escapes"] + (history ? ["--start-line", "-10000"] : [])))
  }

  open func plainScreen(_ key: String) async throws -> String {
    let (socket, pane) = try parse(key)
    return dartTrimRight(try await cli(socket, ["get-text", "--pane-id", pane]))
  }

  open func colors(_ key: String) async throws -> JSONObject? { nil }

  /// `--no-paste`: as typed, not a bracketed paste.
  private func write(_ key: String, _ bytes: String) async throws {
    let (socket, pane) = try parse(key)
    _ = try await cli(socket, ["send-text", "--pane-id", pane, "--no-paste", "--", bytes])
  }

  /// In pieces of `typeBytes`, a command each.
  open func type(_ key: String, _ text: String) async throws {
    for chunk in textChunks(text, Self.typeBytes) { try await write(key, chunk) }
  }

  open func pressKeys(_ key: String, _ names: [String]) async throws {
    for (i, run) in try keyRuns(names).enumerated() {
      if i > 0 { try await Task.sleep(for: .milliseconds(40)) }
      try await write(key, run)
    }
  }

  open func close(_ key: String) async throws {
    let (socket, pane) = try parse(key)
    _ = try await cli(socket, ["kill-pane", "--pane-id", pane])
  }

  /// With `into` (`wezterm:<gui pid>/w<id>`), a new tab in that window;
  /// otherwise, or if that window is gone, a new window (WezTerm comes to
  /// the front for it, and the app that was in front gets it back). A
  /// WezTerm not running is started in the background, and its first
  /// window is the new one.
  open func launch(_ cwd: String, command: [String]?, into: String?) async throws -> String {
    if !directoryExists(cwd) { throw TerminalException("No such folder: \(cwd)") }
    var sockets = sockets(await Procs.snapshot())
    let fresh = sockets.isEmpty
    if fresh {
      _ = try? await runProcess("/usr/bin/open", ["-g", "-a", "WezTerm"])
      var i = 0
      while i < 40 && sockets.isEmpty {
        try await Task.sleep(for: .milliseconds(250))
        sockets = self.sockets(await Procs.snapshot())
        i += 1
      }
      if sockets.isEmpty { throw TerminalException("WezTerm didn't start.") }
    }
    // The GUI holding `into`, else the newest one.
    let target = Self.windowPattern.firstMatch(into ?? "")
    let (pid, socket) = sockets.last(where: { $0.pid == target?[1] }) ?? sockets.last!
    let panes = JSON.tryParse(try await cli(socket, ["list", "--format", "json"]))?.array ?? []
    if fresh && command == nil && panes.count == 1 {
      let key = "wezterm:\(pid)/\(jsonText(panes[0]["pane_id"]))"
      try await type(key, " cd -- \(shellQuote(cwd)) && clear\r")
      return key
    }
    let window: String? =
      target != nil && target?[1] == pid && panes.contains(where: { jsonText($0["window_id"]) == target?[2] })
      ? target?[2] : nil
    let spawn = {
      try await self.cli(
        socket,
        ["spawn"] + (window.map { ["--window-id", $0] } ?? ["--new-window"]) + ["--cwd", cwd]
          + (command.map { ["--"] + $0 } ?? []))
    }
    let pane = dartTrim(window != nil ? try await spawn() : try await keepFront(app: bundleId, spawn))
    return "wezterm:\(pid)/\(pane)"
  }
}

private let bareEscape = TermRegex("%(?![0-9A-Fa-f]{2})")

/// `wezterm cli list --format json` (the GUI with pid `pid`) as windows. A
/// pane with no tty names its program by its title.
public func parseWezTermList(_ pid: String, _ json: String, procs: Procs? = nil) -> [TermWindow] {
  (JSON.tryParse(json)?.array ?? []).map { pane in
    let tty = dartReplaceFirst(pane["tty_name"]?.string ?? "", "/dev/", "")
    let title = cleanTitle(pane["title"]?.string ?? "")
    let fg = procs?.foreground(tty)
    // A `%` the shell didn't escape (a folder named `100%`) as itself.
    let cwd = fileURLPath(bareEscape.replaceAll(pane["cwd"]?.string ?? "", "%25")).map(decodePercent) ?? ""
    return TermWindow(
      key: "wezterm:\(pid)/\(jsonText(pane["pane_id"]))",
      title: title,
      tab: cleanTitle(pane["tab_title"]?.string ?? ""),
      cwd: cwd,
      program: fg?.program ?? (tty.isEmpty ? programOfTitle(title) : ""),
      focused: pane["is_active"]?.bool == true,
      app: "wezterm",
      tty: tty,
      osWindow: "wezterm:\(pid)/w\(jsonText(pane["window_id"]))",
      tabId: "wezterm:\(pid)/t\(jsonText(pane["tab_id"]))"
    )
  }
}

/// The (still percent-encoded) path of a `file:` URI, any host dropped; nil
/// for anything else.
private func fileURLPath(_ uri: String) -> String? {
  let ns = uri as NSString
  guard ns.length >= 5, ns.substring(to: 5).lowercased() == "file:" else { return nil }
  var rest = ns.substring(from: 5) as NSString
  if rest.hasPrefix("//") {
    let afterHost = rest.substring(from: 2) as NSString
    let slash = afterHost.range(of: "/")
    rest = (slash.location == NSNotFound ? "" : afterHost.substring(from: slash.location)) as NSString
  }
  let end = rest.rangeOfCharacter(from: CharacterSet(charactersIn: "?#"))
  return end.location == NSNotFound ? rest as String : rest.substring(to: end.location)
}

private let percentRun = TermRegex("(?:%[0-9A-Fa-f]{2})+")

/// `path` with its `%XX` escapes as the UTF-8 they stand for; bytes that
/// aren't UTF-8 as U+FFFD rather than an error.
func decodePercent(_ path: String) -> String {
  percentRun.replaceAllMapped(path) { m in
    let run = Array((m[0] ?? "").utf8)
    let bytes = stride(from: 0, to: run.count, by: 3).map { UInt8(String(decoding: run[$0 + 1...$0 + 2], as: UTF8.self), radix: 16)! }
    return String(decoding: bytes, as: UTF8.self)
  }
}

private let releasePattern = TermRegex(#"\b([0-9]{8})-[0-9]{6}-[0-9a-f]+\b"#)

/// The release date `wezterm --version` tells (`wezterm 20240203-110809-5046fc22`
/// → 20240203); nil for a build that tells none.
public func weztermRelease(_ version: String) -> Int? {
  releasePattern.firstMatch(version)?[1].flatMap { Int($0) }
}
#endif
