#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// One terminal PocketTerm Desk runs: a tmux session of its own on Desk's
/// server, in a project.
public struct DeskSession: Sendable, Hashable, Identifiable {
  /// The tmux session's name (`d-…`).
  public var name: String
  /// Its pane's window key (`tmux:pocketterm/<n>`), which the tmux host and
  /// the coding sessions' hub use too.
  public var key: String
  /// The project folder it belongs to.
  public var project: String
  /// What it was started as: `shell`, `run` (a command), or a coding agent's
  /// name (`omp`, `claude`).
  public var kind: String
  /// The name the person gave it; empty for none.
  public var label: String
  /// The folder its shell is in now.
  public var cwd: String
  /// What runs in it now (`zsh`, `npm`, `omp`).
  public var program: String
  /// The title the program in it set.
  public var title: String
  /// When it started.
  public var created: Date
  /// Its pane's process (the shell), for what it started (`Desk.listening`).
  public var pid: Int

  public var id: String { name }

  public init(
    name: String, key: String, project: String, kind: String, label: String = "", cwd: String = "",
    program: String = "", title: String = "", created: Date = Date(timeIntervalSince1970: 0), pid: Int = 0
  ) {
    self.name = name
    self.key = key
    self.project = project
    self.kind = kind
    self.label = label
    self.cwd = cwd
    self.program = program
    self.title = title
    self.created = created
    self.pid = pid
  }

  /// The coding agent running in it now, else the one it was started as.
  public var agent: Agent? { Agent.ofProgram(program) ?? Agent(rawValue: kind) }

  /// Whether a program other than its shell runs in it.
  public var busy: Bool { !program.isEmpty && !Desk.shells.contains(program) }
}

/// A project's git state, as Desk's inspector shows it.
public struct DeskGit: Sendable, Hashable {
  /// The branch checked out; empty on a detached HEAD.
  public var branch: String
  /// Files changed, staged or not, and new ones.
  public var changes: Int
  /// Commits ahead of and behind its upstream.
  public var ahead: Int
  public var behind: Int
  /// Working trees of the repository, this one included.
  public var worktrees: Int

  public init(branch: String, changes: Int, ahead: Int = 0, behind: Int = 0, worktrees: Int = 1) {
    self.branch = branch
    self.changes = changes
    self.ahead = ahead
    self.behind = behind
    self.worktrees = worktrees
  }
}

/// PocketTerm Desk's terminals: headless tmux sessions on a server of
/// PocketTerm's own (`tmux -L pocketterm`), one per terminal, each tagged with
/// its project. They outlive Desk's window and PocketTerm itself, and the
/// tmux host (Tmux.swift) lists their panes like any other, so the phone and
/// the coding sessions' hub see them as tmux panes (`tmux:pocketterm/<n>`).
///
/// As a terminal app it's "PocketTerm Desk": chosen in Settings, sessions the
/// phone starts open here. It lists no windows itself (the tmux host does);
/// `windows` only learns each pane's project, for `Terminals.windows`.
public final class Desk: TerminalHost, @unchecked Sendable {
  /// Its tmux server's socket name.
  public static let defaultSocket = "pocketterm"

