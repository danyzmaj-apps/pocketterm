#if os(macOS)
import Combine
import Foundation
import PocketTermKit
import PocketTermTerminals

/// Where the built-in server stands, for the person: what to do next.
public enum HostState: Sendable, Equatable {
  /// Looking at Tailscale for the first time.
  case checking
  /// Tailscale isn't installed: Install.
  case noTailscale
  /// Tailscale isn't running or is switched off: Open Tailscale.
  case tailscaleOff
  /// Tailscale is signed out: Open Tailscale.
  case loggedOut
  /// The tailnet has HTTPS off (or MagicDNS): the page that turns it on.
  case httpsOff
  /// `tailscale serve` failed for another reason ([BuiltInServer.error]).
  case failed
  /// Port 443 of this computer's Tailscale name serves something else, left alone ([BuiltInServer.error] says what).
  case taken
  /// Phones reach it at [BuiltInServer.publicUrl].
  case ready
}

/// Why the server didn't start.
public enum ServerStartError: Error, Sendable, Equatable, CustomStringConvertible {
  /// Its port is taken (the sidecar's exit code 98): another port may do.
  case portTaken(String)
  /// Anything else, in the server's words.
  case failed(String)

  public var description: String {
    switch self {
    case .portTaken(let why), .failed(let why): why
    }
  }
}

/// A server that listens ([ServerSidecar.serve]).
public protocol RunningServer: AnyObject, Sendable {
  /// The port it listens on, on 127.0.0.1.
  var port: Int { get }
  /// Its exit code once it ends, asked or not.
  func exitCode() async -> Int32
  /// Stops it and waits until it has.
  func stop() async
}

/// How a server is started on a data folder, and its setup links made: the bundled `pocketterm-server` binary;
/// tests hand in their own.
public protocol ServerSidecar: Sendable {
  func serve(dataDir: URL, port: Int, relay: URL?, relayKey: Data?) async throws(ServerStartError) -> any RunningServer
  /// The setup link for computers: [publicUrl] and the server's setup token.
  func setupLink(dataDir: URL, publicUrl: String) async throws -> URL
}

/// The PocketTerm server the app bundles (apps/pocketterm-server/README.md, "Bundled in the desktop apps"), run as a
/// child process that ends with this app: its stdin is a pipe only this app holds.
public struct BundledServer: ServerSidecar {
  public init(binary: URL? = nil) {
    self.binary = binary ?? BundledServer.defaultBinary
  }

  /// `PocketTerm.app/Contents/Helpers/pocketterm-server`.
  public static var defaultBinary: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pocketterm-server")
  }

  public let binary: URL

  /// The sidecar's exit code when its port is taken.
  static let exitPortInUse: Int32 = 98

  public func serve(dataDir: URL, port: Int, relay: URL?, relayKey: Data?) async throws(ServerStartError)
    -> any RunningServer
  {
    var args = [
      "serve", "--data", dataDir.path, "--address", "127.0.0.1", "--port", "\(port)", "--exit-with-stdin",
      // tailscale serve forwards from 127.0.0.1 with the tailnet caller in X-Forwarded-For: each gets its own
      // redeem throttle instead of one shared by everyone.
      "--trust-loopback-proxy",
    ]
    if let relay { args += ["--relay", relay.absoluteString] }
    if let relayKey { args += ["--relay-key", relayKey.base64EncodedString()] }
    let child = SidecarProcess()
    do {
      try child.start(binary.path, args)
    } catch {
      throw .failed("The server didn't start: \(error)")
    }
    // The listening line, or its end, or 30 seconds. Unstructured: the loser (an exit that never comes while it
    // runs) isn't waited for.
    let outcome: Result<Int, ServerStartError> = await withCheckedContinuation { done in
      let once = OnceFlag()
      let timer = Task {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        if !Task.isCancelled, once.take() {
          done.resume(returning: .failure(.failed("The server didn't start within 30 seconds.")))
        }
      }
      let listened = Task {
        if let port = await child.listening(), once.take() {
          timer.cancel()
          done.resume(returning: .success(port))
        }
      }
      Task {
        let code = await child.exitCode()
        timer.cancel()
        listened.cancel()
        guard once.take() else { return }
        // A listening line just before the end still counts.
        if let port = child.listeningPort { return done.resume(returning: .success(port)) }
        let said = child.lastError
        if code == BundledServer.exitPortInUse {
          return done.resume(returning: .failure(.portTaken(said ?? "Port \(port) is taken.")))
        }
        done.resume(returning: .failure(.failed(said ?? "The server didn't start (exit code \(code)).")))
      }
    }
    switch outcome {
    case .success(let port):
      child.port = port
      return child
    case .failure(let e):
      child.kill()
      throw e
    }
  }

  public func setupLink(dataDir: URL, publicUrl: String) async throws -> URL {
    let result = try await runProcess(
      binary.path, ["setup-link", "--data", dataDir.path, "--public-url", publicUrl], timeout: .seconds(10))
    guard let result else { throw ServerStartError.failed("pocketterm-server setup-link took too long.") }
    let line = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.code == 0, let url = URL(string: line), url.scheme == "pocketterm" else {
      let said = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
      throw ServerStartError.failed(said.isEmpty ? "pocketterm-server setup-link failed (\(result.code))." : said)
    }
    return url
  }
}

