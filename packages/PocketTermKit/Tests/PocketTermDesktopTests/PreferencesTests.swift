#if os(macOS)
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

final class PreferencesTests: XCTestCase {
  /// A suite of this test's own, never the app's standard defaults.
  private func suite() -> UserDefaults {
    let name = "PocketTermTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return defaults
  }

  func testFlutterPreferencesAreCopiedOnceToTheirNativeKeysAsTheyWere() {
    let defaults = suite()
    // As shared_preferences_foundation kept them.
    defaults.set("dawn", forKey: "flutter.theme")
    defaults.set(true, forKey: "flutter.terminal_bridge")
    defaults.set(47901, forKey: "flutter.hosting_port")
    defaults.set(["/Users/me/Dev", "/Users/me/Work"], forKey: "flutter.project_roots")
    defaults.set(1.5, forKey: "flutter.zoom")
    defaults.set("ab12cd34", forKey: "flutter.desktop_id_user-1")
    defaults.set("other", forKey: "unrelated")

    XCTAssertEqual(
      migrateFlutterPreferences(defaults),
      ["desktop_id_user-1", "hosting_port", "project_roots", "terminal_bridge", "theme", "zoom"])
    let prefs = UserDefaultsPreferenceStore(defaults)
    XCTAssertEqual(prefs.string("theme"), "dawn")
    XCTAssertEqual(prefs.bool("terminal_bridge"), true)
    XCTAssertEqual(prefs.int("hosting_port"), 47901)
    XCTAssertEqual(prefs.stringList("project_roots"), ["/Users/me/Dev", "/Users/me/Work"])
    XCTAssertEqual(defaults.double(forKey: "zoom"), 1.5)
    XCTAssertEqual(prefs.string("desktop_id_user-1"), "ab12cd34")
    // The Flutter app's own are left for it.
    XCTAssertEqual(defaults.string(forKey: "flutter.theme"), "dawn")

    // Once: a Flutter value changed since (an older version run again) doesn't come over again.
    prefs.setString("theme", "gruvbox")
    defaults.set("tokyoNight", forKey: "flutter.theme")
    XCTAssertEqual(migrateFlutterPreferences(defaults), [])
    XCTAssertEqual(prefs.string("theme"), "gruvbox")
  }

  func testANativeValueIsNeverOverwritten() {
    let defaults = suite()
    defaults.set("dawn", forKey: "flutter.theme")
    defaults.set("auto", forKey: "flutter.terminal_app")
    defaults.set("gruvbox", forKey: "theme")
    XCTAssertEqual(migrateFlutterPreferences(defaults), ["terminal_app"])
    XCTAssertEqual(defaults.string(forKey: "theme"), "gruvbox")
    XCTAssertEqual(defaults.string(forKey: "terminal_app"), "auto")
  }

  func testNothingToMigrateStillCountsAsDone() {
    let defaults = suite()
    XCTAssertEqual(migrateFlutterPreferences(defaults), [])
    defaults.set("dawn", forKey: "flutter.theme")
    XCTAssertEqual(migrateFlutterPreferences(defaults), [])
    XCTAssertNil(defaults.string(forKey: "theme"))
  }

  func testTheStoreTellsAMissingValueFromAZeroOrFalseOne() {
    let prefs = UserDefaultsPreferenceStore(suite())
    XCTAssertNil(prefs.int("port"))
    XCTAssertNil(prefs.bool("on"))
    XCTAssertFalse(prefs.contains("on"))
    prefs.setInt("port", 0)
    prefs.setBool("on", false)
    XCTAssertEqual(prefs.int("port"), 0)
    XCTAssertEqual(prefs.bool("on"), false)
    XCTAssertTrue(prefs.contains("on"))
    // Another type is no value of this one.
    prefs.setString("name", "x")
    XCTAssertNil(prefs.int("name"))
    XCTAssertNil(prefs.stringList("name"))
    prefs.remove("on")
    XCTAssertNil(prefs.bool("on"))
  }
}
#endif