  /// What counts as a shell at rest in a session.
  static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "login"]

  /// The tmux whose executable and environment it uses.
  public let tmux: Tmux
  /// Its server's socket name.
  public let socket: String
  /// Where the socket goes (`-S <dir>/<socket>`): tests; tmux's own place (`-L`) when nil.
  private let socketDir: String?

  private struct State {
    /// Each pane's project on the last look, by key.
    var projects: [String: String] = [:]
  }

  private let state = Guarded(State())

  public init(tmux: Tmux, socket: String = Desk.defaultSocket, socketDir: String? = nil) {
    self.tmux = tmux
    self.socket = socket
    self.socketDir = socketDir
  }

  public var id: String { "desk" }
  public var label: String { "PocketTerm Desk" }
  public var appName: String? { nil }
  public var caps: Set<TermCap> { allCaps }

  /// Its panes are tmux's: the tmux host answers for them.
  public func owns(_ key: String) -> Bool { false }

  /// Whether `key` is one of Desk's panes.
  public func isDesk(_ key: String) -> Bool { key.dartStartsWith("tmux:\(socket)/") }

  /// The project of Desk pane `key` on the last look; nil for another window.
  public func projectOf(_ key: String) -> String? { state.get.projects[key] }

  /// Its server, for every tmux command: no config of the person's (`-f /dev/null`, read only when the server
  /// starts), as Desk sets its own options.
  private var server: [String] {
    (socketDir.map { ["-S", Paths.join($0, socket)] } ?? ["-L", socket]) + ["-f", "/dev/null"]
  }

  /// The server's options, set before each new session (the history limit counts for panes made after it):
  /// no status line or prefix key (Desk's window is the interface), the mouse for scrolling back, 24-bit color
  /// and extended keys passed through (Shift+Enter in the agents), and the clipboard (OSC 52) out.
  private static let options: [[String]] = [
    ["set-option", "-g", "status", "off"],
    ["set-option", "-g", "prefix", "None"],
    ["set-option", "-g", "prefix2", "None"],
    ["set-option", "-g", "mouse", "on"],
    ["set-option", "-g", "history-limit", "50000"],
    ["set-option", "-g", "escape-time", "10"],
    ["set-option", "-g", "focus-events", "on"],
    ["set-option", "-g", "extended-keys", "on"],
    ["set-option", "-g", "set-clipboard", "on"],
    ["set-option", "-g", "allow-passthrough", "on"],
    ["set-option", "-g", "default-terminal", "tmux-256color"],
    ["set-option", "-g", "terminal-features[90]", "xterm-256color:RGB:extkeys:clipboard:focus:title"],
    ["set-option", "-gw", "window-size", "latest"],
    ["set-option", "-gw", "aggressive-resize", "on"],
  ]

  /// `commands` joined as one tmux command line (`a ; b`).
  private static func chain(_ commands: [[String]]) -> [String] {
    var out: [String] = []
    for (i, c) in commands.enumerated() {
      if i > 0 { out.append(";") }
      out += c
    }
    return out
  }

  private func run(_ args: [String]) async throws -> String {
    guard let exe = tmux.executable else { throw TerminalException(Tmux.notInstalled) }
    let r: ProcessResult?
    do {
      r = try await runProcess(exe, ["-u"] + server + args, environment: utf8Locale(tmux.env), timeout: tmux.timeout)
    } catch {
      throw TerminalException("tmux: \(error.message)")
    }
    guard let r else { throw TerminalException("tmux did not answer.") }
    if r.code != 0 {
      let e = dartTrim(r.err)
      if e.dartContains("no server running") || e.dartContains("error connecting to") { throw DeskStopped() }
      if e.dartContains("can't find session") || e.dartContains("no such session") { throw TerminalException(Self.gone) }
      throw TerminalException("tmux: \(e)")
    }
    return r.out
  }

  /// No server runs: Desk has no sessions.
  private struct DeskStopped: Error {}

  /// What a request about a session that ended says.
  static let gone = "That session is gone."

  static let format =
    "#{session_name}\u{1f}#{pane_id}\u{1f}#{@pocketterm_project}\u{1f}#{@pocketterm_kind}\u{1f}"
    + "#{@pocketterm_label}\u{1f}#{pane_current_path}\u{1f}#{pane_current_command}\u{1f}#{pane_title}\u{1f}"
    + "#{session_created}\u{1f}#{pane_tty}\u{1f}#{pane_pid}\u{1e}"

  /// Every session, oldest first; none when the server doesn't run. With `procs`, each one's program is its
  /// tty's foreground process (an agent shows as itself, not as the interpreter tmux names).
  public func sessions(_ procs: Procs? = nil) async throws -> [DeskSession] {
    if !tmux.installed { return [] }
    let out: String
    do {
      out = try await run(["list-panes", "-a", "-F", Self.format])
    } catch is DeskStopped {
      state.with { $0.projects = [:] }
      return []
    }
    let list = parseDeskPanes(socket, out, procs)
    state.with { s in s.projects = Dictionary(list.map { ($0.key, $0.project) }) { a, _ in a } }
    return list
  }

  public func status(_ procs: Procs) async throws -> TermStatus {
    if !tmux.installed { return TermStatus(id, label, .missing, note: Tmux.notInstalled) }
    let n = try await sessions().count
    return TermStatus(id, label, .ready, note: n == 0 ? "No sessions yet" : plural(n, "session"))
  }

  /// None: the tmux host lists Desk's panes. Learns their projects for `projectOf`.
  public func windows(_ procs: Procs) async throws -> [TermWindow] {
    _ = try await sessions()
    return []
  }

  /// A new session in `cwd` for `project`, running the login shell, which then runs `command` if given (an
  /// agent, a project's command): typed as the person would, so the shell stays when it ends.
  @discardableResult
  public func create(project: String, cwd: String? = nil, kind: String = "shell", label: String = "",
    command: String? = nil) async throws -> DeskSession
  {
    let dir = cwd ?? project
    if !directoryExists(dir) { throw TerminalException("No such folder: \(dir)") }
    let name = Self.newName()
    var commands = Self.options
    commands.append(["new-session", "-d", "-s", name, "-c", dir, "-x", "160", "-y", "48", "-P", "-F", "#{pane_id}"])
    // Later commands in the chain act on the session just made (a `=name` target isn't found until it ends).
    commands.append(["set-option", "@pocketterm_project", project])
    commands.append(["set-option", "@pocketterm_kind", kind])
    if !label.isEmpty { commands.append(["set-option", "@pocketterm_label", label]) }
    // The shell reads it once it's up: the terminal holds what's typed.
    if let command, !command.isEmpty {
      commands.append(["send-keys", "-l", "--", command])
      commands.append(["send-keys", "Enter"])
    }
    let out = try await run(["start-server", ";"] + Self.chain(commands))
    let pane = dartTrim(out).components(separatedBy: "\n").first { $0.dartStartsWith("%") } ?? ""
    guard pane.count > 1 else { throw TerminalException("tmux: \(dartTrim(out))") }
    let key = "tmux:\(socket)/\(dartReplaceFirst(pane, "%", ""))"
    state.with { $0.projects[key] = project }
    return DeskSession(
      name: name, key: key, project: project, kind: kind, label: label, cwd: dir, created: Date())
  }

  /// `d-` and the time in base 36, and a random letter or two: unique on one Mac.
  private static func newName() -> String {
    let ms = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
    return "d-\(ms)\(String(Int.random(in: 0..<1296), radix: 36))"
  }

  /// The phone's new session (Terminals.launch): a shell session in `cwd`, its own project. `command` and
  /// `into` aren't used: Desk shows it with the project's other sessions.
  public func launch(_ cwd: String, command: [String]?, into: String?) async throws -> String {
    try await create(project: cwd, cwd: cwd).key
  }

  /// Ends session `name` and everything running in it; one already gone is ended.
  public func end(_ name: String) async throws {
    do {
      _ = try await run(["kill-session", "-t", "=\(name)"])
    } catch is DeskStopped {
    } catch let e as TerminalException where e.message == Self.gone {}
  }

  /// Names session `name` (empty: no name, its program names it).
  public func rename(_ name: String, to label: String) async throws {
    _ = try await run(
      label.isEmpty
        ? ["set-option", "-u", "-t", "=\(name):", "@pocketterm_label"]
        : ["set-option", "-t", "=\(name):", "@pocketterm_label", label])
  }

  /// Moves session `name` to `project`.
  public func move(_ name: String, to project: String) async throws {
    _ = try await run(["set-option", "-t", "=\(name):", "@pocketterm_project", project])
  }

  /// The program and arguments that show session `name` in a terminal (`tmux attach`); nil without tmux.
  public func attach(_ name: String) -> (executable: String, args: [String])? {
    guard let exe = tmux.executable else { return nil }
    return (exe, ["-u"] + server + ["attach-session", "-t", "=\(name)"])
  }

  // ------------------------------------------------------------ projects

  /// `dir`'s git state; nil when it isn't in a repository or git isn't there.
  public static func git(_ dir: String) async -> DeskGit? {
    guard let git = findExecutable("git") else { return nil }
    guard let r = try? await runProcess(
      git, ["-C", dir, "status", "--porcelain=v1", "--branch", "--untracked-files=normal"], environment: utf8Output,
      timeout: .seconds(5)), r.code == 0
    else { return nil }
    var info = parseGitStatus(r.out)
    if let w = try? await runProcess(git, ["-C", dir, "worktree", "list", "--porcelain"], timeout: .seconds(5)),
      w.code == 0
    {
      info.worktrees = max(1, w.out.components(separatedBy: "\n").filter { $0.dartStartsWith("worktree ") }.count)
    }
    return info
  }

  /// The TCP ports listening in processes under `roots` (session shells' pids), by root: what a session's dev
  /// server serves on. One `lsof`.
  public static func listening(under roots: [Int], _ procs: Procs) async -> [Int: [Int]] {
    if roots.isEmpty { return [:] }
    let out = await outputOf("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], environment: utf8Output)
    let ports = parseLsofListening(out ?? "")
    if ports.isEmpty { return [:] }
    var parent: [Int: Int] = [:]
    for p in procs.all { parent[p.pid] = p.ppid }
    let rootSet = Set(roots)
    var byRoot: [Int: Set<Int>] = [:]
    for (pid, list) in ports {
      // Up the tree to a session's shell, at most 64 steps (a loop in a snapshot taken mid-change).
      var at = pid
      for _ in 0..<64 {
        if rootSet.contains(at) {
          byRoot[at, default: []].formUnion(list)
          break
        }
        guard let up = parent[at], up > 1, up != at else { break }
        at = up
      }
    }
    return byRoot.mapValues { $0.sorted() }
  }
}

