#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals

/// Where an agent's PocketTerm integration stands: installed, and current (the same as the copy bundled with the
/// app), or the problem that keeps it from being installed at all.
public struct IntegrationState: Equatable, Sendable {
  public var installed: Bool
  public var current: Bool
  public var problem: String?
  public init(installed: Bool, current: Bool, problem: String?) {
    self.installed = installed
    self.current = current
    self.problem = problem
  }
}

/// A coding agent found on this computer and PocketTerm in it: `state` as `Integrations.state` has it, `modsOff`
/// as `Integrations.claudeModsOff`.
public struct AgentCheck: Equatable, Sendable {
  public var state: IntegrationState
  public var modsOff: Bool
  public init(state: IntegrationState, modsOff: Bool) {
    self.state = state
    self.modsOff = modsOff
  }
}

/// What the phone hears of `check` (the live protocol's `agents`).
public func integrationOf(_ check: AgentCheck) -> AgentIntegration {
  let s = check.state
  if !s.installed || s.problem != nil { return .missing }
  if !s.current { return .outdated }
  return check.modsOff ? .off : .installed
}

/// Installing an integration failed: `message` says why, for Settings.
public struct IntegrationException: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
  public var errorDescription: String? { message }
}

/// Installs the coding agents' PocketTerm integrations (apps/pocketterm-desktop/integrations/) from the copies
/// bundled with the app: omp's extensions, Claude Code's plugin.
public final class Integrations: Sendable {
  /// Runs an executable with arguments to its end, as dart:io's `Process.run`.
  typealias Run = @Sendable (_ executable: String, _ arguments: [String]) async throws -> ProcessResult

  /// `home`: the home folder (`HOME` if nil). `bundled`: the folder holding the bundled integrations (the app's
  /// `Resources/integrations` if nil; tests point at the repo's). `claudePaths` / `ompPaths`: where `claude` /
  /// `omp` may be before a login shell is asked; the usual install places if nil. `claudeTimeout`: how long a
  /// `claude` run may take before it counts as `noAnswer` (and is killed).
  public convenience init(
    home: String? = nil, bundled: String? = nil, claudePaths: [String]? = nil, ompPaths: [String]? = nil,
    claudeTimeout: Duration = .seconds(60)
  ) {
    self.init(
      home: home, bundled: bundled, run: nil, claudePaths: claudePaths, ompPaths: ompPaths,
      claudeTimeout: claudeTimeout)
  }

  /// `run`: how programs are run (tests pass a fake); the real one, killed after `claudeTimeout`, if nil.
  init(
    home: String? = nil, bundled: String? = nil, run: Run?, claudePaths: [String]? = nil, ompPaths: [String]? = nil,
    claudeTimeout: Duration = .seconds(60)
  ) {
    let home = home ?? homeDir()
    self.home = home
    self.bundled = bundled ?? Self.bundledDir
    self.claudePaths = claudePaths
    self.ompPaths = ompPaths
    self.claudeTimeout = claudeTimeout
    self.run = run ?? Self.process(in: home, limit: claudeTimeout)
  }

  /// The app's copy of apps/pocketterm-desktop/integrations: `Contents/Resources/integrations`.
  public static var bundledDir: String {
    Bundle.main.resourceURL?.appendingPathComponent("integrations").path ?? "integrations"
  }

  public let home: String
  let bundled: String
  private let run: Run
  private let claudeTimeout: Duration

  /// Where `claude` may be: before asking a login shell. The usual install places if nil.
  private let claudePaths: [String]?

  /// Where `omp` may be, as `claudePaths` for `claude`; the usual install places if nil.
  private let ompPaths: [String]?

  /// The folders of `bundled` the app installs, as the Flutter app's pubspec listed its assets: each one's own
  /// files, not its subfolders (Claude Code's plugin without its tests/).
  static let bundledFolders = [
    "omp/",
    "claude/.claude-plugin/",
    "claude/plugins/pocketterm/.claude-plugin/",
    "claude/plugins/pocketterm/hooks/",
  ]

