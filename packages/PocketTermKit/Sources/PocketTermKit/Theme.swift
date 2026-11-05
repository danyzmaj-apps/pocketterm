import Combine
import Foundation

/// Light or dark, as a palette is.
public enum ThemeBrightness: String, Hashable, Sendable {
  case light
  case dark
}

/// One half of a theme, light or dark: what colors terminal screens, code blocks and the accent. The app's
/// chrome is the system's own; read the palette showing now through [Appearance].
public struct PtTheme: Hashable, Sendable {
  public let name: String
  public let brightness: ThemeBrightness

  /// The terminal screen's and code blocks' background.
  public let win: TermColor
  /// Bars over a terminal screen (the keys bar).
  public let bar: TermColor
  /// Fields and pressed rows on a terminal screen.
  public let field: TermColor
  /// The selected row or tab.
  public let sel: TermColor
  /// Borders and separators.
  public let line: TermColor
  /// The terminal's default foreground.
  public let text: TermColor
  /// Secondary text.
  public let dim: TermColor
  /// Hints and what's off.
  public let dim2: TermColor
  /// The accent; on [platformAccent] palettes only a stand-in for the system's own.
  public let accent: TermColor
  /// Text and icons on [accent].
  public let onAccent: TermColor
  public let ok: TermColor
  public let warn: TermColor
  public let error: TermColor
  /// Raised surfaces over a terminal screen.
  public let card: TermColor
  public let cursor: TermColor
  /// Selected text's background (it may be translucent).
  public let selection: TermColor
  /// ANSI colors 0–15: 8 normal, then 8 bright.
  public let ansi: [TermColor]
  /// The accent is the platform's (the system theme): apps put their own in place of [accent].
  public let platformAccent: Bool

  public init(
    name: String, brightness: ThemeBrightness, win: TermColor, bar: TermColor, field: TermColor, sel: TermColor,
    line: TermColor, text: TermColor, dim: TermColor, dim2: TermColor, accent: TermColor, onAccent: TermColor,
    ok: TermColor, warn: TermColor, error: TermColor, card: TermColor, cursor: TermColor, selection: TermColor,
    ansi: [TermColor], platformAccent: Bool = false
  ) {
    precondition(ansi.count == 16, "a palette has 16 ANSI colors")
    self.name = name
    self.brightness = brightness
    self.win = win
    self.bar = bar
    self.field = field
    self.sel = sel
    self.line = line
    self.text = text
    self.dim = dim
    self.dim2 = dim2
    self.accent = accent
    self.onAccent = onAccent
    self.ok = ok
    self.warn = warn
    self.error = error
    self.card = card
    self.cursor = cursor
    self.selection = selection
    self.ansi = ansi
    self.platformAccent = platformAccent
  }

  public var dark: Bool { brightness == .dark }

  /// A terminal's colors from this palette: its foreground and background, its 16 ANSI colors, then xterm's
  /// cube and greys (for a terminal the computer hasn't sent the colors of).
  public var termColors: TermColors {
    TermColors(foreground: text, background: win, palette: ansi + (16..<256).map(TermColors.xterm))
  }

  private static func c(_ rgb: UInt32) -> TermColor { TermColor(argb: 0xFF00_0000 | rgb) }
  private static func palette(_ rgb: [UInt32]) -> [TermColor] { rgb.map(c) }

  /// xterm's 16 basic colors, the System theme's in light and dark alike
  /// (https://github.com/ThomasDickey/xterm-snapshots/blob/master/XTerm-col.ad, the same as TermColors.xterm).
  public static let xterm16: [TermColor] = (0..<16).map(TermColors.xterm)

  // System: Apple Terminal's Basic profile, black on white or light on near-black, with xterm's colors; the
  // greys, greens, oranges and reds are Apple's system colors
  // (https://developer.apple.com/design/human-interface-guidelines/color). The accent is the platform's.
  public static let systemLight = PtTheme(
    name: "System Light", brightness: .light,
    win: c(0xFFFFFF), bar: c(0xF2F2F7), field: c(0xF2F2F7), sel: c(0xE5E5EA), line: c(0xC6C6C8),
    text: c(0x000000), dim: c(0x8E8E93), dim2: c(0xAEAEB2), accent: c(0x007AFF), onAccent: c(0xFFFFFF),
    ok: c(0x34C759), warn: c(0xFF9500), error: c(0xFF3B30), card: c(0xF2F2F7), cursor: c(0x929292),
    selection: c(0xB3D7FF), ansi: xterm16, platformAccent: true
  )

