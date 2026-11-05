#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals

/// A started program as the Tailscale CLI runs (dart:io's `Process`): its output as it comes, its exit, a kill.
public protocol RunningProcess: AnyObject, Sendable {
  /// Chunks of stdout and stderr as they arrive; ends once both have closed.
  var output: AsyncStream<Data> { get }
  func exitCode() async -> Int32
  func kill()
}

/// Starts a program, as dart:io's `Process.start` does; tests hand in a fake.
public typealias StartProcess = @Sendable (_ executable: String, _ arguments: [String]) async throws -> any RunningProcess

/// A program started with posix_spawn (Subprocess), [environment] added to this process's.
final class SpawnedProcess: RunningProcess {
  let output: AsyncStream<Data>
  private let process: Subprocess

  init(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws {
    let (stream, sink) = AsyncStream<Data>.makeStream()
    output = stream
    let open = Guarded(2)
    process = try Subprocess.start(executable, arguments, environment: environment) { _, chunk in
      if !chunk.isEmpty { sink.yield(chunk); return }
      let left = open.with { n -> Int in
        n -= 1
        return n
      }
      if left == 0 { sink.finish() }
    }
  }

  func exitCode() async -> Int32 { await process.exitCode() }
  func kill() { process.kill() }
}

/// Where Tailscale stands on this computer.
public enum TailscaleState: Sendable, Equatable {
  /// No Tailscale CLI here: install Tailscale.
  case missing
  /// Installed, but not running or switched off: open Tailscale.
  case stopped
  /// Running, but signed out of its tailnet: open Tailscale and sign in.
  case loggedOut
  /// Connected to its tailnet.
  case running
}

/// What `tailscale status --json` says about this computer.
public struct TailscaleStatus: Sendable, Equatable {
  public init(_ state: TailscaleState, dnsName: String? = nil, https: Bool = false) {
    self.state = state
    self.dnsName = dnsName
    self.https = https
  }

  public let state: TailscaleState

  /// This computer's MagicDNS name without the trailing dot (`mac.tail1234.ts.net`); nil without MagicDNS.
  public let dnsName: String?

  /// HTTPS certificates are on for the tailnet (CertDomains isn't empty).
  public let https: Bool

  /// Where `tailscale serve` publishes this computer: `https://<dnsName>`.
  public var url: URL? { dnsName.flatMap { URL(string: "https://\($0)") } }
}

/// How `tailscale serve` went.
public struct ServeResult: Sendable, Equatable {
  private init(enableLink: URL? = nil, error: String? = nil, taken: String? = nil) {
    self.enableLink = enableLink
    self.error = error
    self.taken = taken
  }

  public static let ok = ServeResult()
  public static func needsHttps(_ link: URL) -> ServeResult { ServeResult(enableLink: link) }
  public static func failed(_ error: String) -> ServeResult { ServeResult(error: error) }

  /// Port 443 of this computer's Tailscale name already serves something else ([taken] says what), so nothing was
  /// changed.
  public static func taken(_ what: String) -> ServeResult {
    ServeResult(
      error:
        "Tailscale already serves \(what) on this computer’s HTTPS port (443). PocketTerm leaves it alone: "
        + "remove it with tailscale serve --https=443 off, or serve it on another port, then check again.",
      taken: what)
  }

  /// The tailnet has HTTPS (Serve) off: the page that turns it on.
  public let enableLink: URL?

  /// What the CLI said when it failed otherwise.
  public let error: String?

  /// What already uses port 443 ([taken]).
  public let taken: String?

  public var isOk: Bool { enableLink == nil && error == nil }
}

/// What port 443 of this computer's Tailscale name serves ([Tailscale.port443]).
public enum Serving: Sendable, Equatable {
  /// Nothing.
  case nothing
  /// This app's built-in server, and nothing else.
  case ours
  /// Something else, in words: it stays.
  case elsewhere(String)
  /// The CLI couldn't say (it failed, or took too long): nothing is changed.
  case unknown
}

/// The Tailscale CLI: whether Tailscale runs here and under which name, and `tailscale serve`, which publishes the
/// built-in server at `https://<this computer>.<tailnet>.ts.net` to the tailnet only.
public final class Tailscale: Sendable {
  public init(start: StartProcess? = nil, locate: (@Sendable () -> String?)? = nil) {
    self.start = start ?? Tailscale.startCli
    self.locate = locate ?? { Tailscale.findCli() }
  }

