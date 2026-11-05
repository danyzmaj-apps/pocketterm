#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// A tmux client: the pane key it shows, and the title it gives the terminal
/// it runs in (empty: none).
public struct TmuxClient: Sendable, Hashable {
  public var pane: String
  public var title: String
  public init(pane: String, title: String) {
    self.pane = pane
    self.title = title
  }
}

/// tmux, whichever terminal shows it: every server of this user (the
/// default socket and any `-L` one in `$TMUX_TMPDIR/tmux-<uid>` or
/// `/private/tmp/tmux-<uid>`), through its command line. Window keys:
/// `tmux:<socket name>/<pane number>` (the pane `%n`). A pane no terminal app
/// shows sits in its session as the window (`tmux:<socket name>/s<n>`, the
/// session `$n`) and its tmux window as the tab (`tmux:<socket name>/w<n>`,
/// the window `@n`).
open class Tmux: TerminalHost, @unchecked Sendable {
  private let fixedExe: String?
  private let fixedDirs: [String]?

  /// The environment PocketTerm runs in: where tmux is looked up, and
  /// whether a server it starts needs a UTF-8 locale (`utf8Locale`); this
  /// process's when nil.
  public let env: [String: String]?

  /// How long one tmux command may take.
  public let timeout: Duration

  private struct State {
    /// Looked up until found, not once at start: tmux installed while the app
    /// runs shows up without a restart.
    var found: String?
    /// Sockets learnt from agents (their `TMUX`), by name in the order learnt,
    /// for servers in a directory not scanned.
    var known: [(name: String, path: String)] = []
    var clients: [String: TmuxClient] = [:]
    var lastSession: String?
  }

  private let state = Guarded(State())

  public init(executable: String? = nil, socketDirs: [String]? = nil, env: [String: String]? = nil,
    timeout: Duration = .seconds(5))
  {
    fixedExe = executable
    fixedDirs = socketDirs
    self.env = env
    self.timeout = timeout
  }

  private var exe: String? {
    if let fixedExe { return fixedExe }
    if let found = state.get.found, fileExists(found) { return found }
    let found = findExecutable("tmux", env: env)
    state.with { $0.found = found }
    return found
  }

  /// Listed on each look: a server's directory appears when it first starts.
  private var dirs: [String] { fixedDirs ?? Self.defaultDirs(env ?? ProcessInfo.processInfo.environment) }

  /// The clients attached on the last `windows`, by tty, so a terminal
  /// window showing tmux can give way to its pane.
  public var clients: [String: TmuxClient] {
    get { state.get.clients }
    set { state.with { $0.clients = newValue } }
  }

  /// The session `launch` made last.
  public var lastSession: String? { state.get.lastSession }

  private static func defaultDirs(_ env: [String: String]) -> [String] {
    var roots: [String] = []
    if let tmp = env["TMUX_TMPDIR"], !tmp.isEmpty { roots.append(tmp) }
    if !roots.contains("/private/tmp") { roots.append("/private/tmp") }
    var dirs: [String] = []
    for root in roots where directoryExists(root) {
      for name in listNames(root) ?? [] where name.dartStartsWith("tmux-") {
        let path = Paths.join(root, name)
        if fileKind(path) == .directory { dirs.append(path) }
      }
    }
    return dirs
  }

  public var installed: Bool {
    guard let exe else { return false }
    return fileExists(exe)
  }

  /// The tmux found (an absolute path), or nil when it isn't installed.
  public var executable: String? { installed ? exe : nil }

  open var id: String { "tmux" }
  open var label: String { "tmux" }
  open var appName: String? { nil }
  open var bundleId: String? { nil }
  open var caps: Set<TermCap> { allCaps }
  open var limits: String { "" }

  open func owns(_ key: String) -> Bool { key.dartStartsWith("tmux:") }

  /// A socket an agent named (its `TMUX`), for a server outside the
  /// directories scanned.
  public func learn(_ socketPath: String) {
    let name = socketPath.components(separatedBy: "/").last!
    guard tmuxSocketName(name) else { return }
    state.with { s in
      if let i = s.known.firstIndex(where: { $0.name == name }) {
        s.known[i].path = socketPath
      } else {
        s.known.append((name, socketPath))
      }
    }
  }

