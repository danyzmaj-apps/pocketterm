import Foundation
import PocketTermKit

/// The app's preferences in UserDefaults (the app's own, not the App Group's: only the server and the keys
/// are shared with the push extension), under the same key names the Flutter app used, without its
/// `flutter.` prefix ([FlutterPreferences] moves them over once).
final class Preferences: PreferenceStore, @unchecked Sendable {
  let defaults: UserDefaults

  init(_ defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func string(_ key: String) -> String? { defaults.string(forKey: key) }
  func setString(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
  func bool(_ key: String) -> Bool? { defaults.object(forKey: key) as? Bool }
  func setBool(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }
  func int(_ key: String) -> Int? { (defaults.object(forKey: key) as? NSNumber)?.intValue }
  func setInt(_ key: String, _ value: Int) { defaults.set(value, forKey: key) }
  func stringList(_ key: String) -> [String]? { defaults.object(forKey: key) as? [String] }
  func setStringList(_ key: String, _ value: [String]) { defaults.set(value, forKey: key) }
  func contains(_ key: String) -> Bool { defaults.object(forKey: key) != nil }
  func remove(_ key: String) { defaults.removeObject(forKey: key) }

  /// Every key starting with [prefix] (drafts, per-server push choices).
  func keys(withPrefix prefix: String) -> [String] {
    defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.sorted()
  }
}

/// PocketTerm before 0.2 was a Flutter app: shared_preferences kept every preference in the app's
/// UserDefaults as `flutter.<key>` (theme, list sort and folds, row names and colours, the computers list,
/// push choices, tips seen, the voice language, drafts …). The first launch of the native app moves each one
/// to `<key>` with its value as it is (strings, bools, ints, doubles and string lists alike), once: a key the
/// native app already has keeps its value.
enum FlutterPreferences {
  static let prefix = "flutter."

  /// Set once the move is done, so preferences the person later removes don't come back.
  static let doneKey = "pocketterm_migrated_flutter"

  static func migrate(_ defaults: UserDefaults) {
    if defaults.bool(forKey: doneKey) { return }
    for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
      let native = String(key.dropFirst(prefix.count))
      if !native.isEmpty && defaults.object(forKey: native) == nil {
        defaults.set(value, forKey: native)
      }
      defaults.removeObject(forKey: key)
    }
    defaults.set(true, forKey: doneKey)
  }
}
