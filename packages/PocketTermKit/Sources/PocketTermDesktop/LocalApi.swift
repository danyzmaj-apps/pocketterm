#if os(macOS)
import Foundation
import NIOCore
import NIOPosix
import PocketTermKit

/// The terminal's way in (the live sessions of omp and Claude Code): HTTP
/// on 127.0.0.1 at a random port, guarded by a random token. Both are
/// written to `~/.config/pocketterm/cli.json`
/// (mode 600; `POCKETTERM_CLI_JSON` names another file) for the
/// clients to read, and taken out again when PocketTerm quits.
///
///   GET   /v1/ping?nonce=N         → {"app": "pocketterm", "proof"}: no token; proof is
///                                  `pingProof`, so a client knows it's this PocketTerm
///                                  before its token goes anywhere
///   GET   /v1/ping                 → {"app": "pocketterm", "pid"}: this PocketTerm is up
///   GET   /v1/live                 WebSocket: a coding session reporting itself (omp's
///                                  integrations/omp/pocketterm-live.ts, LiveHub)
///   POST  /v1/live/http            {conn?, frames, wait?, close?} → {conn, frames}: the same over
///                                  HTTP long polls (the Claude Code plugin)
///
/// The orchestrator's folder (`LiveEndpoint.orchestratorDir`) is `orchestrator` beside `file`: a session started
/// there may call on the hub (Orchestrator).
@MainActor
public final class LocalApi {
  /// How often `file` is checked for another PocketTerm having taken it over.
  public nonisolated static let watchEvery: TimeInterval = 5
  /// How long a long poll waits for frames from the hub.
  public nonisolated static let pollHold: TimeInterval = 25
  /// A long-poll connection without a request for this long is gone, and its session with it.
  public nonisolated static let pollIdle: TimeInterval = 60
  /// The most a long poll's body may hold; more is refused (413).
  public nonisolated static let maxBody = 8 * 1024 * 1024

  /// Where the port and token go: `~/.config/pocketterm/cli.json`, or the file `POCKETTERM_CLI_JSON` names.
  public let file: String

  private let live: LiveEndpoint
  /// `file`'s folder is PocketTerm's own `~/.config/pocketterm`, kept private (700).
  /// One `POCKETTERM_CLI_JSON` names (a home folder, a project) keeps its mode.
  private let ownFolder: Bool
  nonisolated let token: String = newId(32)
  let hold: TimeInterval
  let idle: TimeInterval
  let watchInterval: TimeInterval

  private var group: MultiThreadedEventLoopGroup?
  private var server: Channel?
  private var children: ChildChannels?
  /// What this app wrote to `file`.
  private var written: String?
  private var watch: Task<Void, Never>?
  /// HTTP long-poll connections (/v1/live/http) by id.
  private var polls: [String: PollLink] = [:]
  /// The live sessions' WebSockets (/v1/live), open now.
  private var sockets: [ObjectIdentifier: WebSocketLink] = [:]

  /// The port it listens on, once started.
  public private(set) var port: Int?

  public convenience init(live: LiveEndpoint, file: String? = nil) {
    self.init(live: live, file: file, pollHold: Self.pollHold, idle: Self.pollIdle, watchEvery: Self.watchEvery)
  }

  init(live: LiveEndpoint, file: String?, pollHold: TimeInterval, idle: TimeInterval, watchEvery: TimeInterval) {
    let hooks = testHooks()
    let named = !(hooks["POCKETTERM_CLI_JSON"] ?? "").isEmpty
    self.file = file ?? Self.defaultFile(env: ProcessInfo.processInfo.environment, hooks: hooks)
    ownFolder = file == nil && !named
    self.live = live
    hold = pollHold
    self.idle = idle
    watchInterval = watchEvery
    live.orchestratorDir = ((self.file as NSString).deletingLastPathComponent as NSString)
      .appendingPathComponent("orchestrator")
  }

  /// Where cli.json goes: `POCKETTERM_CLI_JSON` (test builds), else `$HOME/.config/pocketterm/cli.json`. `HOME`
  /// as the process has it, not the account's home (NSHomeDirectory ignores HOME): tool/smoke and tool/e2e run
  /// the app with a throwaway HOME, and the integrations read the same `$HOME` path.
  nonisolated static func defaultFile(env: [String: String], hooks: [String: String]) -> String {
    if let named = hooks["POCKETTERM_CLI_JSON"], !named.isEmpty { return named }
    return (homeDir(env: env) as NSString).appendingPathComponent(".config/pocketterm/cli.json")
  }

  /// What /v1/ping?nonce= answers: HMAC-SHA256 under `token` of the `port` asked and the client's `nonce`, in
  /// hex. Only the PocketTerm that wrote cli.json can make it, and only for its own port: whatever else listens
  /// there (after PocketTerm quit, say) can't, nor pass on a real PocketTerm's.
  public nonisolated static func pingProof(_ token: String, _ port: Int, _ nonce: String) -> String {
    PocketTermKit.pingProof(token: token, port: port, nonce: nonce)
  }

