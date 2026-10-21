import CryptoKit
import Foundation
import Security

/// What the app and its push extension share through the App Group: the
/// backend (the Supabase project the user connected, written by
/// packages/pocketterm_core/lib/backend.dart) and each computer's channel key.
/// Compiled into Runner and PocketTermPush.
enum PocketTermShared {
  /// The App Group id, from config/PocketTerm.xcconfig through each target's
  /// Info.plist (`PocketTermAppGroup`).
  static let group = Bundle.main.object(forInfoDictionaryKey: "PocketTermAppGroup") as! String
  static let defaults = UserDefaults(suiteName: group)!

  /// The connected Supabase project: its URL and publishable key.
  struct Backend: Equatable {
    let url: String
    let key: String
  }

  static var backend: Backend? {
    get {
      guard let url = defaults.string(forKey: "backendUrl"), let key = defaults.string(forKey: "backendKey") else {
        return nil
      }
      return Backend(url: url, key: key)
    }
    set {
      if let newValue {
        defaults.set(newValue.url, forKey: "backendUrl")
        defaults.set(newValue.key, forKey: "backendKey")
      } else {
        defaults.removeObject(forKey: "backendUrl")
        defaults.removeObject(forKey: "backendKey")
      }
    }
  }

  // MARK: Channel keys

  /// Each computer's channel key (32 bytes), which the phone got only by
  /// scanning that computer's code. One Keychain item per computer, in the App
  /// Group's access group so the push extension reads it too, readable after
  /// the first unlock and never leaving this device (no backup, no iCloud).
  private static let keyService = "com.danyzmaj.pocketterm.channel-key"

  private static func keyQuery(_ desktop: String? = nil) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keyService,
      kSecAttrAccessGroup as String: group,
    ]
    if let desktop { q[kSecAttrAccount as String] = desktop }
    return q
  }

  /// Stores [key] for computer [desktop], replacing the one it had.
  @discardableResult
  static func setChannelKey(_ key: Data, for desktop: String) -> Bool {
    let query = keyQuery(desktop)
    SecItemDelete(query as CFDictionary)
    var add = query
    add[kSecValueData as String] = key
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  static func removeChannelKey(for desktop: String) {
    SecItemDelete(keyQuery(desktop) as CFDictionary)
  }

  static func channelKey(for desktop: String) -> Data? {
    var query = keyQuery(desktop)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
    return out as? Data
  }

  /// Every computer's key, by its id.
  static func channelKeys() -> [String: Data] {
    var query = keyQuery()
    query[kSecReturnAttributes as String] = true
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
      let items = out as? [[String: Any]]
    else { return [:] }
    var keys: [String: Data] = [:]
    for item in items {
      if let desktop = item[kSecAttrAccount as String] as? String, let key = item[kSecValueData as String] as? Data {
        keys[desktop] = key
      }
    }
    return keys
  }

  /// Opens [sealed] (nonce 12 ‖ ciphertext ‖ tag 16, AES-256-GCM) with [key]
  /// and [aad]; nil if it was made with another key or for anything else.
  static func open(_ sealed: Data, key: Data, aad: String) -> Data? {
    guard key.count == 32, sealed.count >= 12 + 16, let box = try? AES.GCM.SealedBox(combined: sealed) else {
      return nil
    }
    return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
  }
}
