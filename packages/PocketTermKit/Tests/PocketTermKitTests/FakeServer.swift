import Foundation

@testable import PocketTermKit

/// A [Server] that answers from memory: the computers list, blobs and pushes it was given or got.
final class FakeServer: Server, @unchecked Sendable {
  init(_ backend: Backend = Backend(url: "https://pt.example.com")) { self.backend = backend }

  let backend: Backend
  private let lock = NSLock()
  private var _desktops: Result<[JSONObject], Error> = .success([])
  private var _blobs: [String: Data] = [:]
  private var _deleted: [String] = []
  private var _pushes: [(String, JSONObject)] = []
  private var _paths = 0

  func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var desktopsAnswer: Result<[JSONObject], Error> {
    get { locked { _desktops } }
    set { locked { _desktops = newValue } }
  }
  var blobs: [String: Data] { locked { _blobs } }
  var deleted: [String] { locked { _deleted } }
  var pushes: [(String, JSONObject)] { locked { _pushes } }

  var account: Account? { nil }
  var ended: AsyncStream<Void> { endedBroadcast.stream() }
  func freshConnections() {}
  func load() async {}
  func recheck() async { locked { _rechecks += 1 } }
  func redeemSetup(_ setup: String, label: String, platform: String) async throws -> Account { throw ServerException(0, "offline", "Offline.") }
  func redeemCode(_ code: String, label: String, platform: String) async throws -> Account { throw ServerException(0, "offline", "Offline.") }
  func leave() async throws {}
  func erase() async throws {}
  func refused() async {
    locked { _refusedCount += 1 }
    endedBroadcast.send(())
  }
  func createPairingCode() async throws -> String { "ABCD-1234" }
  func devices() async throws -> [Device] { [] }
  func revokeDevice(_ id: String) async throws {}
  func desktops() async throws -> [JSONObject] { try desktopsAnswer.get() }
  func putDesktop(_ id: String, name: String, platform: String) async throws {}
  func deleteDesktop(_ id: String) async throws {}
  func newBlobPath() -> String { locked { _paths += 1; return "blob-\(_paths)" } }
  func putBlob(_ path: String, _ bytes: Data) async throws { locked { _blobs[path] = bytes } }
  func getBlob(_ path: String) async throws -> Data {
    guard let b = locked({ _blobs.removeValue(forKey: path) }) else { throw ServerException(404, "not_found", "Gone.") }
    return b
  }
  func deleteBlob(_ path: String) async throws { locked { _deleted.append(path); _blobs[path] = nil } }
  func push(_ action: String, _ body: JSONObject) async throws -> JSONObject {
    locked { _pushes.append((action, body)) }
    return [:]
  }
  func close() {}

  /// What [connectLive] does; by default it fails as offline.
  var live: (@Sendable () async throws -> LiveSocket)? {
    get { locked { _live } }
    set { locked { _live = newValue } }
  }
  private var _live: (@Sendable () async throws -> LiveSocket)?
  private var _refusedCount = 0
  private var _rechecks = 0
  var refusedCount: Int { locked { _refusedCount } }
  var rechecks: Int { locked { _rechecks } }
  let endedBroadcast = Broadcaster<Void>()

  func connectLive() async throws -> LiveSocket {
    guard let live else { throw ServerException(0, "offline", backend.unreachable) }
    return try await live()
  }
}

/// The live channel in memory, as the PocketTerm server's WebSocket answers it: joins of any topic are
/// answered `joined`, pings `pong`; what's sent is recorded; [deliver] relays a message; [drop] closes it.
final class FakeSocket: LiveSocket, @unchecked Sendable {
  init(answerJoins: Bool = true) {
    self.answerJoins = answerJoins
    (frames, continuation) = AsyncStream.makeStream(of: String.self)
  }
  let answerJoins: Bool
  let frames: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private let lock = NSLock()
  private var _closeCode: Int?
  private var _sent: [(event: String, payload: JSONObject)] = []
  private var _joins = 0
  private var _closed = false

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var closeCode: Int? { locked { _closeCode } }
  var sent: [(event: String, payload: JSONObject)] { locked { _sent } }
  var joins: Int { locked { _joins } }
  var closed: Bool { locked { _closed } }

  func add(_ frame: String) {
    guard let f = JSON.tryParse(frame) else { return }
    switch f["t"]?.string {
    case "join":
      locked { _joins += 1 }
      if answerJoins { continuation.yield(JSON.object(["t": "joined", "topic": f["topic"]!]).encoded()) }
    case "send":
      locked { _sent.append((f["event"]!.string!, f["payload"]!.object!)) }
    case "ping":
      continuation.yield(#"{"t":"pong"}"#)
    default: break
    }
  }

  func deliver(_ topic: String, _ event: String, _ payload: JSONObject) {
    continuation.yield(
      JSON.object(["t": "msg", "topic": .string(topic), "event": .string(event), "payload": .object(payload)]).encoded())
  }

  func raw(_ frame: String) { continuation.yield(frame) }

  /// The server closes it with [code].
  func drop(_ code: Int) {
    locked {
      _closeCode = code
      _closed = true
    }
    continuation.finish()
  }

  func close(_ code: Int) async {
    locked { _closed = true }
    continuation.finish()
  }
}