/// The sidecar as it runs: its lines to debugLog, its listening line read for the port.
final class SidecarProcess: RunningServer, @unchecked Sendable {
  private let lock = NSLock()
  private var process: Subprocess?
  private var pending = [Subprocess.Stream.out: Data(), .err: Data()]
  private var heardPort: Int?
  private var portWaiters: [CheckedContinuation<Int?, Never>] = []
  private var outEnded = false
  private var lastLine: String?
  private var bound = 0

  var port: Int {
    get { locked { bound } }
    set { locked { bound = newValue } }
  }

  var listeningPort: Int? { locked { heardPort } }

  /// The last line it wrote to stderr: why it didn't start.
  var lastError: String? { locked { lastLine } }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  func start(_ binary: String, _ args: [String]) throws {
    let p = try Subprocess.start(binary, args, keepStdin: true) { [weak self] stream, chunk in
      self?.heard(stream, chunk)
    }
    locked { process = p }
  }

  private func heard(_ stream: Subprocess.Stream, _ chunk: Data) {
    var lines: [String] = []
    var waiters: [CheckedContinuation<Int?, Never>] = []
    var found: Int?
    lock.lock()
    var buffer = pending[stream]!
    if chunk.isEmpty {
      if !buffer.isEmpty { lines.append(String(decoding: buffer, as: UTF8.self)) }
      buffer = Data()
    } else {
      buffer.append(chunk)
      while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
        buffer = Data(buffer[buffer.index(after: nl)...])
      }
    }
    pending[stream] = buffer
    for line in lines where stream == .err && !line.trimmingCharacters(in: .whitespaces).isEmpty {
      lastLine = line
    }
    if stream == .out {
      for line in lines where heardPort == nil {
        if let event = JSON.tryParse(line), event["event"]?.string == "listening", let p = event["port"]?.int {
          heardPort = p
          found = p
        }
      }
      if found != nil || chunk.isEmpty {
        if chunk.isEmpty { outEnded = true }
        waiters = portWaiters
        portWaiters = []
      }
    }
    let port = heardPort
    lock.unlock()
    // A first start prints its setup link, which carries the setup token: kept out of the log.
    for line in lines where !line.contains("pocketterm://") { debugLog("PocketTerm server: \(line)") }
    if found != nil || chunk.isEmpty {
      for w in waiters { w.resume(returning: port) }
    }
  }

  /// The port of its listening line; nil when its stdout ended without one.
  func listening() async -> Int? {
    await withCheckedContinuation { c in
      lock.lock()
      if heardPort != nil || outEnded {
        let p = heardPort
        lock.unlock()
        c.resume(returning: p)
      } else {
        portWaiters.append(c)
        lock.unlock()
      }
    }
  }

  func exitCode() async -> Int32 {
    guard let p = locked({ process }) else { return -1 }
    return await p.exitCode()
  }

  func kill() { locked { process }?.kill() }

  /// Closes its stdin, which ends it (its WebSockets closed, pushes on their way given a few seconds); killed if it
  /// hasn't ended within 10 seconds.
  func stop() async {
    guard let p = locked({ process }) else { return }
    p.closeStdin()
    if await p.exitCode(within: .seconds(10)) == nil {
      p.kill()
      _ = await p.exitCode()
    }
  }
}

/// The PocketTerm server built into the app ("This computer"): it listens on 127.0.0.1 only, and Tailscale publishes
/// it to the owner's tailnet at `https://<this computer>.<tailnet>.ts.net` (`tailscale serve`), so phones get real
/// HTTPS and nothing else on the network reaches it. This computer signs itself in on 127.0.0.1 with the server's own
/// setup token.
@MainActor
public final class BuiltInServer: ObservableObject {
  /// [binary]: the bundled `pocketterm-server` (nil: `Contents/Helpers/pocketterm-server` of this app).
  public convenience init(
    dataDir: URL, tailscale: Tailscale, binary: URL? = nil, recheck: TimeInterval = 10, recheckReady: TimeInterval = 60,
    relay: URL? = nil, relayKey: Data? = nil
  ) {
    self.init(
      dataDir: dataDir, tailscale: tailscale, sidecar: BundledServer(binary: binary), recheck: recheck,
      recheckReady: recheckReady, relay: relay, relayKey: relayKey)
  }