  /// Socket name → path, in the order found, for every live-looking socket we
  /// may open (a learnt one only while it's there: its server may have gone).
  /// A name found twice keeps its first path: a learnt one, then
  /// `$TMUX_TMPDIR`'s (where tmux itself looks), then `/private/tmp`'s. Its
  /// `default` is often a socket left behind by a server long gone, and
  /// letting it win hid the live server of the same name.
  private func sockets() -> [(name: String, path: String)] {
    var out = state.with { s in
      s.known.removeAll { fileKind($0.path) != .socket }
      return s.known
    }
    func put(_ name: String, _ path: String) {
      if !out.contains(where: { $0.name == name }) { out.append((name, path)) }
    }
    for dir in dirs where directoryExists(dir) {
      for name in listNames(dir) ?? [] {
        let path = Paths.join(dir, name)
        if tmuxSocketName(name) && fileKind(path) == .socket { put(name, path) }
      }
    }
    return out
  }

  /// What tmux says when it isn't installed, as an error and as its status.
  public static let notInstalled =
    "tmux is not installed. Install it with Homebrew (brew install tmux) or MacPorts (sudo port install tmux)."

  /// The most UTF-8 bytes of text one `send-keys` takes: tmux refuses a
  /// command over 16 KB ("command too long").
  public static let typeBytes = 8000

  /// tmux with `args` on server `socket`; killed when it hasn't answered
  /// within `timeout` (a server that hangs leaves no client behind each look).
  /// `-u`: names and folders come back in UTF-8 even when PocketTerm has no
  /// UTF-8 locale (started from Finder or the Dock), not with `_` for each
  /// other letter.
  private func run(_ socket: String, _ args: [String]) async throws -> String {
    guard let exe else { throw TerminalException(Self.notInstalled) }
    let p: Subprocess
    do {
      p = try Subprocess.start(exe, ["-u", "-S", socket] + args)
    } catch {
      throw TerminalException("tmux: \(error.message)")
    }
    guard let code = await p.exitCode(within: timeout) else {
      p.kill()
      throw TerminalException("tmux did not answer.")
    }
    if code != 0 {
      let e = dartTrim(await p.stderr())
      // A pane closed, a server killed, a socket deleted.
      if e.dartContains("can't find pane") || e.dartContains("no server running") || e.dartContains("error connecting to")
      {
        throw TerminalException("That window is gone.")
      }
      throw TerminalException("tmux: \(e)")
    }
    // Malformed UTF-8 reads as U+FFFD rather than failing the whole answer.
    return await p.stdout()
  }