  public func start() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let children = ChildChannels()
    let token = token
    do {
      let server = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { [self] channel in
          children.add(channel)
          return configureChild(channel, api: self, token: token)
        }
        .bind(host: "127.0.0.1", port: 0).get()
      self.group = group
      self.server = server
      self.children = children
      port = server.localAddress?.port
    } catch {
      try? await group.shutdownGracefully()
      throw error
    }
    written = #"{"port":\#(port!),"token":"\#(token)","pid":\#(ProcessInfo.processInfo.processIdentifier)}"#
    try write()
    let every = watchInterval
    watch = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(every * 1e9))
        if Task.isCancelled { return }
        await self?.reclaim()
      }
    }
  }

  /// Stops listening, ends the live sessions' connections and takes `file` back out, unless another PocketTerm
  /// has it now. Runs when PocketTerm quits (AppController.onQuit).
  public func stop() async {
    watch?.cancel()
    watch = nil
    var closing: [EventLoopFuture<Void>] = []
    if let server {
      closing.append(server.close())
    }
    // Not waiting for the agent's side of the close: quitting can't.
    for ws in sockets.values { closing.append(ws.closeChannel(code: .goingAway)) }
    for p in Array(polls.values) { await p.close() }
    if let children {
      for c in children.all() { closing.append(c.close()) }
    }
    for f in closing { _ = try? await f.get() }
    try? await group?.shutdownGracefully()
    server = nil
    group = nil
    children = nil
    if let written, (try? String(contentsOfFile: file, encoding: .utf8)) == written {
      try? FileManager.default.removeItem(atPath: file)
    }
  }

  /// Writes `written` to `file` as a whole (a reader never sees half of it), private before the token goes in:
  /// a chmod that fails stops it.
  private func write() throws {
    let fm = FileManager.default
    let dir = (file as NSString).deletingLastPathComponent
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if ownFolder { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir) }
    let tmp = "\(file).\(ProcessInfo.processInfo.processIdentifier).tmp"
    do {
      try Data().write(to: URL(fileURLWithPath: tmp))
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
      let h = try FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
      defer { try? h.close() }
      try h.write(contentsOf: Data(written!.utf8))
      try h.synchronize()
      if rename(tmp, file) != 0 {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
      }
    } catch {
      if fm.fileExists(atPath: tmp) { try? fm.removeItem(atPath: tmp) }
      throw error
    }
  }

  /// Another PocketTerm (a debug build, say) took `file` over and has quit or died since, leaving the terminal
  /// pointed at nothing: this one's address goes back.
  func reclaim() async {
    guard let written else { return }
    let text = try? String(contentsOfFile: file, encoding: .utf8)
    guard await Self.shouldReclaim(text, written, answers: Self.answers) else { return }
    debugLog("PocketTerm: \(file) named no running PocketTerm; writing this one back")
    do { try write() } catch { debugLog("PocketTerm: \(file) not written: \(error)") }
  }

  /// Whether cli.json as it reads now (`text`, nil when missing) should give way to `ours`: it's gone or
  /// unreadable, or names a PocketTerm that doesn't `answers` at its port with its token anymore.
  nonisolated static func shouldReclaim(
    _ text: String?,
    _ ours: String,
    answers: @Sendable (Int, String) async -> Bool
  ) async -> Bool {
    if text == ours { return false }
    guard let json = JSON.tryParse(text ?? ""), let port = json["port"]?.int, let token = json["token"]?.string
    else { return true }
    return !(await answers(port, token))
  }

  /// The PocketTerm that holds `token` answers /v1/ping at `port`: it proves it (`pingProof`) without the token
  /// being sent.
  nonisolated static func answers(_ port: Int, _ token: String) async -> Bool {
    let nonce = newId(16)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    config.timeoutIntervalForResource = 4
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    guard let url = URL(string: "http://127.0.0.1:\(port)/v1/ping?nonce=\(nonce)"),
      let (data, res) = try? await session.data(from: url),
      (res as? HTTPURLResponse)?.statusCode == 200
    else { return false }
    return JSON.tryParse(data)?["proof"]?.string == pingProof(token, port, nonce)
  }

  // MARK: - Routes (called from LocalApiServer's handlers)

  /// GET/other routes but the live ones: the nonce ping before the token, then the token for the rest.
  nonisolated static func route(
    method: String, uri: String, authorization: String?, token: String, port: Int
  ) -> (Int, String) {
    let (path, query) = splitUri(uri)
    let segments = path.hasPrefix("/") ? path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) : []
    let ping = method == "GET" && segments.count == 2 && segments[0] == "v1" && segments[1] == "ping"
    // Before the token: a client asks this way whether to send it here.
    if ping, let nonce = query["nonce"] {
      if !pingNonceAccepted(nonce) { return (400, #"{"error":"nonce: 16 to 128 characters."}"#) }
      return (200, #"{"app":"pocketterm","proof":"\#(pingProof(token, port, nonce))"}"#)
    }
    if authorization != "Bearer \(token)" { return (403, badToken) }
    if ping { return (200, #"{"app":"pocketterm","pid":\#(ProcessInfo.processInfo.processIdentifier)}"#) }
    return (404, #"{"error":"Not found."}"#)
  }

  nonisolated static let badToken = #"{"error":"Bad token."}"#

  /// A request's path and query parameters.
  nonisolated static func splitUri(_ uri: String) -> (String, [String: String]) {
    guard let c = URLComponents(string: uri) else { return (uri, [:]) }
    var query: [String: String] = [:]
    for item in c.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
    return (c.percentEncodedPath, query)
  }

  /// One long poll: the extension's frames go to its connection in order, and the answer carries the hub's,
  /// waiting `hold` for some when asked to. A request without a connection opens one.
  func poll(_ data: Data) async -> (Int, String) {
    let body: JSONObject
    let frames: [String]
    do {
      guard let o = try JSON.parse(data).object else { throw LocalApiError.bad("body is not a JSON object") }
      body = o
      switch body["frames"] {
      case nil, .null?: frames = []
      case .array(let list)?: frames = list.map { $0.encoded() }
      default: throw LocalApiError.bad("frames is not a list")
      }
      if let c = body["conn"], !c.isNull, c.string == nil { throw LocalApiError.bad("conn is not a string") }
    } catch {
      debugLog("PocketTerm: live poll: \(error)")
      return (400, JSON.object(["error": .string("Bad request: \(error)")]).encoded())
    }
    let link: PollLink?
    if let id = body["conn"]?.string {
      link = polls[id]
    } else {
      let (stream, input) = AsyncStream.makeStream(of: String.self)
      let l = PollLink(id: newId(16), frames: stream, input: input, idle: idle) { [weak self] in
        self?.polls.removeValue(forKey: $0)
      }
      polls[l.id] = l
      let live = live
      Task { await live.accept(stream, l) }
      link = l
    }
    let out = await link?.exchange(frames, hold: body["wait"] == .bool(true) ? hold : nil)
    // The agent is quitting: its session ends now.
    if body["close"] == .bool(true) { await link?.close() }
    guard let out, let link else { return (404, #"{"error":"No such connection: say hello again."}"#) }
    // The hub's frames are JSON already.
    return (200, #"{"conn":\#(JSON.string(link.id).encoded()),"frames":[\#(out.joined(separator: ","))]}"#)
  }

  /// A WebSocket on /v1/live, upgraded: its text frames go to the hub until it closes.
  func acceptSocket(_ frames: AsyncStream<String>, _ channel: Channel) async {
    let link = WebSocketLink(channel)
    let key = ObjectIdentifier(link)
    sockets[key] = link
    defer { sockets.removeValue(forKey: key) }
    await live.accept(frames, link)
  }
}

enum LocalApiError: Error, CustomStringConvertible {
  case bad(String)
  var description: String { if case .bad(let s) = self { s } else { "" } }
}

/// `bytes` random bytes in lowercase hex.
func newId(_ bytes: Int) -> String {
  var g = SystemRandomNumberGenerator()
  return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
}

/// One extension on the HTTP long-poll transport (/v1/live/http): its frames go to the hub in the order they
/// came, and the hub's wait here for its next request. Gone, and its session with it, after `idle` without one.
@MainActor
final class PollLink: LiveLink {
  let id: String
  /// The extension's frames, for LiveEndpoint.accept.
  let frames: AsyncStream<String>
  private let input: AsyncStream<String>.Continuation
  private let gone: (String) -> Void
  private let idle: TimeInterval
  private var out: [String] = []
  private var waiting: (gen: Int, cont: CheckedContinuation<Void, Never>)?
  private var gen = 0
  private var idleTimer: Task<Void, Never>?
  private var active = 0
  private(set) var closed = false

  init(
    id: String, frames: AsyncStream<String>, input: AsyncStream<String>.Continuation, idle: TimeInterval,
    gone: @escaping (String) -> Void
  ) {
    self.id = id
    self.frames = frames
    self.input = input
    self.idle = idle
    self.gone = gone
    armIdle()
  }

  private func armIdle() {
    let idle = idle
    idleTimer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(idle * 1e9))
      if Task.isCancelled { return }
      await self?.close()
    }
  }

  func send(_ frame: String) {
    if closed { return }
    out.append(frame)
    wake()
  }

  private func wake() {
    let w = waiting
    waiting = nil
    w?.cont.resume()
  }

  func close() async {
    if closed { return }
    closed = true
    idleTimer?.cancel()
    wake()
    gone(id)
    input.finish()
  }

  /// One request: `frames` in, then the hub's out, waiting up to `hold` for some when there are none yet (a
  /// newer wait ends an older one). Nil once closed.
  func exchange(_ frames: [String], hold: TimeInterval?) async -> [String]? {
    if closed { return nil }
    active += 1
    idleTimer?.cancel()
    defer {
      active -= 1
      if active == 0 && !closed { armIdle() }
    }
    for f in frames { input.yield(f) }
    if out.isEmpty, let hold {
      wake()
      gen += 1
      let mine = gen
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        waiting = (mine, c)
        Task { [weak self] in
          try? await Task.sleep(nanoseconds: UInt64(hold * 1e9))
          guard let self, self.waiting?.gen == mine else { return }
          self.wake()
        }
      }
    }
    let result = out
    out.removeAll()
    return result
  }
}
#endif