  public init(
    dataDir: URL, tailscale: Tailscale, sidecar: any ServerSidecar, recheck: TimeInterval = 10,
    recheckReady: TimeInterval = 60, relay: URL? = nil, relayKey: Data? = nil
  ) {
    self.dataDir = dataDir
    self.tailscale = tailscale
    self.sidecar = sidecar
    self.recheck = recheck
    self.recheckReady = recheckReady
    self.relay = relay
    self.relayKey = relayKey
  }

  /// The server's data (app support `pocketterm-server/`).
  public let dataDir: URL
  public let tailscale: Tailscale
  public let sidecar: any ServerSidecar

  /// How often (seconds) Tailscale is looked at again while it isn't serving, and once it is (it may sign out, or the
  /// computer get another name). Zero: only when asked ([refresh]).
  public let recheck: TimeInterval
  public let recheckReady: TimeInterval

  /// The push relay and its key; the publisher's (the server's own default) when nil.
  public let relay: URL?
  public let relayKey: Data?

  private var server: (any RunningServer)?

  /// The port this app's server had last time ([start]).
  private var earlier: Int?
  private var timer: MainTimer?

  /// Running (between [start] and [stop]).
  public var running: Bool { server != nil }

  /// The port it listens on, on 127.0.0.1; 0 while it doesn't run.
  public var port: Int { server?.port ?? 0 }

  /// How this computer reaches it: `http://127.0.0.1:<port>`.
  public var backend: Backend { Backend(url: "http://127.0.0.1:\(port)") }

  /// What Tailscale said last; nil before the first look.
  public private(set) var tailscaleStatus: TailscaleStatus?

  /// Where phones and other computers reach it, while Tailscale serves it.
  public private(set) var publicUrl: URL?

  /// The tailnet's page that turns HTTPS on, when `tailscale serve` asked for it.
  public private(set) var enableHttps: URL?

  /// What `tailscale serve` said when it failed otherwise.
  public private(set) var error: String?
  private var taken = false

  /// `tailscale serve` was run since [start]: [stop] takes back what it published.
  private var serveRan = false

  private static let servedFile = "tailscale_url"
  private static let renamedFile = "tailscale_renamed_from"

  private func file(_ name: String) -> URL { dataDir.appendingPathComponent(name) }

