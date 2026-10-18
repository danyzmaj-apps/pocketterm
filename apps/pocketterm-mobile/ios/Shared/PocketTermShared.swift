import Foundation
import Security

/// What the app and its push extension share through the App Group: the
/// backend (the Supabase project the user connected, written by
/// packages/pocketterm_core/lib/backend.dart) and the push key. Compiled
/// into Runner and PocketTermPush.
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

  /// This iPhone's push key (32 bytes): made here, given only to the user's
  /// own server (functions/push), which seals each notification with it; the
  /// PocketTermPush extension opens them. Made on first use, kept across sign-ins.
  /// Nil when the system had no random bytes to give: no push then.
  static var pushKey: Data? { defaults.data(forKey: "pushKey") }

  static func makePushKey() -> Data? {
    if let key = pushKey { return key }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
    let key = Data(bytes)
    defaults.set(key, forKey: "pushKey")
    return key
  }
}
