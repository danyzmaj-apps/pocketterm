import PocketTermKit
import SwiftUI
import UIKit

// The app's chrome is iOS's own (system colours, light and dark, SF fonts). The theme the person picks colours
// what is the terminal's: screens, code, and the accent everything tints with.

// Nonisolated: SwiftUI resolves colours on its render thread, not the main actor.
nonisolated extension TermColor {
  var color: Color {
    Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: Double(alpha) / 255)
  }

  var uiColor: UIColor {
    UIColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
  }

  /// Dark enough that what's on it reads in dark mode's colours (its perceived brightness under half).
  var isDark: Bool { Double(red) * 0.299 + Double(green) * 0.587 + Double(blue) * 0.114 < 128 }
}

/// A 0xAARRGGBB int ([tileColors]) as a colour.
func argbColor(_ argb: Int) -> Color { TermColor(argb: UInt32(truncatingIfNeeded: argb)).color }

nonisolated extension PtTheme {
  /// The tint of buttons, links and switches: iOS's own (the system blue) for System, else the theme's accent,
  /// its light or dark half's as the screen is.
  var tint: Color { platformAccent ? Color.accentColor : accent.color }
}

extension ThemeChoice {
  /// The launch screen's picture for this theme: the app's icon as it shows on the home screen.
  var launchIcon: String {
    switch appIconFor(self) {
    case "dawn": "LaunchIconDawn"
    case "tokyoNight": "LaunchIconTokyoNight"
    default: "LaunchIconMocha"
    }
  }
}

/// The terminal font: the system's monospaced one, at Dynamic Type's size for [style].
extension Font {
  static func mono(_ style: Font.TextStyle = .footnote) -> Font { .system(style, design: .monospaced) }
}

extension TileState {
  /// The colour that tells it: iOS's own orange, red and green, the theme's accent while working.
  func color(_ theme: PtTheme) -> Color {
    switch self {
    case .idle: .secondary
    case .working: theme.tint
    case .needsYou: .orange
    case .failed: .red
    case .paused: .secondary
    case .done: .green
    }
  }

  /// Its SF Symbol, for rows and badges.
  var symbol: String {
    switch self {
    case .idle: "sparkle"
    case .working: "sparkles"
    case .needsYou: "exclamationmark.bubble.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .paused: "pause.circle.fill"
    case .done: "checkmark.circle.fill"
    }
  }

  /// What VoiceOver says of it.
  var label: String {
    switch self {
    case .idle: "Idle"
    case .working: "Working"
    case .needsYou: "Needs you"
    case .failed: "Stopped on an error"
    case .paused: "Queue paused"
    case .done: "Done"
    }
  }
}

/// The theme showing now, for views: `@EnvironmentObject var look: Appearance` reads `look.theme`.
extension View {
  /// The theme's tint over everything below, following the person's choice and the system's light or dark.
  func themed(_ appearance: Appearance) -> some View {
    modifier(Themed(look: appearance))
  }
}

/// Tells [Appearance] whether the screen is dark, so `look.theme` is the half that goes with it; the root's
/// appearance is the system's (pages that dress as a terminal set theirs below it, never above).
private struct Themed: ViewModifier {
  @ObservedObject var look: Appearance
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    content
      .tint(look.theme.tint)
      .environmentObject(look)
      .onChange(of: scheme, initial: true) { _, scheme in look.follow(dark: scheme == .dark) }
  }
}

/// Haptics for what happens away from a view's own state (a send that went, a pick).
enum Haptics {
  /// Something went: a prompt, an answer.
  static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }

  /// A pick or a key pressed.
  static func picked() { UISelectionFeedbackGenerator().selectionChanged() }

  /// A long press that opened a menu.
  static func held() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

  /// Something went wrong.
  static func failed() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

/// A thin bar filled as far as the context window is: the accent, then orange above 70%, red above 90%.
struct ContextBar: View {
  let percent: Int
  @EnvironmentObject private var look: Appearance

  var body: some View {
    let p = min(max(percent, 0), 100)
    let color: Color = p > 90 ? .red : p > 70 ? .orange : look.theme.tint
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Color(.systemFill))
        Capsule().fill(color).frame(width: g.size.width * CGFloat(p) / 100)
      }
    }
    .frame(height: 3)
    .animation(.easeOut(duration: 0.28), value: p)
    .accessibilityElement()
    .accessibilityLabel("Context")
    .accessibilityValue("\(p)%")
  }
}

/// A small rounded label on a list row: a window's terminal ([termBadge]), or that it shows only as a screen.
struct TermBadge: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
  }
}

/// The line under a page's title saying what's wrong with the link to the computer ([LinkNote]), with a
/// spinner while connecting and Retry when it's stuck.
struct LinkNoteBar: View {
  @ObservedObject var remote: TerminalRemote

  var body: some View {
    if let note = LinkNote(remote) {
      HStack(spacing: 10) {
        if note.busy { ProgressView().controlSize(.small) }
        Text(note.text)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        if note.retry {
          Button("Retry") { remote.reconnect() }
            .font(.footnote.weight(.semibold))
            .accessibilityIdentifier("link-retry")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.bar)
      .accessibilityIdentifier("link-note")
      .transition(.opacity)
    }
  }
}
