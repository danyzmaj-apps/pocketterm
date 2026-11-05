#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// One terminal app (or tmux) on this Mac, behind the interface the bridge
/// uses. Keys are always those `owns` accepts.
public protocol TerminalHost: AnyObject, Sendable {
  /// The key prefix family and the id in Settings: kitty, tmux, wezterm,
  /// iterm, ghostty.
  var id: String { get }

  /// How people name it: "WezTerm".
  var label: String { get }

  /// What its windows can do.
  var caps: Set<TermCap> { get }

  /// What a window of it can't do, said once for Settings and the phone
  /// (empty: nothing missing).
  var limits: String { get }

  /// The name of its app in `lsappinfo visibleProcessList` (nil: not an app).
  var appName: String? { get }

  /// Its app's bundle id, for `keepFront` (nil: not an app).
  var bundleId: String? { get }

  func owns(_ key: String) -> Bool

  /// Is it installed / running / reachable; never launches it.
  func status(_ procs: Procs) async throws -> TermStatus

  /// Every window, in the app's order. Throws when the app can't be asked.
  func windows(_ procs: Procs) async throws -> [TermWindow]

  /// What the window shows now (with `history`, its scrollback above
  /// too), line by line, with colors as ANSI escapes where it has them.
  func lines(_ key: String, history: Bool) async throws -> [String]

  /// What the window shows now as plain text.
  func plainScreen(_ key: String) async throws -> String

  /// The window's colors (`{fg, bg, palette}` as 0xRRGGBB), when the app tells.
  func colors(_ key: String) async throws -> JSONObject?

  /// Types `text` as keystrokes (not as a paste), without Enter.
  func type(_ key: String, _ text: String) async throws

  /// Presses `names` in order: kitty's key names (`keyBytes` knows them).
  func pressKeys(_ key: String, _ names: [String]) async throws

  /// Closes the window and what runs in it.
  func close(_ key: String) async throws

  /// A new window in `cwd` running the login shell, or `command` (argv)
  /// instead; or, with `into` (one of this app's `TermWindow.osWindow`s), a
  /// new tab in that window, and a new window when that one is gone. Its
  /// key. Never takes the focus where the app allows.
  func launch(_ cwd: String, command: [String]?, into: String?) async throws -> String
}

extension TerminalHost {
  public var limits: String { "" }
  public var bundleId: String? { nil }

  public func lines(_ key: String, history: Bool) async throws -> [String] {
    throw TerminalException("\(label) can't share its screen.")
  }

  public func lines(_ key: String) async throws -> [String] { try await lines(key, history: false) }

  public func plainScreen(_ key: String) async throws -> String {
    throw TerminalException("\(label) can't share its screen.")
  }

  public func colors(_ key: String) async throws -> JSONObject? { nil }

  public func type(_ key: String, _ text: String) async throws {
    throw TerminalException("\(label) can't type into its windows.")
  }

  public func pressKeys(_ key: String, _ names: [String]) async throws {
    throw TerminalException("\(label) can't press keys in its windows.")
  }

  public func close(_ key: String) async throws {
    throw TerminalException("\(label) can't close its windows.")
  }

  public func launch(_ cwd: String) async throws -> String { try await launch(cwd, command: nil, into: nil) }

  /// Types `text`, a line break (`\n`, `\r\n` or `\r`: a lone CR typed would
  /// be Enter, running a half-written line) as Shift+Enter (a new line in an
  /// agent's editor; a shell runs the line), then Enter if `enter`.
  public func send(_ key: String, _ text: String, enter: Bool) async throws {
    for (i, line) in lineBreaks.split(text).enumerated() {
      if i > 0 { try await pressKeys(key, ["shift+enter"]) }
      if !line.isEmpty { try await type(key, line) }
    }
    if enter { try await pressKeys(key, ["enter"]) }
  }
}