  /// A run killed for outlasting its limit.
  struct Overran: Error {}

  /// Programs run with UTF-8 output, on a PATH where an npm `claude` finds its Node (`agentPath`). A run still
  /// going after `limit` is killed and throws `Overran`.
  private static func process(in home: String, limit: Duration) -> Run {
    { executable, arguments in
      let path = agentPath(executable, home, ProcessInfo.processInfo.environment["PATH"] ?? "")
      guard let r = try await runProcess(executable, arguments, environment: ["PATH": path], timeout: limit) else {
        throw Overran()
      }
      return r
    }
  }

  /// The PATH `executable` runs with: its folder and the one it links into, where Node goes (`usualPlaces`), then
  /// `current`. Claude Code installed with npm is a `#!/usr/bin/env node` script, and an app started from Finder or
  /// the Dock has only `/usr/bin:/bin:/usr/sbin:/sbin`, no node.
  static func agentPath(_ executable: String, _ home: String, _ current: String) -> String {
    var dirs = [Paths.dirname(executable)]
    if let linked = realPath(executable) { dirs.append(Paths.dirname(linked)) }
    dirs += usualPlaces(home, "node").map(Paths.dirname)
    dirs += current.split(separator: ":").map(String.init)
    var seen = Set<String>()
    return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
  }

  /// What Settings says when a `claude` run outlasts its timeout.
  public static let noAnswer = "Claude Code didn't answer"

  /// What Settings calls the agent: Claude's product name in full.
  public static func name(_ agent: Agent) -> String {
    switch agent {
    case .omp: "omp"
    case .claude: "Claude Code"
    }
  }

  /// What to do while Claude Code has mods off (`claudeModsOff`): its rollout switch stays cached as off until
  /// Claude Code, logged in, fetches it again.
  public static let modsOffHint =
    "Claude Code has mods turned off for now: run claude /login, start claude once, "
    + "then type /reload-plugins in your Claude Code sessions"

  /// The oldest Claude Code whose plugins may have mods (hooks/*.ts).
  public static let minClaude = [2, 1, 287]

  /// Where omp loads extensions from in `profile` (`omp --profile`); "" is the default profile.
  public func ompDirOf(_ profile: String) -> String {
    profile.isEmpty ? "\(home)/.omp/agent/extensions" : "\(home)/.omp/profiles/\(profile)/agent/extensions"
  }

  /// The omp profiles on this computer besides the default (the folders under `~/.omp/profiles` named as omp
  /// names them), sorted.
  public func ompProfiles() -> [String] {
    let dir = "\(home)/.omp/profiles"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    return names.filter { directoryExists("\(dir)/\($0)") && isOmpProfile($0) }.dartSorted()
  }

  /// Where omp loads extensions from: the default profile's folder, then each of `ompProfiles`'.
  public var ompDirs: [String] { [ompDirOf("")] + ompProfiles().map(ompDirOf) }

  /// The marketplace Claude Code is pointed at: a stable copy of the bundled one, which it loads the plugin from in
  /// place.
  public var claudeDir: String { "\(home)/.config/pocketterm/claude-plugin" }

  private static let plugin = "pocketterm@pocketterm"

  public func state(_ agent: Agent) async throws -> IntegrationState {
    switch agent {
    case .omp:
      // Installed only where every profile has it, so a profile made since asks for Install again.
      let files = try bundledFiles("omp/")
      let dirs = ompDirs
      let installed = dirs.allSatisfy { d in files.allSatisfy { fileExists(Self.under(d, $0.path)) } }
      let current = installed && dirs.allSatisfy { Self.same(files, $0) }
      return IntegrationState(installed: installed, current: current, problem: nil)
    case .claude:
      let claude = await claude()
      if let problem = claude.problem { return IntegrationState(installed: false, current: false, problem: problem) }
      let entry: JSONObject?
      do {
        entry = try await listed(claude.path!)
      } catch let e as IntegrationException where e.message == Self.noAnswer {
        return IntegrationState(installed: false, current: false, problem: Self.noAnswer)
      }
      let installed = loadsOurs(entry) && entry?["enabled"] != .bool(false)
      let current = try installed && Self.same(bundledFiles("claude/"), claudeDir, exact: true)
      return IntegrationState(installed: installed, current: current, problem: nil)
    }
  }

