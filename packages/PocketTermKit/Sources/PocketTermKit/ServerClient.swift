import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// What a device is to its server.
public enum DeviceRole: String, Sendable, Hashable {
  case desktop, phone
}

/// A computer or phone signed in to the server (packages/pocketterm_server/PROTOCOL.md, Device).
public struct Device: Sendable, Hashable {
  public init(
    id: String, role: DeviceRole, label: String, platform: String, seenAt: Date? = nil, current: Bool = false
  ) {
    self.id = id
    self.role = role
    self.label = label
    self.platform = platform
    self.seenAt = seenAt
    self.current = current
  }

  /// Nil when [json] has no `id`.
  public init?(json j: JSONObject) {
    guard let id = j["id"]?.string else { return nil }
    self.init(
      id: id,
      role: j["role"]?.string == "phone" ? .phone : .desktop,
      label: j["label"]?.string ?? "",
      platform: j["platform"]?.string ?? "",
      seenAt: DartDate.tryParse(j["seen_at"]?.string ?? ""),
      current: j["current"]?.bool == true
    )
  }

  /// 16 characters, made by the server.
  public let id: String
  public let role: DeviceRole
  public let label: String

  /// `macos`, `windows`, `linux`, `ios` or `android`.
  public let platform: String
  public let seenAt: Date?

  /// It's the device asking (GET /v1/devices).
  public let current: Bool

  public func toJson() -> JSONObject {
    ["id": .string(id), "role": .string(role.rawValue), "label": .string(label), "platform": .string(platform)]
  }
}

/// This device, signed in to its server: what's kept per server is keyed on [id], the server's own id,
/// which never changes.
public struct Account: Sendable, Hashable {
  public init(id: String, device: Device) {
    self.id = id
    self.device = device
  }

  /// The server's id (GET /v1/me).
  public let id: String

  /// This device, as the server knows it.
  public let device: Device
}

/// The letter an avatar shows for [name] (account.dart's Avatar): its first character upper-cased, `?`
/// for none.
public func avatarLetter(_ name: String) -> String { name.first.map { String($0).uppercased() } ?? "?" }

/// Where a device keeps its sign-in (the device token and what came with it, one string): the Keychain or
/// a DPAPI-encrypted file on a computer, the phone's own secure storage. A store that can't keep it (the
/// Keychain locked) throws [SecureStoreError].
public protocol DeviceTokens: AnyObject, Sendable {
  func read() async throws -> String?

  /// Nil forgets it.
  func write(_ value: String?) async throws
}

/// Why secure storage (the Keychain) refused: locked, missing, its dialog cancelled. A sign-in that fails
/// on it can be retried ([Session.retry]).
public struct SecureStoreError: Error, Sendable, CustomStringConvertible {
  public let status: Int32
  public let message: String
  public init(status: Int32, message: String) {
    self.status = status
    self.message = message
  }
  public var description: String { "\(message) (\(status))" }
}

/// A sign-in that lasts as long as the app runs (tests, a computer's own built-in server).
public final class MemoryDeviceTokens: DeviceTokens, @unchecked Sendable {
  private let state = Locked<String?>(nil)
  public init(_ value: String? = nil) { state.with { $0 = value } }
  public var value: String? { state.get }
  public func read() async throws -> String? { state.get }
  public func write(_ value: String?) async throws { state.with { $0 = value } }
}

/// [DeviceTokens] over a [SecureStore] account.
public final class SecureStoreDeviceTokens: DeviceTokens, @unchecked Sendable {
  public let store: SecureStore
  public let account: String
  public init(_ store: SecureStore, account: String) {
    self.store = store
    self.account = account
  }
  public func read() async throws -> String? {
    try store.data(account).flatMap { String(data: $0, encoding: .utf8) }
  }
  public func write(_ value: String?) async throws {
    if let value { try store.setData(account, Data(value.utf8)) } else { try store.remove(account) }
  }
}

/// What the server answered instead (`{error, message}`), or that it couldn't be reached ([status] 0).
/// [message] is worded for the person.
public struct ServerException: Error, Sendable, CustomStringConvertible, LocalizedError {
  public init(_ status: Int, _ code: String, _ message: String) {
    self.status = status
    self.code = code
    self.message = message
  }
  public let status: Int

  /// The server's `error` (`invalid_code`, `unauthorized`, …; `offline`).
  public let code: String
  public let message: String

