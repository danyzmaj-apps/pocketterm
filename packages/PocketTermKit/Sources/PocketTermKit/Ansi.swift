import Foundation

/// A color as plain data: 0xAARRGGBB, as Flutter's `Color` holds it. The apps turn it into their own
/// color type.
public struct TermColor: Hashable, Sendable, CustomStringConvertible {
  public let argb: UInt32

  public init(argb: UInt32) { self.argb = argb }

  /// An opaque color from its channels.
  public init(red: Int, green: Int, blue: Int, alpha: Int = 255) {
    func c(_ v: Int) -> UInt32 { UInt32(v & 0xFF) }
    argb = c(alpha) << 24 | c(red) << 16 | c(green) << 8 | c(blue)
  }

  public var alpha: Int { Int(argb >> 24 & 0xFF) }
  public var red: Int { Int(argb >> 16 & 0xFF) }
  public var green: Int { Int(argb >> 8 & 0xFF) }
  public var blue: Int { Int(argb & 0xFF) }

  /// This color at [opacity] (0 to 1), as Flutter's `withValues(alpha:)` rounds it: 0.6 is 0x99.
  public func withOpacity(_ opacity: Double) -> TermColor {
    let a = UInt32((min(max(opacity, 0), 1) * 255).rounded())
    return TermColor(argb: a << 24 | (argb & 0x00FF_FFFF))
  }

  /// `#AARRGGBB`.
  public var hex: String { String(format: "#%08X", argb) }
  public var description: String { hex }
}

/// A terminal's colors: default foreground and background plus the 256-color palette, as the terminal
/// reports them (kitty's `get-colors`).
public struct TermColors: Hashable, Sendable {
  public let foreground: TermColor
  public let background: TermColor
  public let palette: [TermColor]

  public init(foreground: TermColor, background: TermColor, palette: [TermColor]) {
    self.foreground = foreground
    self.background = background
    self.palette = palette
  }

  /// `{fg, bg, palette}` as 0xRRGGBB ints, made opaque. Nil when a field is missing or not an int (Dart throws).
  public init?(json j: JSONObject) {
    guard let fg = j["fg"]?.int, let bg = j["bg"]?.int, let p = j["palette"]?.array else { return nil }
    var palette: [TermColor] = []
    palette.reserveCapacity(p.count)
    for c in p {
      guard let v = c.int else { return nil }
      palette.append(Self.opaque(v))
    }
    self.init(foreground: Self.opaque(fg), background: Self.opaque(bg), palette: palette)
  }

  private static func opaque(_ v: Int) -> TermColor { TermColor(argb: 0xFF00_0000 | UInt32(truncatingIfNeeded: v)) }

  /// The xterm defaults, until the Mac has sent the terminal's.
  public static let fallback = TermColors(
    foreground: TermColor(argb: 0xFFDD_DDDD),
    background: TermColor(argb: 0xFF00_0000),
    palette: (0..<256).map(xterm)
  )

  /// xterm's 256 colors: 16 basic, a 6×6×6 cube, 24 greys.
  public static func xterm(_ i: Int) -> TermColor {
    let basic: [UInt32] = [
      0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
      0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]
    if i < 16 { return TermColor(argb: 0xFF00_0000 | basic[i]) }
    if i < 232 {
      func level(_ v: Int) -> Int { v == 0 ? 0 : 55 + v * 40 }
      let n = i - 16
      return TermColor(red: level(n / 36), green: level(n / 6 % 6), blue: level(n % 6))
    }
    let g = 8 + (i - 232) * 10
    return TermColor(red: g, green: g, blue: g)
  }
}

/// How a span's text is lined: underline wins over a strike.
public enum AnsiDecoration: String, Hashable, Sendable {
  case underline
  case lineThrough
}

/// A run of terminal text in one style: Flutter's `TextSpan` as plain data.
public struct AnsiSpan: Hashable, Sendable {
  public let text: String
  public let fg: TermColor
  /// Nil: no background.
  public let bg: TermColor?
  public let bold: Bool
  public let italic: Bool
  public let decoration: AnsiDecoration?

  public init(text: String, fg: TermColor, bg: TermColor?, bold: Bool, italic: Bool, decoration: AnsiDecoration?) {
    self.text = text
    self.fg = fg
    self.bg = bg
    self.bold = bold
    self.italic = italic
    self.decoration = decoration
  }
}

private struct Pen {
  var fg: TermColor?
  var bg: TermColor?
  var bold = false
  var dim = false
  var italic = false
  var underline = false
  var strike = false
  var reverse = false

  mutating func reset() { self = Pen() }

