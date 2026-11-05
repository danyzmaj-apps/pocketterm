import Foundation
import PocketTermKit
import Security

/// The phone's sign-in on its server, in the Keychain item the push extension and earlier versions use
/// (Shared/PocketTermShared.swift).
final class KeychainDeviceTokens: DeviceTokens {
  nonisolated init() {}

  nonisolated func read() async throws -> String? { PocketTermShared.deviceToken() }

  nonisolated func write(_ value: String?) async throws {
    if !PocketTermShared.setDeviceToken(value) {
      throw SecureStoreError(status: errSecIO, message: "Couldn't save the sign-in in the Keychain")
    }
  }
}

/// The connected server, kept in the App Group (`backendUrl`, `backendKind`) where the push extension and
/// earlier versions read it; `backendKey` is what a 0.1 app kept with a Supabase project.
final class AppGroupBackendStore: BackendStore {
  nonisolated init() {}

  nonisolated func loadBackend() -> (url: String, kind: String?, legacy: Bool)? {
    guard let url = PocketTermShared.backendUrl else { return nil }
    return (url, PocketTermShared.backendKind, PocketTermShared.legacyBackendKey != nil)
  }

  nonisolated func saveBackend(url: String?, kind: String?) {
    PocketTermShared.setBackend(url: url, kind: kind)
  }
}

/// Each computer's channel key, in the Keychain items the push extension opens pushes with.
enum ChannelKeys {
  static func all() -> [String: ChannelKey] {
    var keys: [String: ChannelKey] = [:]
    for (desktop, data) in PocketTermShared.channelKeys() {
      if let key = ChannelKey(data) { keys[desktop] = key }
    }
    return keys
  }

  static func set(_ key: ChannelKey, for desktop: String) throws {
    if !PocketTermShared.setChannelKey(key.bytes, for: desktop) {
      throw SecureStoreError(status: errSecIO, message: "Couldn't save the key in the Keychain")
    }
  }

  static func removeAll() { PocketTermShared.removeAllChannelKeys() }
}
