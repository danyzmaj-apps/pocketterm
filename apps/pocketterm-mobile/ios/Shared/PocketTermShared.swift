import CryptoKit
import Foundation
import Security

/// What the app and its push extension share through the App Group: the
/// server the phone connected (written by
/// packages/pocketterm_core/lib/backend.dart), each computer's channel key
/// and the phone's sign-in on its server. Compiled into Runner and
/// PocketTermPush.
enum PocketTermShared {
  /// The App Group id, from config/PocketTerm.xcconfig through each target's
  /// Info.plist (`PocketTermAppGroup`).
  static let group = Bundle.main.object(forInfoDictionaryKey: "PocketTermAppGroup") as! String
  static let defaults = UserDefaults(suiteName: group)!

  /// The connected server's URL.
  static var backendUrl: String? { defaults.string(forKey: "backendUrl") }

  /// What kind of server it is: "supabase", or nil for a PocketTerm server.
  static var backendKind: String? { defaults.string(forKey: "backendKind") }

  /// Keeps the connected server (nil url: none).
  static func setBackend(url: String?, kind: String?) {
    if let url {
      defaults.set(url, forKey: "backendUrl")
    } else {
      defaults.removeObject(forKey: "backendUrl")
    }
    if let kind, url != nil {
      defaults.set(kind, forKey: "backendKind")
    } else {
      defaults.removeObject(forKey: "backendKind")
    }
    // A Supabase project's key, from an app before.
    defaults.removeObject(forKey: "backendKey")
  }

  /// The key an app from before saved with a Supabase project, if any: its
  /// URL is no PocketTerm server.
  static var legacyBackendKey: String? { defaults.string(forKey: "backendKey") }

  // MARK: Device token

  /// The phone's sign-in on its server (the device token and what came with
  /// it, one string the Dart side reads): one Keychain item, readable after
  /// the first unlock and never leaving this device.
  private static let tokenQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.danyzmaj.pocketterm.device-token",
    kSecAttrAccessGroup as String: group,
    kSecAttrAccount as String: "device",
  ]

  /// Replaces it; nil removes it. False if the Keychain refused.
  @discardableResult
  static func setDeviceToken(_ value: String?) -> Bool {
    SecItemDelete(tokenQuery as CFDictionary)
    guard let value else { return true }
    var add = tokenQuery
    add[kSecValueData as String] = Data(value.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  static func deviceToken() -> String? {
    var query = tokenQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
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

  /// Every computer's key, also ones the app never loaded (sign-out).
  static func removeAllChannelKeys() {
    SecItemDelete(keyQuery() as CFDictionary)
  }

  /// Keychain items outlive the app: deleting PocketTerm leaves its keys and
  /// sign-in behind for a reinstall to pick up. The first launch after an
  /// install (the app's own UserDefaults go with the app) wipes them, before
  /// anything reads them.
  static func wipeKeychainAfterInstall() {
    let installed = "pocketterm.installed"
    guard !UserDefaults.standard.bool(forKey: installed) else { return }
    removeAllChannelKeys()
    setDeviceToken(nil)
    UserDefaults.standard.set(true, forKey: installed)
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

  /// What a push names the computer that sealed it by, instead of its id (pocketterm_core's pushTag): the first
  /// 8 bytes of HMAC-SHA256(key, "pocketterm/v1|push-tag"), base64url without padding.
  static func pushTag(_ key: Data) -> String {
    let mac = HMAC<SHA256>.authenticationCode(for: Data("pocketterm/v1|push-tag".utf8), using: SymmetricKey(data: key))
    return Data(mac).prefix(8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// The computer among [keys] (by id) whose push tag is [tag]: its id and key; nil when none.
  static func computer(tagged tag: String, in keys: [String: Data]) -> (desktop: String, key: Data)? {
    keys.first { pushTag($0.value) == tag }.map { (desktop: $0.key, key: $0.value) }
  }

  /// Opens [sealed] (nonce 12 ‖ ciphertext ‖ tag 16, AES-256-GCM) with [key]
  /// and [aad]; nil if it was made with another key or for anything else.
  static func open(_ sealed: Data, key: Data, aad: String) -> Data? {
    guard key.count == 32, sealed.count >= 12 + 16, let box = try? AES.GCM.SealedBox(combined: sealed) else {
      return nil
    }
    return try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
  }

  // MARK: Fresh pushes

  /// A sealed notice older (or further ahead) than this shows only the
  /// generic alert: the relay or anyone on the way can hold one back and
  /// send it again later.
  static let freshFor: TimeInterval = 10 * 60

  private static let seenKey = "seenPushIds"
  /// More than a computer sends in [freshFor].
  private static let seenKept = 256

  /// Whether a sealed notice made at [ts] (ms since 1970) with [id] is new:
  /// recent, and not seen before. Remembers [id] (the last 256) either way.
  static func isFreshPush(ts: Double?, id: String?) -> Bool {
    guard let ts, let id, !id.isEmpty else { return false }
    var seen = defaults.stringArray(forKey: seenKey) ?? []
    let repeated = seen.contains(id)
    if !repeated {
      seen.append(id)
      defaults.set(Array(seen.suffix(seenKept)), forKey: seenKey)
    }
    let age = Date().timeIntervalSince1970 - ts / 1000
    return !repeated && abs(age) <= freshFor
  }
}