private let lineBreaks = TermRegex(#"\r\n?|\n"#)

/// "3 windows", "1 pane".
func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

// ------------------------------------------------------------ processes

extension Procs {
  /// The Mac's processes now: one `ps`; none when it can't run.
  public static func snapshot() async -> Procs {
    let out = await outputOf("/bin/ps", ["-Ao", "pid=,ppid=,pgid=,tpgid=,tty=,stat=,args="], environment: utf8Output)
    return Procs(parsePs(out ?? ""))
  }

  /// Working directories of `pids`, in one `lsof`.
  public static func cwds(_ pids: some Sequence<Int>) async -> [Int: String] {
    var seen = Set<Int>()
    let list = pids.filter { seen.insert($0).inserted }
    if list.isEmpty { return [:] }
    let out = await outputOf(
      "/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", list.map(String.init).joined(separator: ",")],
      environment: utf8Output)
    return parseLsofCwd(out ?? "")
  }
}

/// An executable named `name` in the usual places (a GUI app's PATH is
/// short), or in `extra`; nil if none.
public func findExecutable(_ name: String, extra: [String] = [], env: [String: String]? = nil) -> String? {
  let path = (env ?? ProcessInfo.processInfo.environment)["PATH"] ?? ""
  let dirs = path.components(separatedBy: ":").filter { !$0.isEmpty }
    + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
  for f in dirs.map({ "\($0)/\(name)" }) + extra where fileExists(f) { return f }
  return nil
}

// ------------------------------------------------------------ AppleScript

/// Runs `script` with osascript on `app` (bundle id `bundle`), `args` as its
/// `on run argv`; its output without the final newline (`AppleScript.run`).
public func runAppleScript(_ app: String, _ bundle: String, _ script: String, _ args: [String] = []) async throws
  -> String
{
  try await sharedAppleScript.run(app, bundle, script, args)
}

/// The terminals' AppleScript: what macOS answered holds for all of them.
let sharedAppleScript = AppleScript()

/// osascript, for apps macOS asks the person about before PocketTerm may control
/// them (Privacy & Security → Automation). Until they answer, an Apple Event
/// waits in the app, which carries it out once they say yes, long after the
/// phone gave up. So an app is sent nothing before it's known to be allowed:
/// its answer is looked up first (without asking), and while there is none
/// macOS is asked once, by a helper that waits for the answer, and every
/// script throws `AutomationPending` at once instead of piling up. A script
/// that doesn't finish within `timeout` is killed. An app that answered a
/// script is allowed: it isn't looked up again (a look that hangs, as it
/// can for Ghostty, would otherwise hold up every script by `lookFor`).
public final class AppleScript: Sendable {
  /// Starts osascript; tests hand in their own.
  package typealias Start = @Sendable (_ executable: String, _ arguments: [String]) async throws -> Subprocess

  package let start: Start

  /// How long a script may run.
  public let timeout: Duration

  /// A script to an app not known to be allowed (it wasn't running, so the
  /// script started it) that runs this long is checked for macOS asking.
  public let stuckAfter: Duration

  /// How long the helper waits for the person's answer (macOS gives up on
  /// its question after two minutes).
  public let askFor: Duration

  /// How long a look at an app's answer may take.
  public let lookFor: Duration

  /// Apps macOS let PocketTerm control, and those it's asking about, by bundle id.
  private let state = Guarded((allowed: Set<String>(), asking: Set<String>()))

  // AEDeterminePermissionToAutomateTarget's answers.
  private static let wouldAsk = -1744
  private static let refused = -1743

  public convenience init(
    timeout: Duration = .seconds(20), stuckAfter: Duration = .seconds(2), askFor: Duration = .seconds(180),
    lookFor: Duration = .seconds(5)
  ) {
    self.init(
      start: { try Subprocess.start($0, $1) }, timeout: timeout, stuckAfter: stuckAfter, askFor: askFor,
      lookFor: lookFor)
  }

  package init(
    start: @escaping Start, timeout: Duration = .seconds(20), stuckAfter: Duration = .seconds(2),
    askFor: Duration = .seconds(180), lookFor: Duration = .seconds(5)
  ) {
    self.start = start
    self.timeout = timeout
    self.stuckAfter = stuckAfter
    self.askFor = askFor
    self.lookFor = lookFor
  }

