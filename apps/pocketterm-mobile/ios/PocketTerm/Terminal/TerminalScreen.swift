import PocketTermKit
import SwiftUI

/// One line of a terminal's screen, its ANSI escapes as styles in [colors]: colours, bold, italic, underline or
/// strike. An empty line is a space, so it keeps its height.
func screenLine(_ line: String, _ colors: TermColors) -> AttributedString {
  var out = AttributedString()
  for s in ansiSpans(line, colors) where !s.text.isEmpty {
    var a = AttributedString(s.text)
    a.swiftUI.foregroundColor = s.fg.color
    if let bg = s.bg { a.swiftUI.backgroundColor = bg.color }
    var intent: InlinePresentationIntent = []
    if s.bold { intent.insert(.stronglyEmphasized) }
    if s.italic { intent.insert(.emphasized) }
    if !intent.isEmpty { a.inlinePresentationIntent = intent }
    switch s.decoration {
    case .underline: a.swiftUI.underlineStyle = .single
    case .lineThrough: a.swiftUI.strikethroughStyle = .single
    case nil: break
    }
    out += a
  }
  return out.characters.isEmpty ? AttributedString(" ") : out
}

/// Each line's styled text, for the colours it was made in. Emptied past [kept] lines: a long-watched log would
/// otherwise keep every line it ever showed.
final class ScreenLines {
  static let kept = 2000

  private var colors: TermColors?
  private var lines: [String: AttributedString] = [:]

  func line(_ line: String, _ colors: TermColors) -> AttributedString {
    if colors != self.colors || lines.count >= Self.kept {
      self.colors = colors
      lines.removeAll(keepingCapacity: true)
    }
    if let made = lines[line] { return made }
    let made = screenLine(line, colors)
    lines[line] = made
    return made
  }
}

/// A terminal window's screen as text, live: bottom first, following new lines while at the bottom. Lines are
/// numbered from the first one the phone saw ([TermScreen.base]), so lines arriving or scrolling off the top
/// never move what's in view. [wrap]: long lines reflow to the phone's width; else they stay whole and the
/// screen scrolls sideways.
struct TerminalScreenView: View {
  let screen: TermScreen
  let colors: TermColors
  let wrap: Bool
  let cache: ScreenLines

  @State private var atBottom = true
  private static let end = "end"

  var body: some View {
    GeometryReader { box in
      ScrollViewReader { proxy in
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 10)
            ForEach(screen.base..<(screen.base + screen.lines.count), id: \.self) { n in
              Text(cache.line(screen.lines[n - screen.base], colors))
                .lineLimit(wrap ? nil : 1)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
            }
            // Seen: the screen is at its bottom, and follows what arrives.
            Color.clear
              .frame(height: 10)
              .id(Self.end)
              .onAppear { atBottom = true }
              .onDisappear { atBottom = false }
          }
          .padding(.horizontal, 10)
          .font(.mono(.caption2))
          .foregroundStyle(colors.foreground.color)
          .textSelection(.enabled)
          .frame(minWidth: box.size.width, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background(colors.background.color)
        .onChange(of: screen) { _, _ in
          if atBottom { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
        .onChange(of: wrap) { _, _ in
          if atBottom { proxy.scrollTo(Self.end, anchor: .bottom) }
        }
      }
    }
    .background(colors.background.color)
    .accessibilityIdentifier("term-screen")
  }
}
