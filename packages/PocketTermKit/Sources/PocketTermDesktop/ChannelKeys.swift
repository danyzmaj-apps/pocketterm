#if os(macOS)
import Foundation
import PocketTermKit

/// The system's secrets: the login Keychain (`KeychainStore`, the Flutter app's items as they are). A throwaway
/// `POCKETTERM_PROFILE` (tool/smoke: a test build tried out as installed) keeps them in memory instead and never
/// reaches the Keychain.
public final class SystemSecrets: SecureStore, @unchecked Sendable {
  /// `storage`: the Keychain if nil; tests pass their own. `env`: where `POCKETTERM_PROFILE` is read, `testHooks`
  /// if nil.
  public init(_ storage: SecureStore? = nil, env: [String: String]? = nil) {
    self.storage = storage ?? KeychainStore()
    memory = (env ?? testHooks())["POCKETTERM_PROFILE"].map { !$0.isEmpty } ?? false ? Self.profile : nil
  }

  /// The app's: the Keychain, or a throwaway profile's memory.
  public static func standard() -> SecureStore { SystemSecrets() }

  /// A throwaway profile's secrets, for as long as the process runs.
  private static let profile = MemorySecureStore()

  private let storage: SecureStore
  private let memory: MemorySecureStore?

  /// One operation at a time, across every SystemSecrets, as the Flutter app had it.
  private static let serial = NSLock()

  private func serial<T>(_ op: (SecureStore) throws -> T) rethrows -> T {
    if let memory { return try op(memory) }
    Self.serial.lock()
    defer { Self.serial.unlock() }
    return try op(storage)
  }

  public func data(_ account: String) throws -> Data? { try serial { try $0.data(account) } }
  public func setData(_ account: String, _ value: Data) throws { try serial { try $0.setData(account, value) } }
  public func remove(_ account: String) throws { try serial { try $0.remove(account) } }
}

/// This computer's sign-in on its server (the device token and what came with it), kept in its secrets next to
/// the channel keys.
public final class SecretDeviceTokens: DeviceTokens, @unchecked Sendable {
  static let name = "device_token"

  private let tokens: SecureStoreDeviceTokens

  public init(_ store: SecureStore) { tokens = SecureStoreDeviceTokens(store, account: Self.name) }

  public func read() async throws -> String? { try await tokens.read() }
  public func write(_ value: String?) async throws { try await tokens.write(value) }
}

/// This computer's channel keys (PocketTermKit's E2E), one per computer id (an account's, AppController): made the
/// first time one is needed, then kept in its secrets. Never sent to a server; a phone gets it from this computer's
/// QR code.
@MainActor
public final class ChannelKeys {
  public init(_ store: SecureStore) { self.store = store }

  private let store: SecureStore
  private var keys: [String: Task<ChannelKey, Error>] = [:]

  /// Computer `desktopId`'s key; two asking at once get the same one. A store that failed (a locked Keychain) is
  /// asked again next time.
  public func of(_ desktopId: String) async throws -> ChannelKey {
    let pending = keys[desktopId] ?? load(desktopId)
    keys[desktopId] = pending
    do {
      return try await pending.value
    } catch {
      if keys[desktopId] == pending { keys[desktopId] = nil }
      throw error
    }
  }

  /// A new key for `desktopId`: phones with the old one can't read it any more.
  @discardableResult
  public func reset(_ desktopId: String) async throws -> ChannelKey {
    let key = ChannelKey.generate()
    let store = store
    let name = Self.name(desktopId)
    try await Task.detached { try store.setData(name, Data(key.toBase64().utf8)) }.value
    keys[desktopId] = Task { key }
    return key
  }

  /// Off the main actor: the Keychain may wait for its dialog.
  private func load(_ desktopId: String) -> Task<ChannelKey, Error> {
    let store = store
    let name = Self.name(desktopId)
    return Task.detached {
      if let kept = try store.data(name).flatMap({ String(data: $0, encoding: .utf8) }),
        let key = ChannelKey.tryParse(kept)
      {
        return key
      }
      let key = ChannelKey.generate()
      try store.setData(name, Data(key.toBase64().utf8))
      return key
    }
  }

  static func name(_ desktopId: String) -> String { "channel_key_\(desktopId)" }
}
#endif