  private func read(_ name: String) -> String? {
    (try? String(contentsOf: file(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// This computer's address before Tailscale gave it another one (the computer was renamed, or Tailscale signed in
  /// to another tailnet): phones and computers set up with it can't reach this one any more. Kept until
  /// [renameSeen].
  public var renamedFrom: URL? {
    guard let text = read(Self.renamedFile), let old = URL(string: text), !(old.host ?? "").isEmpty else {
      return nil
    }
    return old
  }

  /// The person has seen [renamedFrom]: it goes.
  public func renameSeen() {
    try? FileManager.default.removeItem(at: file(Self.renamedFile))
    objectWillChange.send()
  }

  /// Tailscale serves it at [url] now; another address before means a rename. Renamed again before that was seen,
  /// the first address stays: it's the one the phones have.
  private func servedAt(_ url: URL) {
    do {
      let before = read(Self.servedFile) ?? ""
      if !before.isEmpty && before != url.absoluteString && renamedFrom == nil {
        try before.write(to: file(Self.renamedFile), atomically: true, encoding: .utf8)
      }
      // Back at the old name: nothing changed for the phones after all.
      if renamedFrom?.absoluteString == url.absoluteString {
        try FileManager.default.removeItem(at: file(Self.renamedFile))
      }
      try url.absoluteString.write(to: file(Self.servedFile), atomically: true, encoding: .utf8)
    } catch {
      debugLog("PocketTerm: Tailscale address not kept: \(error)")
    }
  }

  public var state: HostState {
    guard let s = tailscaleStatus else { return .checking }
    switch s.state {
    case .missing: return .noTailscale
    case .stopped: return .tailscaleOff
    case .loggedOut: return .loggedOut
    case .running:
      if publicUrl != nil { return .ready }
      if taken { return .taken }
      if error != nil { return .failed }
      return .httpsOff
    }
  }

  /// Starts listening on 127.0.0.1:[port], or the next free port above it (up to 20 more), else any free port, then
  /// has Tailscale publish it. [earlier]: the port this app's server listened on last time, whose Serve entry is
  /// this app's to move; nil on a first start (an entry there is someone else's).
  public func start(port: Int = 47900, earlier: Int? = nil) async throws {
    if server != nil { return }
    self.earlier = earlier
    let ports = port == 0 ? [0] : Array(port..<min(port + 20, 65536)) + [0]
    var last: ServerStartError?
    for p in ports {
      do {
        let started = try await sidecar.serve(dataDir: dataDir, port: p, relay: relay, relayKey: relayKey)
        // Stopped meanwhile, or started twice at once: this one isn't wanted.
        if server != nil {
          await started.stop()
          return
        }
        server = started
        watch(started)
        break
      } catch .portTaken(let why) {
        last = .portTaken(why)
      } catch {
        throw error
      }
    }
    guard server != nil else { throw last ?? .failed("No free port for the server.") }
    objectWillChange.send()
    // Tailscale may take a while (serve waits up to 30 seconds); the server works on 127.0.0.1 meanwhile.
    Task { await self.refresh() }
  }

  /// A server that ends without [stop] (it crashed, or was killed) is taken off the tailnet as [stop] would.
  private func watch(_ started: any RunningServer) {
    Task { [weak self] in
      let code = await started.exitCode()
      guard let self, self.server === started else { return }
      debugLog("PocketTerm: the built-in server ended by itself (exit code \(code))")
      await self.stop()
    }
  }

  private var refreshing: Task<Void, Never>?

  /// Looks at Tailscale again and has it publish the server when it can (again when this computer's name changed).
  /// A call while one runs waits for that one.
  public func refresh() async {
    if let refreshing { return await refreshing.value }
    let task = Task {
      await self.doRefresh()
      self.refreshing = nil
    }
    refreshing = task
    await task.value
  }

  private func doRefresh() async {
    guard server != nil else { return }
    let status = await tailscale.status()
    guard server != nil else { return }
    tailscaleStatus = status
    if status.state != .running || status.url == nil {
      publicUrl = nil
      enableHttps = nil
      error = nil
      taken = false
    } else if let url = status.url {
      var serve = publicUrl != url
      if !serve {
        let now = await tailscale.port443([port])
        guard server != nil else { return }
        switch now {
        case .elsewhere(let what):
          // Something else took port 443 since: it stays, and phones can't reach this one.
          publicUrl = nil
          error = ServeResult.taken(what).error
          taken = true
        case .nothing:
          // This app's entry went (tailscale serve reset, say): Tailscale publishes it again.
          serve = true
        case .ours, .unknown: break
        }
      }
      if serve {
        serveRan = true
        let result = await tailscale.serve(port, earlier: earlier)
        guard server != nil else { return }
        publicUrl = result.isOk ? url : nil
        enableHttps = result.enableLink
        error = result.error
        taken = result.taken != nil
        if result.isOk { servedAt(url) }
      }
    }
    schedule()
    objectWillChange.send()
  }

  private func schedule() {
    timer?.cancel()
    timer = nil
    let every = state == .ready ? recheckReady : recheck
    if every > 0 {
      timer = MainTimer(every) { [weak self] in
        guard let self else { return }
        Task { await self.refresh() }
      }
    }
  }

  /// Stops publishing it on the tailnet and stops it. A look at Tailscale under way ends first, so what its
  /// `tailscale serve` published goes too.
  public func stop() async {
    timer?.cancel()
    timer = nil
    guard let server else { return }
    self.server = nil
    await refreshing?.value
    let served = serveRan
    serveRan = false
    publicUrl = nil
    tailscaleStatus = nil
    enableHttps = nil
    error = nil
    taken = false
    let tailscale = tailscale
    async let unserved: Void = served ? tailscale.unserve(server.port) : ()
    async let stopped: Void = server.stop()
    _ = await (unserved, stopped)
    objectWillChange.send()
  }

  /// The link another computer sets up with ("Add a computer…"): the Tailscale address and the server's setup token.
  /// Nil until Tailscale serves it.
  public func setupLink() async throws -> URL? {
    guard let publicUrl else { return nil }
    return try await sidecar.setupLink(dataDir: dataDir, publicUrl: publicUrl.absoluteString)
  }

  /// The same for this computer itself, on 127.0.0.1.
  public func ownSetupLink() async throws -> URL {
    guard running else { throw ServerStartError.failed("The server isn't running.") }
    return try await sidecar.setupLink(dataDir: dataDir, publicUrl: backend.url)
  }

  /// Stops looking at Tailscale (the server itself stops with [stop], or with the app).
  public func dispose() {
    timer?.cancel()
    timer = nil
  }
}

/// True the first time only.
final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if taken { return false }
    taken = true
    return true
  }
}
#endif