  public static let systemDark = PtTheme(
    name: "System Dark", brightness: .dark,
    win: c(0x1E1E1E), bar: c(0x1C1C1E), field: c(0x2C2C2E), sel: c(0x3A3A3C), line: c(0x38383A),
    text: c(0xF2F2F2), dim: c(0x8E8E93), dim2: c(0x636366), accent: c(0x0A84FF), onAccent: c(0xFFFFFF),
    ok: c(0x30D158), warn: c(0xFF9F0A), error: c(0xFF453A), card: c(0x1C1C1E), cursor: c(0x929292),
    selection: c(0x3F638B), ansi: xterm16, platformAccent: true
  )

  // Catppuccin: https://github.com/catppuccin/palette/blob/main/palette.json (v1.8.0, colors and ansiColors);
  // cursor Rosewater and selection Overlay 2 at 25% as https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md has them.
  public static let latte = PtTheme(
    name: "Catppuccin Latte", brightness: .light,
    win: c(0xEFF1F5), bar: c(0xE6E9EF), field: c(0xCCD0DA), sel: c(0xCCD0DA), line: c(0xBCC0CC),
    text: c(0x4C4F69), dim: c(0x6C6F85), dim2: c(0x8C8FA1), accent: c(0x8839EF), onAccent: c(0xEFF1F5),
    ok: c(0x40A02B), warn: c(0xFE640B), error: c(0xD20F39), card: c(0xE6E9EF), cursor: c(0xDC8A78),
    selection: TermColor(argb: 0x407C_7F93),
    ansi: palette([
      0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
      0x6C6F85, 0xDE293E, 0x49AF3D, 0xEEA02D, 0x456EFF, 0xFE85D8, 0x2D9FA8, 0xBCC0CC,
    ])
  )

  public static let mocha = PtTheme(
    name: "Catppuccin Mocha", brightness: .dark,
    win: c(0x1E1E2E), bar: c(0x181825), field: c(0x313244), sel: c(0x313244), line: c(0x45475A),
    text: c(0xCDD6F4), dim: c(0xA6ADC8), dim2: c(0x7F849C), accent: c(0xCBA6F7), onAccent: c(0x1E1E2E),
    ok: c(0xA6E3A1), warn: c(0xFAB387), error: c(0xF38BA8), card: c(0x181825), cursor: c(0xF5E0DC),
    selection: TermColor(argb: 0x4093_99B2),
    ansi: palette([
      0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
      0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE,
    ])
  )

  // Rosé Pine: https://rosepinetheme.com/palette/ingredients/ (roles: love errors, gold warnings, foam
  // additions); cursor, selection and ANSI colors from https://github.com/rose-pine/kitty/tree/main/dist.
  public static let dawn = PtTheme(
    name: "Rosé Pine Dawn", brightness: .light,
    win: c(0xFAF4ED), bar: c(0xF2E9E1), field: c(0xF2E9E1), sel: c(0xDFDAD9), line: c(0xDFDAD9),
    text: c(0x575279), dim: c(0x797593), dim2: c(0x9893A5), accent: c(0x286983), onAccent: c(0xFAF4ED),
    ok: c(0x56949F), warn: c(0xEA9D34), error: c(0xB4637A), card: c(0xFFFAF3), cursor: c(0xCECACD),
    selection: c(0xDFDAD9),
    ansi: palette([
      0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
      0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
    ])
  )

  public static let rosePine = PtTheme(
    name: "Rosé Pine", brightness: .dark,
    win: c(0x191724), bar: c(0x1F1D2E), field: c(0x26233A), sel: c(0x403D52), line: c(0x403D52),
    text: c(0xE0DEF4), dim: c(0x908CAA), dim2: c(0x6E6A86), accent: c(0x9CCFD8), onAccent: c(0x191724),
    ok: c(0x31748F), warn: c(0xF6C177), error: c(0xEB6F92), card: c(0x1F1D2E), cursor: c(0x524F67),
    selection: c(0x403D52),
    ansi: palette([
      0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
      0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
    ])
  )