  /// The Mac app's binary is the CLI only when started from a terminal; started by an app (no TERM), it tries to
  /// open its window and prints nothing. `TAILSCALE_BE_CLI` tells it to act as the CLI either way.
  private static let startCli: StartProcess = { executable, arguments in
    try SpawnedProcess(executable, arguments, environment: cliEnvironment)
  }

  static let cliEnvironment = ["TAILSCALE_BE_CLI": "1"]

  private let start: StartProcess
  private let locate: @Sendable () -> String?

  /// Where to get Tailscale.
  public static let download = URL(string: "https://tailscale.com/download")!

  /// The admin console's DNS page: MagicDNS and HTTPS certificates.
  public static let adminDns = URL(string: "https://login.tailscale.com/admin/dns")!

  /// The Mac app's CLI (App Store and standalone builds alike).
  public static let macCli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

  /// The CLI: `POCKETTERM_TAILSCALE` when set in a test build ([testHooks]; tool/smoke: a stand-in, so a throwaway
  /// copy never changes the Mac's Serve settings), the app's own, else `tailscale` on the PATH (a GUI app's PATH is
  /// short, so Homebrew's folders too: the open source build). Nil when Tailscale isn't installed.
  public static func findCli(
    env: [String: String]? = nil, hooks: [String: String]? = nil, exists: ((String) -> Bool)? = nil
  ) -> String? {
    let isFile = exists ?? { FileManager.default.fileExists(atPath: $0) }
    let vars = env ?? ProcessInfo.processInfo.environment
    if let standIn = (hooks ?? testHooks())["POCKETTERM_TAILSCALE"], !standIn.isEmpty { return standIn }
    if isFile(macCli) { return macCli }
    let dirs = (vars["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty } + [
      "/opt/homebrew/bin", "/usr/local/bin",
    ]
    for dir in dirs {
      let path = dir.hasSuffix("/") ? "\(dir)tailscale" : "\(dir)/tailscale"
      if isFile(path) { return path }
    }
    return nil
  }

  /// Whether Tailscale runs here, signed in, and this computer's name.
  public func status() async -> TailscaleStatus {
    guard let cli = locate() else { return TailscaleStatus(.missing) }
    do {
      let run = try await run(cli, ["status", "--json"], timeout: 10)
      return Tailscale.parseStatus(run.out)
    } catch {
      debugLog("PocketTerm: tailscale status: \(error)")
      return TailscaleStatus(.stopped)
    }
  }

  /// [out] from its first `{` (all of it without one), as Dart's `indexOf('{').clamp(0, length)` cut it.
  private static func fromBrace(_ out: String) -> String {
    out.firstIndex(of: "{").map { String(out[$0...]) } ?? out
  }

  /// `tailscale status --json`'s output read; anything else (the service isn't running) reads as stopped.
  static func parseStatus(_ out: String) -> TailscaleStatus {
    guard let json = JSON.tryParse(fromBrace(out)), let map = json.object else { return TailscaleStatus(.stopped) }
    let state: TailscaleState =
      switch map["BackendState"]?.string {
      case "Running": .running
      case "NeedsLogin", "NeedsMachineAuth": .loggedOut
      default: .stopped
      }
    guard state == .running else { return TailscaleStatus(state) }
    var name = map["Self"]?["DNSName"]?.string ?? ""
    while name.hasSuffix(".") { name.removeLast() }
    let certs = map["CertDomains"]?.array
    return TailscaleStatus(state, dnsName: name.isEmpty ? nil : name, https: !(certs ?? []).isEmpty)
  }

  /// Publishes `http://127.0.0.1:<port>` at `https://<this computer's name>` on the tailnet, in the background
  /// (`tailscale serve --bg`), so it lasts until [unserve]. A tailnet with HTTPS off answers with the page that turns
  /// it on: the CLI prints it and waits, so it's stopped there. Something else already served on 443 stays: it's
  /// never replaced, and nothing is changed while `tailscale serve status` can't say. [earlier]: the port this app's
  /// server had before (its entry is this app's to move).
  public func serve(_ port: Int, earlier: Int? = nil) async -> ServeResult {
    guard let cli = locate() else { return .failed("Tailscale isn’t installed.") }
    var ours: Set<Int> = [port]
    if let earlier { ours.insert(earlier) }
    switch await port443(ours) {
    case .elsewhere(let what): return .taken(what)
    case .unknown: return .failed(Tailscale.unreadable)
    case .nothing, .ours: break
    }
    let run: (code: Int32?, out: String)
    do {
      run = try await self.run(
        cli, ["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"], timeout: 30,
        stopWhen: { Tailscale.enableLinkIn($0) != nil })
    } catch {
      return .failed("\(error)")
    }
    if let link = Tailscale.enableLinkIn(run.out) { return .needsHttps(link) }
    if run.code == 0 { return .ok }
    return .failed(Tailscale.serveError(run.out))
  }

  /// What `tailscale serve` printed when it failed, for the person.
  static func serveError(_ out: String) -> String {
    // The open source build's daemon runs as root and lets only its operator change Serve.
    if out.lowercased().contains("access denied") {
      return "Tailscale didn’t let PocketTerm change its Serve settings. Run sudo tailscale set --operator=$USER "
        + "once in a terminal, then check again."
    }
    let said =
      out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
      .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
    return said.isEmpty ? "tailscale serve failed." : said
  }

  /// Why PocketTerm changed nothing: `tailscale serve status` didn't answer.
  public static let unreadable =
    "PocketTerm couldn’t read Tailscale’s Serve settings, so it changed nothing. It checks again by itself."

  /// What serves on port 443 now (`tailscale serve status --json`): this app's built-in server at one of [ours],
  /// something else, nothing, or unknown when the CLI can't say.
  public func port443(_ ours: Set<Int>) async -> Serving {
    guard let cli = locate() else { return .unknown }
    do {
      let run = try await run(cli, ["serve", "status", "--json"], timeout: 10)
      return run.code == 0 ? Tailscale.readServing(run.out, ours) : .unknown
    } catch {
      debugLog("PocketTerm: tailscale serve status: \(error)")
      return .unknown
    }
  }

  private static let proxyPattern = try! NSRegularExpression(
    pattern: #"^(?:https?://)?(?:(?:127\.0\.0\.1|localhost):)?(\d+)/?$"#)

  /// A proxy to 127.0.0.1 at one of [ours]: the ports this app's own built-in server has had. Only those: another
  /// PocketTerm on this Mac (a second user, a second copy) serves on a port of the same range, and its entry isn't
  /// this one's to replace.
  private static func isOurs(_ proxy: String, _ ours: Set<Int>) -> Bool {
    let s = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let m = proxyPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
      let r = Range(m.range(at: 1), in: s), let port = Int(s[r])
    else { return false }
    return ours.contains(port)
  }

  /// [json] (`tailscale serve status --json`, a ServeConfig, or `null` when nothing is served) read for port 443:
  /// what serves there that isn't the built-in server at one of [ours], in words; nil when nothing else does.
  static func servedElsewhere(_ json: String, _ ours: Set<Int>) -> String? {
    if case .elsewhere(let what) = readServing(json, ours) { return what }
    return nil
  }

  /// [json] (`tailscale serve status --json`) read for port 443; output that isn't a ServeConfig is unknown.
  static func readServing(_ json: String, _ ours: Set<Int>) -> Serving {
    guard let config = JSON.tryParse(fromBrace(json)) else { return .unknown }
    if config == .null { return .nothing }
    guard let root = config.object else { return .unknown }
    var oursSeen = false
    func look(_ c: JSONObject) -> String? {
      if let tcp = c["TCP"]?["443"]?.object {
        if let to = tcp["TCPForward"]?.string, !to.isEmpty { return "a TCP forward to \(to)" }
        if tcp["HTTP"] == .bool(true) { return "plain HTTP" }
      }
      if let web = c["Web"]?.object {
        // Sorted: Dart walked the map in the CLI's order, which a Swift dictionary doesn't keep.
        for key in web.keys.sorted() where key.hasSuffix(":443") {
          guard let handlers = web[key]?["Handlers"]?.object else { continue }
          for mount in handlers.keys.sorted() {
            let h = handlers[mount]!
            if mount == "/", let proxy = h["Proxy"]?.string, isOurs(proxy, ours) {
              oursSeen = true
              continue
            }
            let what = h["Proxy"]?.string ?? h["Path"]?.string ?? "a page"
            return mount == "/" ? what : "\(what) at \(mount)"
          }
        }
      }
      if let sessions = c["Foreground"]?.object {
        for key in sessions.keys.sorted() {
          if let s = sessions[key]?.object, let what = look(s) { return what }
        }
      }
      return nil
    }
    if let what = look(root) { return .elsewhere(what) }
    return oursSeen ? .ours : .nothing
  }

  private static let enableLinkPattern = try! NSRegularExpression(pattern: #"https://login\.tailscale\.com/\S+"#)

  /// The login.tailscale.com page `tailscale serve` asks for, if it does.
  static func enableLinkIn(_ out: String) -> URL? {
    guard let m = enableLinkPattern.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
      let r = Range(m.range, in: out)
    else { return nil }
    return URL(string: String(out[r]))
  }

  /// The page that turns HTTPS on for this tailnet, as `tailscale serve` names it (it asks for it on a tailnet with
  /// HTTPS off); the admin console's DNS page when it names none. A serve that went through (HTTPS was on after all)
  /// is taken back at once.
  public func enableHttpsLink(port: Int = 47900) async -> URL {
    let result = await serve(port)
    if result.isOk { await unserve(port) }
    return result.enableLink ?? Tailscale.adminDns
  }

  /// Stops publishing the built-in server at [port] (`tailscale serve --https=443 off`), only while port 443 serves
  /// it and nothing else: something else there would go with it, and nothing is changed while `tailscale serve
  /// status` can't say.
  public func unserve(_ port: Int) async {
    guard let cli = locate() else { return }
    guard await port443([port]) == .ours else { return }
    do {
      _ = try await run(cli, ["serve", "--https=443", "off"], timeout: 5)
    } catch {
      debugLog("PocketTerm: tailscale serve off: \(error)")
    }
  }

  /// Shows Tailscale's app, to start it or sign in.
  public func open() async {
    do {
      let process = try await start("/usr/bin/open", ["-a", "Tailscale"])
      Task.detached { _ = await process.exitCode() }
    } catch {
      debugLog("PocketTerm: Tailscale not opened: \(error)")
    }
  }

  /// Runs [cli] with [args]: its exit code and what it printed (both streams). Stopped (no code) after [timeout]
  /// seconds, or once [stopWhen] likes the output so far.
  private func run(
    _ cli: String, _ args: [String], timeout: TimeInterval, stopWhen: (@Sendable (String) -> Bool)? = nil
  ) async throws -> (code: Int32?, out: String) {
    let process = try await start(cli, args)
    let buffer = Guarded(Data())
    let code: Int32? = await withTaskGroup(of: Int32?.self) { group in
      group.addTask {
        for await chunk in process.output {
          let text = buffer.with { all -> String in
            all.append(chunk)
            return String(decoding: all, as: UTF8.self)
          }
          if stopWhen?(text) == true { return nil }
        }
        if Task.isCancelled { return nil }
        return await process.exitCode()
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        // Killed, so the reader above ends too.
        if !Task.isCancelled { process.kill() }
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      if first == nil { process.kill() }
      return first
    }
    return (code, String(decoding: buffer.get, as: UTF8.self))
  }
}
#endif
