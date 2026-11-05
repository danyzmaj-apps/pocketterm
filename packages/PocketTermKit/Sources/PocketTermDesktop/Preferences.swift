#if os(macOS)
import Foundation
import PocketTermKit

/// The Mac app's preferences: plain keys in UserDefaults (the standard ones; tests pass a suite of their own).
public final class UserDefaultsPreferenceStore: PreferenceStore, @unchecked Sendable {
  public let defaults: UserDefaults

  public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

  public func string(_ key: String) -> String? { defaults.object(forKey: key) as? String }
  public func setString(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
  public func bool(_ key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
  public func setBool(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }
  public func int(_ key: String) -> Int? { defaults.object(forKey: key) as? Int }
  public func setInt(_ key: String, _ value: Int) { defaults.set(value, forKey: key) }
  public func stringList(_ key: String) -> [String]? { defaults.object(forKey: key) as? [String] }
  public func setStringList(_ key: String, _ value: [String]) { defaults.set(value, forKey: key) }
  public func contains(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
  public func remove(_ key: String) { defaults.removeObject(forKey: key) }
}

/// Set once `migrateFlutterPreferences` has run on these defaults.
let flutterMigratedKey = "flutter_preferences_migrated"

/// The Flutter app's shared_preferences (shared_preferences_foundation's legacy API): every key as `flutter.<key>`
/// in the standard UserDefaults, its value as is (a String, an NSNumber for a bool, int or double, an array of
/// strings). Copied once to `<key>`, the native app's name for it; a value the native app already has stays. The
/// `flutter.` entries are left, so an older version still finds its own. Returns the keys copied.
@discardableResult
public func migrateFlutterPreferences(_ defaults: UserDefaults = .standard) -> [String] {
  if defaults.bool(forKey: flutterMigratedKey) { return [] }
  let prefix = "flutter."
  var copied: [String] = []
  for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) && key.count > prefix.count {
    let native = String(key.dropFirst(prefix.count))
    if defaults.object(forKey: native) != nil { continue }
    defaults.set(value, forKey: native)
    copied.append(native)
  }
  defaults.set(true, forKey: flutterMigratedKey)
  return copied.sorted()
}
#endif