  // Tokyo Night: https://github.com/folke/tokyonight.nvim/blob/main/extras/lua/tokyonight_day.lua and
  // tokyonight_night.lua (bg, bg_dark, bg_highlight, bg_visual, fg_gutter, fg, dark5, comment, blue, green,
  // orange, red); cursor and ANSI colors from extras/kitty/tokyonight_day.conf and tokyonight_night.conf.
  public static let tokyoNightDay = PtTheme(
    name: "Tokyo Night Day", brightness: .light,
    win: c(0xE1E2E7), bar: c(0xD0D5E3), field: c(0xC4C8DA), sel: c(0xB7C1E3), line: c(0xA8AECB),
    text: c(0x3760BF), dim: c(0x68709A), dim2: c(0x848CB5), accent: c(0x2E7DE9), onAccent: c(0xE1E2E7),
    ok: c(0x587539), warn: c(0xB15C00), error: c(0xF52A65), card: c(0xD0D5E3), cursor: c(0x3760BF),
    selection: c(0xB7C1E3),
    ansi: palette([
      0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
      0xA1A6C5, 0xFF4774, 0x5C8524, 0xA27629, 0x358AFF, 0xA463FF, 0x007EA8, 0x3760BF,
    ])
  )

  public static let tokyoNight = PtTheme(
    name: "Tokyo Night", brightness: .dark,
    win: c(0x1A1B26), bar: c(0x16161E), field: c(0x292E42), sel: c(0x283457), line: c(0x3B4261),
    text: c(0xC0CAF5), dim: c(0x737AA2), dim2: c(0x565F89), accent: c(0x7AA2F7), onAccent: c(0x16161E),
    ok: c(0x9ECE6A), warn: c(0xFF9E64), error: c(0xF7768E), card: c(0x16161E), cursor: c(0xC0CAF5),
    selection: c(0x283457),
    ansi: palette([
      0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
      0x414868, 0xFF899D, 0x9FE044, 0xFABA4A, 0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5,
    ])
  )
}

/// The theme the person picked; [system] until they pick one. Each has a light and a dark palette, shown as
/// the system's appearance is. The raw value is the name kept in the preferences.
public enum ThemeChoice: String, CaseIterable, Hashable, Sendable {
  case system
  case catppuccin
  case rosePine
  case tokyoNight

  public var label: String {
    switch self {
    case .system: "System"
    case .catppuccin: "Catppuccin"
    case .rosePine: "Rosé Pine"
    case .tokyoNight: "Tokyo Night"
    }
  }

  public var light: PtTheme {
    switch self {
    case .system: .systemLight
    case .catppuccin: .latte
    case .rosePine: .dawn
    case .tokyoNight: .tokyoNightDay
    }
  }

  public var dark: PtTheme {
    switch self {
    case .system: .systemDark
    case .catppuccin: .mocha
    case .rosePine: .rosePine
    case .tokyoNight: .tokyoNight
    }
  }

  /// The half that goes with the system's appearance.
  public func palette(dark: Bool) -> PtTheme { dark ? self.dark : light }

  /// The accent is the platform's own.
  public var platformAccent: Bool { self == .system }

  /// The choice a kept name stands for: this version's names, and those of earlier ones (`mocha` and 0.1.2's
  /// `auto` → Catppuccin, `dawn` → Rosé Pine, `gruvbox`, which is gone, → Catppuccin); nothing kept, or a
  /// name no version had → System.
  public static func migrating(_ kept: String?) -> ThemeChoice {
    guard let kept else { return .system }
    if let choice = ThemeChoice(rawValue: kept) { return choice }
    switch kept {
    case "mocha", "auto", "gruvbox": return .catppuccin
    case "dawn": return .rosePine
    default: return .system
    }
  }
}

/// The active theme, the choice behind it and the system's appearance, kept per device; publishes when either
/// changes. The app reads it through [appearance] and tells it the system's appearance ([follow(dark:)]).
@MainActor
public final class Appearance: ObservableObject {
  /// The preference the choice is kept under.
  public nonisolated static let prefsKey = "theme"

  private var prefs: PreferenceStore?

  @Published public private(set) var choice: ThemeChoice = .system
  /// The system shows dark.
  @Published public private(set) var dark = false

  public init() {}

  /// The palette showing now.
  public var theme: PtTheme { choice.palette(dark: dark) }

  /// Reads the kept choice ([ThemeChoice.migrating]); an earlier version's name is kept under this version's.
  public func load(_ prefs: PreferenceStore) {
    self.prefs = prefs
    let kept = prefs.string(Self.prefsKey)
    choice = ThemeChoice.migrating(kept)
    if let kept, kept != choice.rawValue { prefs.setString(Self.prefsKey, choice.rawValue) }
  }

  /// Shows [choice] now and keeps it.
  public func choose(_ choice: ThemeChoice) {
    if choice == self.choice { return }
    self.choice = choice
    prefs?.setString(Self.prefsKey, choice.rawValue)
  }

  /// The system's appearance changed (or is first known).
  public func follow(dark: Bool) {
    if dark != self.dark { self.dark = dark }
  }
}

/// The app's one [Appearance].
@MainActor public let appearance = Appearance()