/// `Desk.format`'s output (server `socket`) as sessions, oldest first: each session's first pane (a session
/// someone split in tmux shows as that one).
public func parseDeskPanes(_ socket: String, _ out: String, _ procs: Procs? = nil) -> [DeskSession] {
  var seen = Set<String>()
  var list: [DeskSession] = []
  for record in out.components(separatedBy: "\u{1e}\n") {
    let f = record.components(separatedBy: "\u{1f}")
    guard f.count == 11, f[1].dartStartsWith("%"), seen.insert(f[0]).inserted else { continue }
    let tty = dartReplaceFirst(f[9], "/dev/", "")
    let project = f[2].isEmpty ? f[5] : f[2]
    list.append(
      DeskSession(
        name: f[0], key: "tmux:\(socket)/\(dartReplaceFirst(f[1], "%", ""))", project: project,
        kind: f[3].isEmpty ? "shell" : f[3], label: f[4], cwd: f[5],
        program: procs?.foreground(tty)?.program ?? f[6], title: f[7],
        created: Date(timeIntervalSince1970: TimeInterval(Int(f[8]) ?? 0)), pid: Int(f[10]) ?? 0))
  }
  return list.sorted { $0.created < $1.created }
}

/// `git status --porcelain=v1 --branch` as a branch and its counts.
public func parseGitStatus(_ out: String) -> DeskGit {
  var info = DeskGit(branch: "", changes: 0)
  for line in out.components(separatedBy: "\n") where !line.isEmpty {
    guard line.dartStartsWith("## ") else {
      info.changes += 1
      continue
    }
    // "## main...origin/main [ahead 2, behind 1]", "## No commits yet on main", "## HEAD (no branch)".
    var head = String(line.dropFirst(3))
    if head.dartStartsWith("No commits yet on ") { head = String(head.dropFirst(18)) }
    if head.dartStartsWith("HEAD (no branch)") { continue }
    let name = head.components(separatedBy: " ")[0].components(separatedBy: "...")[0]
    info.branch = name
    if let r = head.range(of: #"ahead (\d+)"#, options: .regularExpression) {
      info.ahead = Int(head[r].dropFirst(6)) ?? 0
    }
    if let r = head.range(of: #"behind (\d+)"#, options: .regularExpression) {
      info.behind = Int(head[r].dropFirst(7)) ?? 0
    }
  }
  return info
}

/// `lsof -nP -iTCP -sTCP:LISTEN -Fpn`: each listening process's ports.
public func parseLsofListening(_ out: String) -> [Int: Set<Int>] {
  var ports: [Int: Set<Int>] = [:]
  var pid: Int?
  for line in out.components(separatedBy: "\n") where !line.isEmpty {
    switch line.first {
    case "p": pid = Int(line.dropFirst())
    case "n":
      // "n*:3000", "n127.0.0.1:5432", "n[::1]:8080".
      guard let pid, let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) else {
        continue
      }
      ports[pid, default: []].insert(port)
    default: continue
    }
  }
  return ports
}
#endif
