import Combine
import XCTest

@testable import PocketTermKit

@MainActor
final class ThemeTests: XCTestCase {
  func testSystemUntilAThemeIsPickedThePickedOneKept() {
    let prefs = MemoryPreferenceStore()
    let first = Appearance()
    first.load(prefs)
    XCTAssertEqual(first.choice, .system)
    XCTAssertEqual(first.theme, .systemLight)
    XCTAssertNil(prefs.string(Appearance.prefsKey), "nothing kept until a pick")
    var changes = 0
    let sub = first.objectWillChange.sink { changes += 1 }
    defer { sub.cancel() }

    first.choose(.rosePine)
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(first.theme, .dawn)
    XCTAssertEqual(prefs.string(Appearance.prefsKey), "rosePine")

    // Picking it again changes nothing.
    first.choose(.rosePine)
    XCTAssertEqual(changes, 1)

    // The next launch reads it back.
    let next = Appearance()
    next.load(prefs)
    XCTAssertEqual(next.choice, .rosePine)
  }

  func testEarlierVersionsNamesMoveToTheirFamilyAndAreKeptSo() {
    let cases: [(String, ThemeChoice)] = [
      ("mocha", .catppuccin), ("auto", .catppuccin), ("gruvbox", .catppuccin), ("dawn", .rosePine),
      ("tokyoNight", .tokyoNight), ("solarized", .system), ("system", .system), ("catppuccin", .catppuccin),
    ]
    for (kept, want) in cases {
      let prefs = MemoryPreferenceStore()
      prefs.setString(Appearance.prefsKey, kept)
      let appearance = Appearance()
      appearance.load(prefs)
      XCTAssertEqual(appearance.choice, want, kept)
      XCTAssertEqual(prefs.string(Appearance.prefsKey), want.rawValue, kept)
    }
    XCTAssertEqual(ThemeChoice.migrating(nil), .system)
  }

  func testThePaletteFollowsTheSystemsAppearance() {
    let appearance = Appearance()
    appearance.load(MemoryPreferenceStore())
    appearance.choose(.catppuccin)
    XCTAssertEqual(appearance.theme, .latte)
    var changes = 0
    let sub = appearance.objectWillChange.sink { changes += 1 }
    defer { sub.cancel() }
    appearance.follow(dark: true)
    XCTAssertEqual(appearance.theme, .mocha)
    appearance.follow(dark: true)
    XCTAssertEqual(changes, 1, "the same appearance again publishes nothing")
    appearance.choose(.tokyoNight)
    XCTAssertEqual(appearance.theme, .tokyoNight)
    appearance.follow(dark: false)
    XCTAssertEqual(appearance.theme, .tokyoNightDay)
  }

  func testEveryFamilyHasALightAndADarkHalf() {
    XCTAssertEqual(ThemeChoice.allCases.map(\.rawValue), ["system", "catppuccin", "rosePine", "tokyoNight"])
    XCTAssertEqual(ThemeChoice.allCases.map(\.label), ["System", "Catppuccin", "Rosé Pine", "Tokyo Night"])
    for choice in ThemeChoice.allCases {
      XCTAssertEqual(choice.light.brightness, .light, choice.rawValue)
      XCTAssertEqual(choice.dark.brightness, .dark, choice.rawValue)
      XCTAssertEqual(choice.palette(dark: true), choice.dark)
      XCTAssertEqual(choice.palette(dark: false), choice.light)
      XCTAssertEqual(choice.light.platformAccent, choice == .system)
      XCTAssertEqual(choice.dark.platformAccent, choice == .system)
    }
  }

  func testSystemIsBlackOnWhiteOrLightOnNearBlackWithXtermsColors() {
    XCTAssertEqual(PtTheme.systemLight.win, TermColor(argb: 0xFFFF_FFFF))
    XCTAssertEqual(PtTheme.systemLight.text, TermColor(argb: 0xFF00_0000))
    XCTAssertEqual(PtTheme.systemDark.win, TermColor(argb: 0xFF1E_1E1E))
    XCTAssertEqual(PtTheme.systemLight.ansi, PtTheme.systemDark.ansi)
    XCTAssertEqual(PtTheme.systemDark.ansi[1], TermColor(argb: 0xFFCD_0000))
    XCTAssertEqual(PtTheme.systemDark.ansi[12], TermColor(argb: 0xFF5C_5CFF))
  }

  func testOfficialPaletteSpotChecks() {
    XCTAssertEqual(PtTheme.latte.win, TermColor(argb: 0xFFEF_F1F5))
    XCTAssertEqual(PtTheme.mocha.accent, TermColor(argb: 0xFFCB_A6F7))
    XCTAssertEqual(PtTheme.dawn.text, TermColor(argb: 0xFF57_5279))
    XCTAssertEqual(PtTheme.rosePine.win, TermColor(argb: 0xFF19_1724))
    XCTAssertEqual(PtTheme.tokyoNightDay.win, TermColor(argb: 0xFFE1_E2E7))
    XCTAssertEqual(PtTheme.tokyoNight.ansi[9], TermColor(argb: 0xFFFF_899D))
  }

  func testTermColorsFromAPalette() {
    let colors = PtTheme.mocha.termColors
    XCTAssertEqual(colors.foreground, PtTheme.mocha.text)
    XCTAssertEqual(colors.background, PtTheme.mocha.win)
    XCTAssertEqual(colors.palette.count, 256)
    XCTAssertEqual(Array(colors.palette.prefix(16)), PtTheme.mocha.ansi)
    XCTAssertEqual(colors.palette[16...], TermColors.fallback.palette[16...])
  }
}