  public var description: String { message }
  public var errorDescription: String? { message }
}

/// The live channel's connection, in the frames of PROTOCOL.md's WebSocket (`join`, `send`, `leave`, `ping`
/// out; `joined`, `msg`, `pong`, `error` in): the PocketTerm server's own WebSocket. [closeCode] 4003 once
/// closed: this device was signed out.
public protocol LiveSocket: AnyObject, Sendable {
  /// Each frame as it comes; done when the connection is. One stream per socket: read it once.
  var frames: AsyncStream<String> { get }
  func add(_ frame: String)
  var closeCode: Int? { get }
  func close(_ code: Int) async
}

extension LiveSocket {
  public func close() async { await close(1000) }
}

/// Where this device is signed in (packages/pocketterm_server/PROTOCOL.md): signing in, pairing, the
/// computers list, images and push, and the live channel ([connectLive]). [Servers.make] gives the
/// [PocketTermServerClient]; tests stand in their own.
public protocol Server: AnyObject, Sendable {
  var backend: Backend { get }

  /// This device, signed in; nil while signed out.
  var account: Account? { get }

  /// The server refused this device's token: it's signed out here now. A new stream per listener.
  var ended: AsyncStream<Void> { get }

  /// Back at the front: the next requests go on new connections.
  func freshConnections()

  /// Reads the sign-in this device kept for this server, without asking it.
  func load() async

  /// Asks the server whether the sign-in still holds; a refusal ends it.
  func recheck() async

  /// Signs this computer in with the server's setup token (its setup link).
  func redeemSetup(_ setup: String, label: String, platform: String) async throws -> Account

  /// Signs this phone in with a computer's pairing code (its QR).
  func redeemCode(_ code: String, label: String, platform: String) async throws -> Account

  /// Leaves the server: the token stops working there and is forgotten here.
  func leave() async throws

  /// Computer only: wipes everything on the server, this device's sign-in too. Its setup link and id stay.
  func erase() async throws

  /// The server refused the token: forgotten here, [ended] says so.
  func refused() async

  /// Computer only: a pairing code for a phone, good once for 10 minutes.
  func createPairingCode() async throws -> String

  /// Every computer and phone signed in to the server, oldest first.
  func devices() async throws -> [Device]

  /// Computer only: signs device [id] out.
  func revokeDevice(_ id: String) async throws

  /// The computers phones list, most recently seen first.
  func desktops() async throws -> [JSONObject]

  /// Computer only: lists computer [id] (also stamps it seen now).
  func putDesktop(_ id: String, name: String, platform: String) async throws

  func deleteDesktop(_ id: String) async throws

  /// A new path for an image or file: the phone seals it for this path first.
  func newBlobPath() -> String

  func putBlob(_ path: String, _ bytes: Data) async throws

  /// The blob at [path]; the server deletes it once sent.
  func getBlob(_ path: String) async throws -> Data

  func deleteBlob(_ path: String) async throws

  /// Push [action] with its [body]; the server's answer.
  func push(_ action: String, _ body: JSONObject) async throws -> JSONObject

  /// The live channel, signed in as this device.
  func connectLive() async throws -> LiveSocket

  func close()
}

/// What's common to every [Server]: the factory and the blob limits.
public enum Servers {
  /// The client for [backend], keeping its sign-in in [tokens].
  public static func make(_ backend: Backend, tokens: DeviceTokens) -> Server {
    PocketTermServerClient(backend, tokens: tokens)
  }

  /// [path] can be one of [Server.newBlobPath]'s.
  public static func isBlobPath(_ path: String) -> Bool {
    let u = path.utf8
    return (1...64).contains(u.count)
      && u.allSatisfy { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
  }

  /// The most a blob may hold (the server's limit, 20 MiB).
  public static let maxBlobBytes = 20 * 1024 * 1024
}

/// The PocketTerm server (packages/pocketterm_server/PROTOCOL.md) through this device's token: signing in,
/// pairing, the computers list, images and push. Signed in is having a token ([account]); once the server
/// refuses it (the device was revoked or left, the server was erased) it is forgotten and [ended] says
/// so. The live channel is TerminalChannel.swift.
public final class PocketTermServerClient: Server, @unchecked Sendable {
  public init(_ backend: Backend, tokens: DeviceTokens) {
    self.backend = backend
    self.tokens = tokens
    http = Locked(Self.newHttp())
  }

