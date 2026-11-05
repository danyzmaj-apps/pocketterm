import XCTest

@testable import PocketTermKit

@MainActor
final class AppIconTests: XCTestCase {
  private struct NoIcons: Error {}

  /// Lets the queued icon changes run.
  private func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  func testTheIconFollowsThePickedThemeCatppuccinAndSystemBeingTheAppsOwn() async {
    let prefs = MemoryPreferenceStore()
    prefs.setString(Appearance.prefsKey, "tokyoNight")
    let appearance = Appearance()
    appearance.load(prefs)
    var applied: [String] = []
    let stop = followAppIcon(appearance) { applied.append($0) }
    defer { stop() }

    // The kept choice's at launch.
    await settle()
    XCTAssertEqual(applied, ["tokyoNight"])

    appearance.choose(.catppuccin)
    await settle()
    XCTAssertEqual(applied, ["tokyoNight", "default"])

    // System shows the same icon: nothing to change.
    appearance.choose(.system)
    await settle()
    XCTAssertEqual(applied, ["tokyoNight", "default"])

    appearance.choose(.rosePine)
    await settle()
    XCTAssertEqual(applied, ["tokyoNight", "default", "dawn"])
  }

  func testAFreshInstallKeepsTheAppsOwnIcon() async {
    let appearance = Appearance()
    appearance.load(MemoryPreferenceStore())
    var applied: [String] = []
    let stop = followAppIcon(appearance) { applied.append($0) }
    defer { stop() }
    await settle()
    XCTAssertEqual(applied, ["default"])
  }

  func testAPlatformWithoutTheSwitchDoesNotBreakTheThemeChange() async {
    let appearance = Appearance()
    appearance.load(MemoryPreferenceStore())
    let stop = followAppIcon(appearance) { _ in throw NoIcons() }
    defer { stop() }
    appearance.choose(.rosePine)
    await settle()
    XCTAssertEqual(appearance.choice, .rosePine)
  }

  func testStoppedItAppliesNoMore() async {
    let appearance = Appearance()
    appearance.load(MemoryPreferenceStore())
    var applied: [String] = []
    let stop = followAppIcon(appearance) { applied.append($0) }
    await settle()
    stop()
    appearance.choose(.rosePine)
    await settle()
    XCTAssertEqual(applied, ["default"])
  }

  func testIconNames() {
    XCTAssertEqual(ThemeChoice.allCases.map(appIconFor), ["default", "default", "dawn", "tokyoNight"])
  }
}
