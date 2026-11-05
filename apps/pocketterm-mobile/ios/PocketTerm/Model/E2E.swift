import Foundation

/// A debug build run by the end-to-end tests and Maestro flows (as the Flutter app's
/// `--dart-define=POCKETTERM_E2E=true` build was): the scanner takes a pasted code (the Simulator has no
/// camera), the first-use tips start out seen, with no question whether to have them, until Show tips again,
/// and the composer's microphone hears a scripted speaker (no microphone either). Switched on by the
/// `POCKETTERM_E2E` launch argument (`-POCKETTERM_E2E true`, Maestro's `launchApp: arguments:`) or environment
/// variable. Release builds compile it out: always false.
enum E2E {
  static let enabled: Bool = {
    #if DEBUG && POCKETTERM_E2E
      let p = ProcessInfo.processInfo
      if let v = p.environment["POCKETTERM_E2E"], ["1", "true", "yes"].contains(v.lowercased()) { return true }
      if p.arguments.contains("POCKETTERM_E2E") || p.arguments.contains("--POCKETTERM_E2E") { return true }
      return UserDefaults.standard.bool(forKey: "POCKETTERM_E2E")
    #else
      return false
    #endif
  }()

  /// A fresh install's preferences for a flow that asks (launch argument `POCKETTERM_E2E_FRESH`): Maestro's
  /// `clearState` empties the app's data container, but the Simulator's preferences daemon still holds the old
  /// UserDefaults (and the App Group's live outside it), so the theme, the tips seen and the server came back.
  /// Called first thing at launch, before anything reads them.
  static func clearPreferencesIfAsked() {
    #if DEBUG && POCKETTERM_E2E
      // Maestro passes it as `-POCKETTERM_E2E_FRESH true`: the argument domain, which a cleared domain keeps.
      guard enabled, UserDefaults.standard.bool(forKey: "POCKETTERM_E2E_FRESH") else { return }
      if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
      UserDefaults(suiteName: PocketTermShared.group)?.removePersistentDomain(forName: PocketTermShared.group)
    #endif
  }
}

/// PocketTerm's home: the source, the docs and the desktop downloads.
enum Links {
  static let repo = URL(string: "https://github.com/danyzmaj-apps/pocketterm")!

  /// The desktop app's latest release (Mac DMG, Windows installer).
  static let desktopDownloads = URL(string: "https://github.com/danyzmaj-apps/pocketterm/releases/latest")!
}
