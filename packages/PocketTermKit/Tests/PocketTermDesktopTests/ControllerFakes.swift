#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals

@testable import PocketTermDesktop

/// The computer's side, recording what it was asked in `calls`.
@MainActor
final class ControllerFakeHost: DesktopHost {
  var calls: [String] = []

  /// What `idleSeconds` answers.
  var idle = 0

  /// Whether PocketTerm is a login item.
  var loginItem = false

  /// Makes `setLaunchAtLogin` fail with this.
  var loginItemRefused: String?

  /// What `pickFolders` answers.
  var folders: [String] = []

  /// What `start` was given.
  var onEvent: (@MainActor (String) async -> Void)?

  struct Refused: Error, CustomStringConvertible { let description: String }

  func start(onEvent: @escaping @MainActor (String) async -> Void) async {
    calls.append("start")
    self.onEvent = onEvent
  }
  func showMain() async { calls.append("showMain") }
  func hideMain() async { calls.append("hideMain") }
  func quit() async { calls.append("quit") }
  func deviceName() async -> String {
    calls.append("deviceName")
    return "Mac"
  }
  func idleSeconds() async -> Int {
    calls.append("idleSeconds")
    return idle
  }
  func launchAtLogin() async -> Bool {
    calls.append("launchAtLogin")
    return loginItem
  }
  func setLaunchAtLogin(on: Bool) async throws {
    calls.append("setLaunchAtLogin(\(on))")
    if let loginItemRefused { throw Refused(description: loginItemRefused) }
    loginItem = on
  }
  func pickFolders() async -> [String] {
    calls.append("pickFolders")
    return folders
  }
  func setKeepAwake(on: Bool) async { calls.append("setKeepAwake(\(on))") }
  func setAppIcon(_ icon: String) async { calls.append("setAppIcon(\(icon))") }
}

/// Secrets kept in memory, as the Keychain would keep them; while `locked`, writes fail as a locked Keychain's do.
final class ControllerSecrets: SecureStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]
  private var _locked = false

  var locked: Bool {
    get { lock.withLock { _locked } }
    set { lock.withLock { _locked = newValue } }
  }

  func data(_ account: String) throws -> Data? { lock.withLock { values[account] } }
  func setData(_ account: String, _ value: Data) throws {
    try lock.withLock {
      if _locked { throw SecureStoreError(status: -25308, message: "User interaction is not allowed.") }
      values[account] = value
    }
  }
  func remove(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

/// A server signed in as `account` from the start, answering from memory.
final class ControllerFakeServer: Server, @unchecked Sendable {
  init(_ backend: Backend, account: Account?) {
    self.backend = backend
    self.account = account
  }

  let backend: Backend
  let account: Account?
  private let lock = NSLock()
  private var codes = 0
  private var _phones = false

  /// Whether a phone has signed in (what `devices` lists).
  var phones: Bool {
    get { lock.withLock { _phones } }
    set { lock.withLock { _phones = newValue } }
  }

  var ended: AsyncStream<Void> { AsyncStream { _ in } }
  func freshConnections() {}
  func load() async {}
  func recheck() async {}
  func redeemSetup(_ setup: String, label: String, platform: String) async throws -> Account {
    throw ServerException(0, "offline", "Offline.")
  }
  func redeemCode(_ code: String, label: String, platform: String) async throws -> Account {
    throw ServerException(0, "offline", "Offline.")
  }
  func leave() async throws {}
  func erase() async throws {}
  func refused() async {}
  func createPairingCode() async throws -> String {
    let n = lock.withLock {
      codes += 1
      return codes
    }
    return "PAIR-\(n)AAA-BBBB-CCCC-DDDD-EEEE-FFFF"
  }
  func devices() async throws -> [Device] {
    guard let account else { return [] }
    let phone = Device(id: "phone-1", role: .phone, label: "iPhone", platform: "ios")
    return phones ? [account.device, phone] : [account.device]
  }
  func revokeDevice(_ id: String) async throws {}
  func desktops() async throws -> [JSONObject] { [] }
  func putDesktop(_ id: String, name: String, platform: String) async throws {}
  func deleteDesktop(_ id: String) async throws {}
  func newBlobPath() -> String { "blob" }
  func putBlob(_ path: String, _ bytes: Data) async throws {}
  func getBlob(_ path: String) async throws -> Data { throw ServerException(404, "not_found", "Gone.") }
  func deleteBlob(_ path: String) async throws {}
  func push(_ action: String, _ body: JSONObject) async throws -> JSONObject { ["sent": 1] }
  func connectLive() async throws -> LiveSocket { throw ServerException(0, "offline", backend.unreachable) }
  func close() {}
}

/// An `AppController` on `ControllerFakeHost`, with no coding agents and no terminals. Unless `real`, its server
/// is a `ControllerFakeServer` signed in as `fakeUser`; with `real`, the server is Session's own (the built-in
/// server, say).
@MainActor
final class TestApp: AppController {
  static let home = "/nonexistent-pocketterm-test"

  init(
    prefs: PreferenceStore = MemoryPreferenceStore(),
    secrets: SecureStore = ControllerSecrets(),
    tailscale: Tailscale? = nil,
    serverDir: URL? = nil,
    sidecar: URL? = nil,
    real: Bool = false
  ) {
    self.real = real
    self.store = prefs
    super.init(
      prefs: prefs,
      device: "Mac",
      host: ControllerFakeHost(),
      integrations: Integrations(home: Self.home, claudePaths: [], ompPaths: []),
      secrets: secrets,
      tailscale: tailscale,
      serverDir: { serverDir ?? URL(fileURLWithPath: "\(Self.home)/server") },
      builtInServer: { dir, tailscale in
        BuiltInServer(dataDir: dir, tailscale: tailscale, binary: sidecar, recheck: 0, recheckReady: 0)
      },
      terminals: Terminals(home: Self.home, recency: { [] }),
      // Its built-in server apart from other tests': a port the system picks.
      hostingPort: 0
    )
  }

  /// The server and sign-in are Session's own.
  let real: Bool
  let store: PreferenceStore

  var fakeHost: ControllerFakeHost { host as! ControllerFakeHost }

  /// Who the fake server says is signed in.
  var fakeUser: Account? = Account(
    id: "server-1", device: Device(id: "device-1", role: .desktop, label: "Mac", platform: "macos"))

  /// The fake server, once connected.
  private(set) var fakeServer: ControllerFakeServer?

  override func makeServer(_ backend: Backend, tokens: DeviceTokens) -> Server {
    if real { return super.makeServer(backend, tokens: tokens) }
    let s = ControllerFakeServer(backend, account: fakeUser)
    fakeServer = s
    return s
  }

  /// Signs in to the fake server.
  func signIn() async { await connect(Backend(url: "https://pt.example.com")) }

  /// What went to the server's push, in order: the action and its body.
  var pushes: [JSONObject] = []

  override func invokePush(_ action: String, _ body: JSONObject) async throws -> JSONObject {
    if real { return try await super.invokePush(action, body) }
    var all = body
    all["action"] = .string(action)
    pushes.append(all)
    return ["sent": 1]
  }

  /// Without a bridge to real terminals: Terminal from phone is only its setting.
  override func setTerminal(on: Bool) async throws {
    store.setBool(AppController.terminalKey, on)
    objectWillChange.send()
  }
}

/// Lets main-actor work started with `Task {}` (sign-in hooks, host events) run.
@MainActor
func settle(_ rounds: Int = 20) async {
  for _ in 0..<rounds { await Task.yield() }
}
#endif