  private static let keyPattern = TermRegex(#"^tmux:([A-Za-z0-9_.-]+)/([0-9]+)\z"#)

  private func parse(_ key: String) throws -> (socket: String, pane: String) {
    guard let m = Self.keyPattern.firstMatch(key), let name = m[1], let n = m[2],
      let path = sockets().first(where: { $0.name == name })?.path
    else { throw TerminalException("That window is gone.") }
    return (path, "%\(n)")
  }

  /// A pane a record, ended by RS and a newline, its fields apart by US: a
  /// folder's name may hold a tab or a line break, which tmux prints as is.
  static let format =
    "#{pane_id}\u{1f}#{pane_tty}\u{1f}#{pane_current_command}\u{1f}#{pane_current_path}\u{1f}#{pane_title}\u{1f}"
    + "#{window_name}\u{1f}#{session_name}\u{1f}#{pane_active}\u{1f}#{window_active}\u{1f}#{session_attached}\u{1f}"
    + "#{session_id}\u{1f}#{window_id}\u{1e}"

  /// A client a record like a pane: its tty, its pane, and the title tmux
  /// gives its terminal (`set-titles-string` as tmux expands it for that
  /// client), empty while `set-titles` is off.
  static let clientFormat = "#{client_tty}\u{1f}#{pane_id}\u{1f}#{?set-titles,#{T:set-titles-string},}\u{1e}"

  open func status(_ procs: Procs) async throws -> TermStatus {
    if !installed { return TermStatus(id, label, .missing, note: Self.notInstalled) }
    let n = try await windows(procs).count
    return TermStatus(id, label, n == 0 ? .idle : .ready, note: n == 0 ? "No tmux server running" : plural(n, "pane"))
  }

  open func windows(_ procs: Procs) async throws -> [TermWindow] {
    if !installed { return [] }
    var out: [TermWindow] = []
    var clients: [String: TmuxClient] = [:]
    for (name, path) in sockets() {
      do {
        out += parseTmuxPanes(name, try await run(path, ["list-panes", "-a", "-F", Self.format]), procs)
        let list = try await run(path, ["list-clients", "-F", Self.clientFormat])
        clients.merge(parseTmuxClients(name, list)) { _, new in new }
      } catch is TerminalException {
        // A socket left behind by a server that has gone.
        continue
      }
    }
    self.clients = clients
    return out
  }

  open func lines(_ key: String, history: Bool) async throws -> [String] {
    let (socket, pane) = try parse(key)
    return screenLines(try await run(socket, ["capture-pane", "-p", "-e", "-t", pane] + (history ? ["-S", "-"] : [])))
  }

  open func plainScreen(_ key: String) async throws -> String {
    let (socket, pane) = try parse(key)
    return dartTrimRight(try await run(socket, ["capture-pane", "-p", "-t", pane]))
  }

  open func colors(_ key: String) async throws -> JSONObject? { nil }

  /// In pieces of `typeBytes`, one `send-keys` each.
  open func type(_ key: String, _ text: String) async throws {
    let (socket, pane) = try parse(key)
    for chunk in textChunks(text, Self.typeBytes) {
      _ = try await run(socket, ["send-keys", "-t", pane, "-l", "--", chunk])
    }
  }

  open func pressKeys(_ key: String, _ names: [String]) async throws {
    if names.isEmpty { return }
    let (socket, pane) = try parse(key)
    for run in try tmuxKeyRuns(names) {
      _ = try await self.run(socket, ["send-keys", "-t", pane] + (run.literal ? ["-l", "--"] : []) + run.keys)
    }
  }

  open func close(_ key: String) async throws {
    let (socket, pane) = try parse(key)
    _ = try await run(socket, ["kill-pane", "-t", pane])
  }

  /// A detached session of its own on the default server (started if none
  /// runs): a terminal app then shows it with `tmux attach` (`attach`). A
  /// server started here keeps PocketTerm's environment for every shell in
  /// it, so it gets a UTF-8 locale should PocketTerm have none. `into` is
  /// ignored: the session is the phone's alone (closing it closes nothing of
  /// the person's), and where it shows is up to the terminal app that
  /// attaches it, which is given `into` instead.
  open func launch(_ cwd: String, command: [String]?, into: String?) async throws -> String {
    if !directoryExists(cwd) { throw TerminalException("No such folder: \(cwd)") }
    guard let exe else { throw TerminalException(Self.notInstalled) }
    let session = "pt-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))"
    let r: ProcessResult?
    do {
      r = try await runProcess(
        exe,
        ["-u", "new-session", "-d", "-s", session, "-c", cwd, "-P", "-F", "#{socket_path}\t#{pane_id}"]
          + (command ?? []),
        environment: utf8Locale(env))
    } catch {
      throw TerminalException("tmux: \(error.message)")
    }
    guard let r else { throw TerminalException("tmux did not answer.") }
    if r.code != 0 { throw TerminalException("tmux: \(dartTrim(r.err))") }
    let parts = dartTrim(r.out).components(separatedBy: "\t")
    guard parts.count == 2 else { throw TerminalException("tmux: \(dartTrim(r.out))") }
    let (path, pane) = (parts[0], parts[1])
    learn(path)
    state.with { $0.lastSession = session }
    return "tmux:\(path.components(separatedBy: "/").last!)/\(dartReplaceFirst(pane, "%", ""))"
  }

  /// What a terminal app runs to show tmux session `session`.
  public func attach(_ session: String) -> [String] { [exe ?? "tmux", "attach-session", "-t", "=\(session)"] }
}

/// This Mac's host name, as tmux gives a pane's default title.
private let localHostname: String = {
  var buf = [CChar](repeating: 0, count: 256)
  guard gethostname(&buf, buf.count) == 0 else { return "" }
  return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}()

/// tmux's `list-panes -a -F Tmux.format` output (server `socket`) as windows.
public func parseTmuxPanes(_ socket: String, _ out: String, _ procs: Procs? = nil) -> [TermWindow] {
  out.components(separatedBy: "\u{1e}\n").compactMap { record in
    let f = record.components(separatedBy: "\u{1f}")
    guard f.count == 12 else { return nil }
    let (id, tty, command, path, title, window, session) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6])
    let fg = procs?.foreground(tty)
    return TermWindow(
      key: "tmux:\(socket)/\(dartReplaceFirst(id, "%", ""))",
      // A pane's default title is the host name: its window's name says more.
      title: cleanTitle(title.isEmpty || title == localHostname ? window : title),
      tab: cleanTitle("\(session):\(window)"),
      cwd: path,
      program: fg?.program ?? command,
      focused: f[7] == "1" && f[8] == "1" && f[9] != "0",
      app: "tmux",
      tty: dartReplaceFirst(tty, "/dev/", ""),
      osWindow: "tmux:\(socket)/s\(dartReplaceFirst(f[10], "$", ""))",
      tabId: "tmux:\(socket)/w\(dartReplaceFirst(f[11], "@", ""))"
    )
  }
}