  /// `agent` is on this computer: omp's folder (`~/.omp`, made the first time it runs) or its executable; Claude
  /// Code's executable, even one too old for PocketTerm (`state` says so).
  public func found(_ agent: Agent) async -> Bool {
    switch agent {
    case .omp:
      if directoryExists("\(home)/.omp") { return true }
      return await find("omp", ompPaths ?? Self.usualPlaces(home, "omp")) != nil
    case .claude:
      return await claude().path != nil
    }
  }

  /// Where `name` goes on macOS when installed by hand, by Homebrew, bun, npm (a global prefix, nvm with the newest
  /// Node first, Volta): a GUI app started from Finder or the Dock has none of these on its PATH, and a login shell
  /// has only what the profile files add, not ~/.zshrc (where bun's and nvm's installers put theirs).
  static func usualPlaces(_ home: String, _ name: String) -> [String] {
    let nvm = "\(home)/.nvm/versions/node"
    let nodes = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
      .map { "\(nvm)/\($0)" }
      .filter(directoryExists)
    func version(_ dir: String) -> [Int] {
      Paths.basename(dir).split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { Int($0) }
    }
    let newestFirst = nodes.sorted { a, b in
      let (x, y) = (version(a), version(b))
      for i in 0..<min(x.count, y.count) where x[i] != y[i] { return x[i] > y[i] }
      return x.count > y.count
    }
    var places = ["\(home)/.local/bin/\(name)"]
    if name == "claude" { places.append("\(home)/.claude/local/claude") }
    places += ["\(home)/.bun/bin/\(name)", "\(home)/.npm-global/bin/\(name)"]
    places += newestFirst.map { "\($0)/bin/\(name)" }
    places += ["\(home)/.volta/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    return places
  }

  /// Installs `agent`'s integration, or updates it to the bundled copy. Its running sessions load it when they
  /// restart (omp) or reload their plugins (Claude Code).
  public func install(_ agent: Agent) async throws {
    switch agent {
    case .omp:
      let files = try bundledFiles("omp/")
      for d in ompDirs {
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try Self.write(files, d)
      }
    case .claude:
      let claude = await claude()
      if let problem = claude.problem { throw IntegrationException(problem) }
      let exe = claude.path!
      let entry = try await listed(exe)
      let files = try bundledFiles("claude/")
      if directoryExists(claudeDir) { try FileManager.default.removeItem(atPath: claudeDir) }
      try Self.write(files, claudeDir)
      _ = try await claudeRun(
        exe,
        loadsOurs(entry)
          ? ["plugin", "marketplace", "update", "pocketterm", "--json"]
          : ["plugin", "marketplace", "add", claudeDir, "--json"])
      if let entry {
        _ = try await claudeRun(exe, ["plugin", "update", Self.plugin, "--json"])
        if entry["enabled"] == .bool(false) { _ = try await claudeRun(exe, ["plugin", "enable", Self.plugin, "--json"]) }
      } else {
        _ = try await claudeRun(exe, ["plugin", "install", Self.plugin, "--json"])
      }
    }
  }

  /// Claude Code has mods (hooks/*.ts, the plugin's whole runtime) turned off. Its rollout switch is cached as off
  /// until Claude Code, logged in, refreshes it; `claude plugin test` checks that switch before anything else and
  /// says so. False when claude can't be run at all (`state` says why).
  public func claudeModsOff() async -> Bool {
    let claude = await claude()
    guard claude.problem == nil, let path = claude.path else { return false }
    // An empty directory: with mods on there is nothing to run or write.
    var template = Array("\(NSTemporaryDirectory())pocketterm-modsXXXXXX".utf8CString)
    guard let made = mkdtemp(&template) else { return false }
    let empty = String(cString: made)
    defer { try? FileManager.default.removeItem(atPath: empty) }
    do {
      let r = try await claudeCall(path, ["plugin", "test", empty])
      return r.code != 0 && (r.err + r.out).contains("modules are turned off")
    } catch {
      // No answer: `state` says so.
      return false
    }
  }

  /// A bundled file: its path below the prefix asked for, with `/`, and its bytes.
  struct Bundled {
    let path: String
    let bytes: Data
  }

  /// The bundled files under `prefix` (one of `bundledFolders`' starts).
  func bundledFiles(_ prefix: String) throws -> [Bundled] {
    var out: [Bundled] = []
    for folder in Self.bundledFolders where folder.hasPrefix(prefix) {
      let dir = "\(bundled)/\(folder)"
      for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).dartSorted()
      where !name.hasPrefix(".") && fileKind(dir + name, followLinks: true) == .file {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: dir + name))
        out.append(Bundled(path: String((folder + name).dropFirst(prefix.count)), bytes: bytes))
      }
    }
    // A build without them would count every agent as having nothing to install.
    if out.isEmpty { throw IntegrationException("PocketTerm's copy of the integration is missing from \(bundled)") }
    return out
  }

  /// `f`, a bundled path with `/`, under `dir`.
  private static func under(_ dir: String, _ f: String) -> String { "\(dir)/\(f)" }

  /// `files` are in `dir` as they are here (`exact`: and nothing else is).
  private static func same(_ files: [Bundled], _ dir: String, exact: Bool = false) -> Bool {
    for f in files {
      let path = under(dir, f.path)
      guard fileExists(path), FileManager.default.contents(atPath: path) == f.bytes else { return false }
    }
    if !exact { return true }
    let there = (FileManager.default.subpaths(atPath: dir) ?? [])
      .filter { fileKind("\(dir)/\($0)", followLinks: true) == .file }.count
    return there == files.count
  }

  /// Writes `files` into `dir` through a rename, so a symlinked one is replaced rather than written through and
  /// nothing reads half a file.
  private static func write(_ files: [Bundled], _ dir: String) throws {
    for f in files {
      let path = under(dir, f.path)
      try FileManager.default.createDirectory(
        atPath: Paths.dirname(path), withIntermediateDirectories: true)
      let tmp = "\(path).pocketterm-tmp"
      guard FileManager.default.createFile(atPath: tmp, contents: nil),
        let handle = FileHandle(forWritingAtPath: tmp)
      else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp]) }
      defer { try? handle.close() }
      try handle.write(contentsOf: f.bytes)
      try handle.synchronize()
      guard Darwin.rename(tmp, path) == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
      }
    }
  }

  /// `name`'s executable: in `candidates` before asking a login shell (a GUI app has no login shell's PATH). The
  /// shell's answer is its last line that is a path (a profile may print something first); a shell that doesn't
  /// answer within 10 s counts as not finding it.
  private func find(_ name: String, _ candidates: [String]) async -> String? {
    if let path = candidates.first(where: fileExists) { return path }
    let run = run
    guard let r = try? await firstOf(.seconds(10), { try await run("/bin/zsh", ["-lc", "command -v \(name)"]) }),
      r.code == 0
    else { return nil }
    return r.out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .last { $0.hasPrefix("/") }
  }

  /// The `claude` executable and whether it's new enough: the usual install places first, then the shell.
  private func claude() async -> (path: String?, problem: String?) {
    guard let path = await find("claude", claudePaths ?? Self.usualPlaces(home, "claude")) else {
      return (nil, "Claude Code isn't installed")
    }
    let r: ProcessResult
    do {
      r = try await claudeCall(path, ["--version"])
    } catch let e as IntegrationException {
      return (path, e.message)
    } catch {
      return (path, "Couldn't run Claude Code: \(error)")
    }
    guard let m = r.out.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
      let major = Int(m.1), let minor = Int(m.2), let patch = Int(m.3)
    else { return (path, "Couldn't run Claude Code: \(Self.message(r))") }
    let (minMajor, minMinor, minPatch) = (Self.minClaude[0], Self.minClaude[1], Self.minClaude[2])
    let tooOld = major != minMajor ? major < minMajor : (minor != minMinor ? minor < minMinor : patch < minPatch)
    if tooOld {
      let min = Self.minClaude.map(String.init).joined(separator: ".")
      return (path, "Claude Code \(m.0) is too old: update it to \(min) or later")
    }
    return (path, nil)
  }

  /// Claude Code's record of PocketTerm's plugin, if it has one.
  private func listed(_ claude: String) async throws -> JSONObject? {
    let r = try await claudeRun(claude, ["plugin", "list", "--json"])
    guard let list = JSON.tryParse(r.out)?.array else {
      throw IntegrationException("Claude Code's plugin list isn't JSON: \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return list.compactMap(\.object).first { $0["id"]?.string == Self.plugin }
  }

  /// `entry` loads from `claudeDir` (not from a marketplace elsewhere that is also called pocketterm, such as a
  /// checkout of this repo).
  private func loadsOurs(_ entry: JSONObject?) -> Bool {
    guard let folder = entry?["readFromFolder"]?.string else { return false }
    return Paths.equals(folder, "\(claudeDir)/plugins/pocketterm")
  }

  private func claudeRun(_ claude: String, _ args: [String]) async throws -> ProcessResult {
    let r = try await claudeCall(claude, args)
    if r.code != 0 { throw IntegrationException(Self.message(r)) }
    return r
  }

  /// `claude` run with `args`; `noAnswer` once it outlasts `claudeTimeout`.
  private func claudeCall(_ claude: String, _ args: [String]) async throws -> ProcessResult {
    let run = run
    do {
      guard let r = try await firstOf(claudeTimeout, { try await run(claude, args) }) else {
        throw IntegrationException(Self.noAnswer)
      }
      return r
    } catch is Overran {
      throw IntegrationException(Self.noAnswer)
    }
  }

  /// What a failed run said: the `message` of its `--json` line, else stderr.
  static func message(_ r: ProcessResult) -> String {
    let last = r.out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? ""
    if let m = JSON.tryParse(last)?["message"]?.string { return m }
    let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    return err.isEmpty ? "exit code \(r.code)" : err
  }
}

/// `body`'s result, or nil once `limit` has passed first (Dart's `Future.timeout`): `body` isn't waited for then,
/// even one that ignores cancellation.
func firstOf<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T? {
  let race = Race<T>()
  return try await withCheckedThrowingContinuation { done in
    race.lock.lock()
    race.done = done
    race.tasks = [
      Task {
        do { race.finish(.success(try await body())) } catch { race.finish(.failure(error)) }
      },
      Task {
        try? await Task.sleep(for: limit)
        if !Task.isCancelled { race.finish(.success(nil)) }
      },
    ]
    race.lock.unlock()
  }
}

/// `firstOf`'s two tasks: whichever finishes first answers, and the other is cancelled.
private final class Race<T: Sendable>: @unchecked Sendable {
  let lock = NSLock()
  var done: CheckedContinuation<T?, Error>?
  var tasks: [Task<Void, Never>] = []

  func finish(_ result: Result<T?, Error>) {
    lock.lock()
    let done = done
    self.done = nil
    let tasks = tasks
    lock.unlock()
    guard let done else { return }
    for t in tasks { t.cancel() }
    done.resume(with: result)
  }
}
#endif