  public let backend: Backend

  /// Where this device's sign-in is kept.
  public let tokens: DeviceTokens

  private let http: Locked<URLSession>

  private static func newHttp() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = 120
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.urlCache = nil
    return URLSession(configuration: config)
  }

  /// Back at the front: the next requests go on new connections. The ones kept open from before may be dead
  /// without having said so (the system stops an app's network in the background, the phone changed
  /// networks), and a request on one would wait out its whole timeout. Requests under way finish where
  /// they are.
  public func freshConnections() {
    let old = http.with { s in
      let old = s
      s = Self.newHttp()
      return old
    }
    old.finishTasksAndInvalidate()
  }

  static let timeout: TimeInterval = 20

  private struct State {
    var account: Account?
    var token: String?
    /// The sign-in as kept in [tokens], so an unchanged one isn't written again.
    var kept: String?
  }
  private let state = Locked(State())

  /// This device, signed in; nil while signed out.
  public var account: Account? { state.get.account }
  var token: String? { state.get.token }

  /// The server refused this device's token: it's signed out here now.
  public var ended: AsyncStream<Void> { endedBroadcast.stream() }
  private let endedBroadcast = Broadcaster<Void>()

  /// Reads the sign-in this device kept for this server: [account] at once, without asking the server
  /// ([recheck] does), so a launch shows what it had before the network answers.
  public func load() async {
    do {
      let raw = try await tokens.read()
      guard let raw, let saved = JSON.tryParse(raw)?.object, saved["url"]?.string == backend.url,
        let token = saved["token"]?.string, let server = saved["server"]?.string,
        let deviceJson = saved["device"]?.object, let device = Device(json: deviceJson)
      else { return }
      state.with {
        $0.token = token
        $0.account = Account(id: server, device: device)
        $0.kept = raw
      }
    } catch {
      debugLog("PocketTerm: sign-in not read: \(error)")
    }
  }

  /// Asks the server whether the sign-in still holds, and keeps what it says of this device. A refusal ends
  /// it ([ended]); no answer (offline), or one this app doesn't read (a captive portal's page), keeps it.
  public func recheck() async {
    guard let token else { return }
    do {
      let me = try await json("GET", "/v1/me", token: token)
      // Signed out, or in anew, meanwhile: the answer is about a sign-in that's gone.
      if self.token == token { _ = try await keep(token, me) }
    } catch let e as ServerException {
      if e.status == 401 && self.token == token { await refused() }
    } catch {
      debugLog("PocketTerm: sign-in not checked: \(error)")
    }
  }

  public func redeemSetup(_ setup: String, label: String, platform: String) async throws -> Account {
    try await redeem("/v1/setup/redeem", ["setup": .string(setup), "label": .string(label), "platform": .string(platform)])
  }

  public func redeemCode(_ code: String, label: String, platform: String) async throws -> Account {
    try await redeem("/v1/pair/redeem", ["code": .string(code), "label": .string(label), "platform": .string(platform)])
  }

  private func redeem(_ path: String, _ body: JSONObject) async throws -> Account {
    let answer = try await json("POST", path, body: body, auth: false)
    guard let token = answer?["token"]?.string else {
      throw ServerException(500, "internal", "The server didn't send a sign-in.")
    }
    return try await signedIn(token)
  }

  /// Asks the server who [token] is and keeps it.
  private func signedIn(_ token: String) async throws -> Account {
    try await keep(token, try await json("GET", "/v1/me", token: token))
  }

  /// [token] and the device the server's GET /v1/me ([me]) says it is.
  private func keep(_ token: String, _ me: JSON?) async throws -> Account {
    guard let deviceJson = me?["device"]?.object, let server = me?["server"]?["id"]?.string,
      let device = Device(json: deviceJson)
    else { throw ServerException(500, "internal", "The server sent an answer this app doesn't read.") }
    let account = Account(id: server, device: device)
    let kept: JSONObject = [
      "url": .string(backend.url), "token": .string(token), "server": .string(server),
      "device": .object(device.toJson()),
    ]
    let text = kept.encoded()
    if text != state.get.kept { try await tokens.write(text) }
    state.with {
      $0.kept = text
      $0.token = token
      $0.account = account
    }
    return account
  }