  /// Whether PocketTerm may send Apple Events to `bundle`: 0 yes, -1743 no,
  /// -1744 not answered yet, -600 not running; nil if it can't be told.
  /// With `ask`, macOS asks the person (if it hasn't) and this waits for
  /// their answer. osascript's answer counts as PocketTerm's: macOS asks about
  /// the app that started it.
  public func consent(_ bundle: String, ask: Bool = false) async throws -> Int? {
    let r = try await osascript(
      ["-l", "JavaScript", "-e", Self.consentScript, bundle, ask ? "ask" : "look"], ask ? askFor : lookFor)
    guard let r, r.code == 0 else { return nil }
    return Int(dartTrim(r.out))
  }

  private static let consentScript = #"""
    ObjC.import('CoreServices');
    ObjC.bindFunction('AEDeterminePermissionToAutomateTarget', ['int', ['void *', 'unsigned int', 'unsigned int', 'bool']]);
    function run(argv) {
      const app = $.NSAppleEventDescriptor.descriptorWithBundleIdentifier(argv[0]);
      return $.AEDeterminePermissionToAutomateTarget(app.aeDesc, 0x2a2a2a2a, 0x2a2a2a2a, argv[1] === 'ask');
    }
    """#

  /// macOS asks about `bundle` (once at a time); a yes is remembered. A
  /// helper that fails to start leaves the next script to look again.
  private func ask(_ bundle: String) {
    guard state.with({ $0.asking.insert(bundle).inserted }) else { return }
    Task {
      if (try? await consent(bundle, ask: true)) == 0 { _ = state.with { $0.allowed.insert(bundle) } }
      _ = state.with { $0.asking.remove(bundle) }
    }
  }

  public func run(_ app: String, _ bundle: String, _ script: String, _ args: [String] = []) async throws -> String {
    if state.get.asking.contains(bundle) { throw AutomationPending(app: app) }
    var known = state.get.allowed.contains(bundle)
    if !known {
      switch try await consent(bundle) {
      case 0:
        _ = state.with { $0.allowed.insert(bundle) }
        known = true
      case Self.wouldAsk:
        ask(bundle)
        throw AutomationPending(app: app)
      case Self.refused:
        throw AutomationDenied(app: app)
      default:
        break
      }
    }
    let stuck: (@Sendable () async -> Bool)?
    if known {
      stuck = nil
    } else {
      stuck = { [self] in
        let answer: Int? = try? await consent(bundle)
        return answer == Self.wouldAsk
      }
    }
    let r = try await osascript(["-e", script] + args, timeout, stuck: stuck)
    guard let r else { throw TerminalException("\(app) did not answer.") }
    if r.code == Self.asked {
      ask(bundle)
      throw AutomationPending(app: app)
    }
    if r.code == 0 {
      _ = state.with { $0.allowed.insert(bundle) }
      return r.out.dartEndsWith("\n") ? String(r.out.utf16.dropLast())! : r.out
    }
    if r.err.dartContains("\(Self.refused)") {
      _ = state.with { $0.allowed.remove(bundle) }
      throw AutomationDenied(app: app)
    }
    if r.err.dartContains("\(Self.wouldAsk)") {
      _ = state.with { $0.allowed.remove(bundle) }
      ask(bundle)
      throw AutomationPending(app: app)
    }
    if r.err.dartContains("-600") || r.err.dartContains("-609") { throw TerminalException("\(app) isn't running.") }
    throw TerminalException("\(app): \(dartTrim(executionError.replaceFirst(r.err, "")))")
  }

  private let executionError = TermRegex("^.*execution error: ")

  /// `osascript`'s code for a script killed because macOS was asking.
  private static let asked: Int32 = -1

  /// osascript with `args`; nil if it didn't finish within `limit`. Killed
  /// then, or once it has run `stuckAfter` and `stuck` says it waits on
  /// macOS asking (code `asked`).
  private func osascript(
    _ args: [String], _ limit: Duration, stuck: (@Sendable () async -> Bool)? = nil
  ) async throws -> ProcessResult? {
    let p: Subprocess
    do {
      p = try await start("/usr/bin/osascript", args)
    } catch let e as ProcessLaunchError {
      throw TerminalException("osascript: \(e.message)")
    } catch {
      throw TerminalException("osascript: \(error)")
    }
    let began = ContinuousClock.now
    var code: Int32? = stuck == nil ? nil : await p.exitCode(within: stuckAfter)
    if code == nil, let stuck, await stuck() {
      p.kill()
      return ProcessResult(code: Self.asked, out: "", err: "")
    }
    if code == nil { code = await p.exitCode(within: limit - (ContinuousClock.now - began)) }
    guard let code else {
      p.kill()
      return nil
    }
    return ProcessResult(code: code, out: await p.stdout(), err: await p.stderr())
  }
}

// ------------------------------------------------------------ focus

/// The app in front (its pid and bundle id), if it can be told.
public func frontApp() async -> (pid: Int, bundle: String)? {
  guard let front = await outputOf("/usr/bin/lsappinfo", ["front"]) else { return nil }
  let asn = dartTrim(front)
  if asn.isEmpty { return nil }
  let info = await outputOf("/usr/bin/lsappinfo", ["info", "-only", "pid", "-only", "bundleid", asn]) ?? ""
  guard let pid = frontPid.firstMatch(info)?[1].flatMap({ Int($0) }),
    let bundle = frontBundle.firstMatch(info)?[1]
  else { return nil }
  return (pid, bundle)
}

private let frontPid = TermRegex(#""pid"[\#(jsSpaceChars)]*=[\#(jsSpaceChars)]*([0-9]+)"#)
private let frontBundle = TermRegex(#""CFBundleIdentifier"="([^"]+)""#)

/// Runs `action` (a new window, a closed one: things that can bring a
/// terminal app to the front), and gives the focus back to the app that had
/// it whenever `app` (a bundle id; nil: any app) takes it, from just
/// before `action` until a second and a half after it, worked or not; by
/// pid, so a second instance of the same app (a second kitty) counts too.
/// The watching runs in an osascript of its own, which starts while
/// `action` does and answers within a few hundredths of a second, so the
/// focus is gone for about a tenth of a second.
public func keepFront<T>(app: String? = nil, _ action: () async throws -> T) async rethrows -> T {
  var watch: Subprocess?
  if let before = await frontApp() {
    // The window still opens should this fail; only the focus may move.
    watch = try? Subprocess.start(
      "/usr/bin/osascript", ["-l", "JavaScript", "-e", keepFrontScript, "\(before.pid)", app ?? ""])
  }
  defer {
    if let watch {
      Task {
        try? await Task.sleep(for: .milliseconds(1500))
        watch.kill()
      }
    }
  }
  return try await action()
}

/// Activates argv[0]'s app whenever another (argv[1]'s bundle id, if any)
/// is in front; `keepFront` ends it. The run loop is turned so that
/// NSWorkspace hears about the front app changing.
private let keepFrontScript = #"""
  ObjC.import('AppKit');
  function run(argv) {
    const before = parseInt(argv[0]);
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(before);
    const ws = $.NSWorkspace.sharedWorkspace;
    const end = Date.now() + 60000;
    while (Date.now() < end) {
      $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.02));
      const front = ws.frontmostApplication;
      if (front.isNil()) continue;
      if (front.processIdentifier !== before && (argv[1] === '' || front.bundleIdentifier.js === argv[1])) {
        app.activateWithOptions(0);
      }
    }
  }
  """#

/// Terminal apps by recent use, most recent first: names as
/// `lsappinfo visibleProcessList` gives them ("kitty", "WezTerm").
public func appsByRecency() async -> [String] {
  let out = await outputOf("/usr/bin/lsappinfo", ["visibleProcessList"]) ?? ""
  return quoted.allMatches(out).map { ($0[1] ?? "").replacingOccurrences(of: "_", with: " ") }
}

private let quoted = TermRegex(#""([^"]+)""#)
#endif