  func span(_ text: String, _ c: TermColors) -> AnsiSpan {
    var f = fg ?? c.foreground
    var b = bg
    if reverse { (f, b) = (b ?? c.background, f) }
    if dim { f = f.withOpacity(0.6) }
    return AnsiSpan(
      text: text, fg: f, bg: b, bold: bold, italic: italic,
      decoration: underline ? .underline : strike ? .lineThrough : nil
    )
  }
}

// SGR, other CSI (or one cut off at the end), OSC (to BEL or ESC \, or cut off), DCS, APC, PM and SOS
// strings (kitty's graphics, tmux passthrough; to ESC \ or cut off), and any other escape: two bytes, or
// more with intermediates (a charset choice, ESC ( B, as WezTerm sends), or a lone ESC at the end.
// `\z`, not Dart's `$`: ICU's `$` also matches before a final line break.
private let escape = try! NSRegularExpression(
  pattern: #"\x1b\[([0-9;:]*)m|\x1b\[[0-9;:?<=>]*[ -/]*(?:[@-~]|\z)|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|"#
    + #"\x1b[P_^X][^\x1b]*(?:\x1b\\)?|\x1b[ -/]*[0-~]?"#
)

/// Terminal text with ANSI escapes as styled spans: SGR colors (16, 256 and truecolor, `;` or kitty's `:`
/// form) and attributes; every other escape (hyperlinks, prompt marks) is dropped. Spans aren't merged.
public func ansiSpans(_ text: String, _ colors: TermColors) -> [AnsiSpan] {
  let ns = text as NSString
  var spans: [AnsiSpan] = []
  var pen = Pen()
  var at = 0
  for m in escape.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
    if m.range.location > at {
      spans.append(pen.span(ns.substring(with: NSRange(location: at, length: m.range.location - at)), colors))
    }
    at = m.range.location + m.range.length
    let params = m.range(at: 1)
    if params.location != NSNotFound { sgr(ns.substring(with: params), &pen, colors) }
  }
  if at < ns.length { spans.append(pen.span(ns.substring(from: at), colors)) }
  return spans
}

/// Dart's `int.tryParse` on the digits an SGR holds: nil when empty or too large.
private func parseInt(_ s: Substring) -> Int? { Int(s) }

private func sgr(_ params: String, _ pen: inout Pen, _ colors: TermColors) {
  // `38:2:r:g:b` stays one group; `38;2;r;g;b` spreads over five.
  let groups: [Substring] = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false)
  // A palette entry, or none when a reported palette is short (Dart would throw).
  func palette(_ i: Int) -> TermColor? { i < colors.palette.count ? colors.palette[i] : nil }
  var i = 0
  while i < groups.count {
    defer { i += 1 }
    let parts = groups[i].split(separator: ":", omittingEmptySubsequences: false)
    let code = parseInt(parts[0]) ?? 0
    switch code {
    case 0: pen.reset()
    case 1: pen.bold = true
    case 2: pen.dim = true
    case 3: pen.italic = true
    case 4: pen.underline = parts.count < 2 || parts[1] != "0"
    case 7: pen.reverse = true
    case 9: pen.strike = true
    case 22:
      pen.bold = false
      pen.dim = false
    case 23: pen.italic = false
    case 24: pen.underline = false
    case 27: pen.reverse = false
    case 29: pen.strike = false
    case 30...37: pen.fg = palette(code - 30)
    case 39: pen.fg = nil
    case 40...47: pen.bg = palette(code - 40)
    case 49: pen.bg = nil
    case 90...97: pen.fg = palette(code - 90 + 8)
    case 100...107: pen.bg = palette(code - 100 + 8)
    case 38, 48, 58:
      let args: [Int?]
      if parts.count > 1 {
        args = parts.dropFirst().map(parseInt)
      } else {
        let mode = i + 1 < groups.count ? parseInt(groups[i + 1]) : nil
        let n = mode == 2 ? 4 : (mode == 5 ? 2 : 1)
        args = groups.dropFirst(i + 1).prefix(n).map(parseInt)
        i += args.count
      }
      let color = extended(args, colors)
      if code == 38 { pen.fg = color }
      if code == 48 { pen.bg = color }
    default: break
    }
  }
}

/// `5;n` or `2;[colorspace;]r;g;b`, without the leading 38/48.
private func extended(_ args: [Int?], _ colors: TermColors) -> TermColor? {
  guard let first = args.first else { return nil }
  if first == 5 && args.count > 1 {
    guard let n = args[1], n >= 0, n < colors.palette.count else { return nil }
    return colors.palette[n]
  }
  if first == 2 {
    let rgb = args.count >= 5 ? Array(args.suffix(3)) : Array(args.dropFirst())
    guard rgb.count == 3 else { return nil }
    return TermColor(red: rgb[0] ?? 0, green: rgb[1] ?? 0, blue: rgb[2] ?? 0)
  }
  return nil
}