  /// Leaves the server: the token stops working there (DELETE /v1/devices/me) and is forgotten here, also
  /// when the server can't be reached.
  public func leave() async throws {
    do {
      if token != nil { _ = try await json("DELETE", "/v1/devices/me") }
    } catch {
      await forget()
      throw error
    }
    await forget()
  }

  /// Computer only: wipes everything on the server (every device, this one too, the computers list, codes,
  /// push tokens, images). Its setup link and id stay.
  public func erase() async throws {
    _ = try await json("POST", "/v1/erase")
    await forget()
  }

  private func forget() async {
    state.with { $0 = State() }
    do {
      try await tokens.write(nil)
    } catch {
      debugLog("PocketTerm: sign-in not forgotten: \(error)")
    }
  }

  /// The server refused the token (an answer 401, the live channel closed with 4003): forgotten here,
  /// [ended] says so (unless [close]d by then).
  public func refused() async {
    guard token != nil else { return }
    await forget()
    endedBroadcast.send(())
  }

  public func createPairingCode() async throws -> String {
    guard let code = try await json("POST", "/v1/pair")?["code"]?.string else {
      throw ServerException(500, "internal", "The server didn't send a code.")
    }
    return code
  }

  public func devices() async throws -> [Device] {
    (try await json("GET", "/v1/devices")?.array ?? []).compactMap { $0.object.flatMap(Device.init(json:)) }
  }

  /// Computer only: signs device [id] out (a lost phone); it's told so the next time it asks.
  public func revokeDevice(_ id: String) async throws { _ = try await json("DELETE", "/v1/devices/\(id)") }

  public func desktops() async throws -> [JSONObject] {
    (try await json("GET", "/v1/desktops")?.array ?? []).compactMap(\.object)
  }

  public func putDesktop(_ id: String, name: String, platform: String) async throws {
    _ = try await json("PUT", "/v1/desktops/\(id)", body: ["name": .string(name), "platform": .string(platform)])
  }

  public func deleteDesktop(_ id: String) async throws { _ = try await json("DELETE", "/v1/desktops/\(id)") }

  public func newBlobPath() -> String { UUID().uuidString.lowercased() }

  /// Uploads [bytes] to [path]. One over [Servers.maxBlobBytes] fails here, with the reason: sent, the server
  /// would cut it off and the reason would be lost.
  public func putBlob(_ path: String, _ bytes: Data) async throws {
    if bytes.count > Servers.maxBlobBytes {
      throw ServerException(413, "too_large", "That file is too large: the most is 20 MB.")
    }
    _ = try await json("PUT", "/v1/blobs/\(path)", bytes: bytes)
  }

  public func getBlob(_ path: String) async throws -> Data { try await send("GET", "/v1/blobs/\(path)").bytes }

  public func deleteBlob(_ path: String) async throws { _ = try await json("DELETE", "/v1/blobs/\(path)") }

  /// Push [action] (register, unregister, notify, activity_register, activity_end, activity) with its
  /// [body]; the server's answer (`{sent}` for notify and activity).
  public func push(_ action: String, _ body: JSONObject) async throws -> JSONObject {
    try await json("POST", "/v1/push/\(action)", body: body)?.object ?? [:]
  }