/// `list-clients -F Tmux.clientFormat` output (server `socket`) as client
/// tty → `TmuxClient`.
public func parseTmuxClients(_ socket: String, _ out: String) -> [String: TmuxClient] {
  var clients: [String: TmuxClient] = [:]
  for record in out.components(separatedBy: "\u{1e}\n") {
    let f = record.components(separatedBy: "\u{1f}")
    guard f.count == 3, f[1].dartStartsWith("%") else { continue }
    clients[dartReplaceFirst(f[0], "/dev/", "")] = TmuxClient(
      pane: "tmux:\(socket)/\((f[1] as NSString).substring(from: 1))", title: cleanTitle(f[2]))
  }
  return clients
}

/// One `send-keys` run: keys by tmux's names, or characters sent literally (`-l`).
public struct TmuxKeyRun: Sendable, Hashable {
  public var literal: Bool
  public var keys: [String]
  public init(literal: Bool, keys: [String]) {
    self.literal = literal
    self.keys = keys
  }
}

private let ctrlLetter = TermRegex(#"^ctrl\+[a-z]\z"#)

/// kitty's key names as tmux's `send-keys` runs: tmux's names where it has
/// them (so it sends what the program in the pane expects), in one run;
/// a character goes literally (`-l`) in a run of its own, as tmux would
/// read `;` or a word like `Up` as something else. Shift+Enter is Alt+Enter
/// (M-Enter): tmux sends Shift+Enter like Enter unless extended keys are on.
public func tmuxKeyRuns(_ names: [String]) throws -> [TmuxKeyRun] {
  var runs: [TmuxKeyRun] = []
  func add(_ key: String, literal: Bool) {
    if let last = runs.last, last.literal == literal {
      runs[runs.count - 1].keys.append(key)
    } else {
      runs.append(TmuxKeyRun(literal: literal, keys: [key]))
    }
  }
  for n in names {
    let named: String? =
      switch n {
      case "enter", "return": "Enter"
      case "esc", "escape": "Escape"
      case "tab": "Tab"
      case "shift+tab": "BTab"
      case "space": "Space"
      case "backspace": "BSpace"
      case "delete": "DC"
      case "up": "Up"
      case "down": "Down"
      case "left": "Left"
      case "right": "Right"
      case "home": "Home"
      case "end": "End"
      case "page_up", "pageup": "PPage"
      case "page_down", "pagedown": "NPage"
      case "shift+enter", "alt+enter": "M-Enter"
      case _ where ctrlLetter.hasMatch(n): "C-\((n as NSString).substring(from: 5))"
      default: nil
      }
    if let named {
      add(named, literal: false)
    } else if n.unicodeScalars.count == 1 {
      add(n, literal: true)
    } else {
      throw TerminalException("Unknown key: \(n)")
    }
  }
  return runs
}
#endif