  /// The server's WebSocket (GET /v1/ws), signed in as this device.
  public func connectLive() async throws -> LiveSocket {
    guard let token else { throw ServerException(401, "unauthorized", "Not signed in.") }
    guard var c = URLComponents(string: backend.api) else { throw ServerException(0, "offline", backend.unreachable) }
    c.scheme = c.scheme == "https" ? "wss" : "ws"
    c.path = c.path + "/v1/ws"
    var req = URLRequest(url: c.url!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
    return try await WebSocketLive.connect(req, timeout: Self.timeout)
  }

  public func close() {
    http.get.invalidateAndCancel()
    endedBroadcast.finish()
  }

  private func json(
    _ method: String, _ path: String, body: JSONObject? = nil, bytes: Data? = nil, auth: Bool = true,
    token: String? = nil
  ) async throws -> JSON? {
    let res = try await send(method, path, body: body, bytes: bytes, auth: auth, token: token)
    if res.bytes.isEmpty { return nil }
    do {
      return try JSON.parse(res.bytes)
    } catch {
      throw ServerException(500, "internal", "The server sent an answer this app doesn't read.")
    }
  }

  private func send(
    _ method: String, _ path: String, body: JSONObject? = nil, bytes: Data? = nil, auth: Bool = true,
    token: String? = nil
  ) async throws -> (status: Int, bytes: Data) {
    let bearer = token ?? self.token
    if auth && bearer == nil { throw ServerException(401, "unauthorized", "Not signed in.") }
    guard let url = URL(string: "\(backend.api)\(path)") else {
      throw ServerException(0, "offline", backend.unreachable)
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    if auth, let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
    if let bytes {
      req.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
      req.httpBody = bytes
    } else if let body {
      req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "content-type")
      req.httpBody = body.encoded().data(using: .utf8)
    }
    let status: Int
    let data: Data
    do {
      let (d, r) = try await http.get.data(for: req)
      status = (r as? HTTPURLResponse)?.statusCode ?? 0
      data = d
    } catch {
      debugLog("PocketTerm: \(method) \(path): \(error)")
      throw ServerException(0, "offline", backend.unreachable)
    }
    if status < 400 { return (status, data) }
    var code = "internal"
    var message = "The server failed (\(status))."
    // Not the server's own answer (a proxy's error page) keeps the above.
    if let j = JSON.tryParse(data), let c = j["error"]?.string, let m = j["message"]?.string {
      code = c
      message = m
    }
    // The token this device holds stopped working.
    if status == 401 && auth && token == nil { await refused() }
    throw ServerException(status, code, message)
  }
}

/// A WebSocket (URLSessionWebSocketTask) as a [LiveSocket]: its text frames as they are.
final class WebSocketLive: NSObject, LiveSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
  private let continuation: AsyncStream<String>.Continuation
  let frames: AsyncStream<String>
  private var session: URLSession!
  private var task: URLSessionWebSocketTask!
  private struct State {
    var opened: CheckedContinuation<Void, Error>?
    var isOpen = false
    var closeCode: Int?
    var done = false
  }
  private let state = Locked(State())

  private override init() {
    (frames, continuation) = AsyncStream.makeStream(of: String.self)
    super.init()
  }

  /// Opens [request] (ws:// or wss://), within [timeout] seconds; fails when the server refuses.
  static func connect(_ request: URLRequest, timeout: TimeInterval) async throws -> WebSocketLive {
    let ws = WebSocketLive()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    ws.session = URLSession(configuration: config, delegate: ws, delegateQueue: nil)
    ws.task = ws.session.webSocketTask(with: request)
    // The server's frames are at most 256 KiB.
    ws.task.maximumMessageSize = 4 * 1024 * 1024
    do {
      try await withTimeout(timeout) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
          let resumeNow = ws.state.with { s -> Bool in
            if s.isOpen { return true }
            s.opened = c
            return false
          }
          if resumeNow { c.resume() }
          ws.task.resume()
        }
      }
    } catch {
      ws.finish(code: nil)
      ws.task.cancel()
      ws.session.invalidateAndCancel()
      throw error
    }
    ws.receive()
    return ws
  }

  private func receive() {
    task.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(.string(let s)):
        self.continuation.yield(s)
        self.receive()
      case .success:
        self.receive()
      case .failure:
        let code = self.task.closeCode.rawValue
        self.finish(code: code == 0 ? nil : code)
      }
    }
  }

  private func finish(code: Int?) {
    let first = state.with { s -> Bool in
      if s.done { return false }
      s.done = true
      if s.closeCode == nil { s.closeCode = code }
      return true
    }
    guard first else { return }
    continuation.finish()
    session?.finishTasksAndInvalidate()
  }

  func add(_ frame: String) {
    task.send(.string(frame)) { _ in }
  }

  var closeCode: Int? { state.get.closeCode }

  func close(_ code: Int) async {
    task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
    finish(code: nil)
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
  ) {
    let c = state.with { s -> CheckedContinuation<Void, Error>? in
      s.isOpen = true
      defer { s.opened = nil }
      return s.opened
    }
    c?.resume()
  }

  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    finish(code: closeCode.rawValue == 0 ? nil : closeCode.rawValue)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let c = state.with { s -> CheckedContinuation<Void, Error>? in
      defer { s.opened = nil }
      return s.opened
    }
    c?.resume(throwing: error ?? URLError(.networkConnectionLost))
    let code = (task as? URLSessionWebSocketTask)?.closeCode.rawValue ?? 0
    finish(code: code == 0 ? nil : code)
  }
}
