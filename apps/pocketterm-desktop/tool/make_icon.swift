// Draws the app icons: a phone showing a terminal prompt, leaning out of a jeans pocket, in a theme's colors and
// corners (packages/pocketterm_core/lib/logo.dart's LogoStyle draws the same; lib/app_icon.dart names them). The
// app's own icon is Catppuccin Mocha's, the default theme; the other themes' are alternates the apps switch to.
//   swift tool/make_icon.swift   (in apps/pocketterm-desktop; needs ImageMagick's `magick`)
//     The app's own icon (Catppuccin Mocha):
//     → ../pocketterm-mobile/assets/icon/ios.png (square, opaque)
//       ../pocketterm-mobile/assets/icon/android-background.png, android-foreground.png
//         (Android's adaptive icon: the gradient, and the pocket alone inside the safe zone)
//       assets/icon/macos.png (rounded, padded)
//       windows/runner/resources/app_icon.ico, assets/tray.ico (rounded, full bleed), assets/icon/windows-default.ico
//     Then in each app: fvm dart run flutter_launcher_icons (in the phone's it also points every launcher alias
//       in AndroidManifest.xml at ic_launcher and sets Runner's ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES to
//       AppIcon: put both back with git)
//     Each other theme's (dawn, tokyoNight, gruvbox), used as they are:
//     → ../pocketterm-mobile/ios/Runner/Assets.xcassets/AppIcon-<Theme>.appiconset (iOS alternate icons)
//       ../pocketterm-mobile/android/app/src/main/res/drawable-*dpi/ic_launcher_<theme>_{background,foreground}.png,
//         mipmap-anydpi-v26/ic_launcher_<theme>.xml (the launcher aliases' adaptive icons)
//       assets/icon/macos-<theme>.png (the Dock icon), assets/icon/windows-<theme>.ico (window and taskbar),
//       assets/icon/tray-<theme>.ico (Windows' tray item)
import AppKit

/// What an icon is drawn in.
struct Look {
  var tileTop: NSColor
  var tileBottom: NSColor
  var pocketTop: NSColor
  var pocketBottom: NSColor
  var screen: NSColor
  var frame: NSColor
  var prompt: NSColor
  /// The phone's corner radius, a fraction of the art's width.
  var phoneRadius: CGFloat
  /// Square caps, joins and cursor (Gruvbox's boxy shape).
  var square: Bool
}

func rgb(_ hex: UInt32) -> NSColor {
  NSColor(
    srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
    alpha: 1)
}

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor { a.blended(withFraction: t, of: b)! }

/// A theme's look, as LogoStyle.of makes it: the frame its text, the screen its background, the prompt its
/// warning color, the pocket its accent; [radius] and [square] from its shape (soft, crisp, boxy).
func themed(bg: UInt32, accent: UInt32, warn: UInt32, text: UInt32, radius: CGFloat, square: Bool = false) -> Look {
  Look(
    tileTop: mix(rgb(bg), rgb(accent), 0.2), tileBottom: rgb(bg), pocketTop: rgb(accent),
    pocketBottom: mix(rgb(accent), rgb(bg), 0.35), screen: rgb(bg), frame: rgb(text), prompt: rgb(warn),
    phoneRadius: radius, square: square)
}

/// The app's own icon: Catppuccin Mocha's.
let mocha = themed(bg: 0x1E1E2E, accent: 0xCBA6F7, warn: 0xFAB387, text: 0xCDD6F4, radius: 0.056)

/// The alternates, by lib/app_icon.dart's names; [res]: Android's resource name.
let themes: [(name: String, res: String, look: Look)] = [
  ("dawn", "dawn", themed(bg: 0xFAF4ED, accent: 0x286983, warn: 0x9E6210, text: 0x534E73, radius: 0.056)),
  ("tokyoNight", "tokyo_night", themed(bg: 0x1A1B26, accent: 0x7AA2F7, warn: 0xFF9E64, text: 0xC0CAF5, radius: 0.03)),
  (
    "gruvbox", "gruvbox",
    themed(bg: 0x282828, accent: 0x7DAEA3, warn: 0xD8A657, text: 0xD4BE98, radius: 0.012, square: true)
  ),
]

/// [gradient]/[art]: which layers to draw; [scale]: the art's size around
/// the centre (Android's mask shows only the middle of its foreground);
/// [small]: the art for 24 px and under (see [drawArt]).
func render(
  _ look: Look, size: CGFloat, inset: CGFloat, radius: CGFloat, gradient: Bool = true, art: Bool = true,
  scale: CGFloat = 1, small: Bool = false, to path: String
) {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  if gradient {
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(starting: look.tileTop, ending: look.tileBottom)!.draw(in: shape, angle: -60)
  }
  if art {
    // Small: the art fills more of the body, nudged down so the phone clears the top edge.
    let s = small ? 1.3 : scale
    let area = body.insetBy(dx: body.width * (1 - s) / 2, dy: body.height * (1 - s) / 2)
    drawArt(look, in: small ? area.offsetBy(dx: 0, dy: -0.04 * body.height) : area, small: small)
  }
  image.unlockFocus()

  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// The phone and the pocket, in [rect]. [small] (24 px and under) drops the stitching,
/// which turns to mush that small, and bolds the phone's outline and the prompt.
func drawArt(_ look: Look, in rect: NSRect, small: Bool = false) {
  // Unit coordinates inside the body, y up.
  func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
  let w = rect.width
  let cap: NSBezierPath.LineCapStyle = look.square ? .square : .round
  let join: NSBezierPath.LineJoinStyle = look.square ? .miter : .round

  // A phone showing a terminal prompt, leaning right out of the pocket; the pocket covers its lower half.
  // Phone coordinates: centred on its pivot, y up, in units of [w] (logo.dart draws the same shapes).
  NSGraphicsContext.saveGraphicsState()
  let tilt = NSAffineTransform()
  tilt.translateX(by: p(0.5, 0.64).x, yBy: p(0.5, 0.64).y)
  tilt.rotate(byDegrees: -10)
  tilt.concat()
  let phone = NSBezierPath(
    roundedRect: NSRect(x: -0.15 * w, y: -0.26 * w, width: 0.30 * w, height: 0.50 * w),
    xRadius: look.phoneRadius * w, yRadius: look.phoneRadius * w)
  look.screen.setFill()
  phone.fill()
  phone.lineWidth = (small ? 0.03 : 0.018) * w
  look.frame.setStroke()
  phone.stroke()
  // The prompt: ">_" in the stitching's color.
  let chevron = NSBezierPath()
  chevron.move(to: NSPoint(x: -0.085 * w, y: 0.14 * w))
  chevron.line(to: NSPoint(x: -0.019 * w, y: 0.0896 * w))
  chevron.line(to: NSPoint(x: -0.085 * w, y: 0.0392 * w))
  chevron.lineWidth = (small ? 0.05 : 0.034) * w
  chevron.lineCapStyle = cap
  chevron.lineJoinStyle = join
  look.prompt.setStroke()
  chevron.stroke()
  look.prompt.setFill()
  let cursor = look.square ? 0 : 0.016 * w
  NSBezierPath(
    roundedRect: NSRect(x: 0.01 * w, y: 0.028 * w, width: 0.08 * w, height: 0.032 * w), xRadius: cursor,
    yRadius: cursor
  ).fill()
  NSGraphicsContext.restoreGraphicsState()

  // The pocket: a jeans back pocket, square top, pointed bottom.
  let pocket = NSBezierPath()
  pocket.move(to: p(0.22, 0.60))
  pocket.line(to: p(0.78, 0.60))
  pocket.line(to: p(0.78, 0.33))
  pocket.line(to: p(0.50, 0.17))
  pocket.line(to: p(0.22, 0.33))
  pocket.close()
  pocket.lineJoinStyle = .round
  NSGradient(starting: look.pocketTop, ending: look.pocketBottom)!.draw(in: pocket, angle: -90)
  if small { return }

  // Stitching just inside the edge, and the hem along the top.
  let stitch = NSBezierPath()
  stitch.move(to: p(0.255, 0.565))
  stitch.line(to: p(0.745, 0.565))
  stitch.line(to: p(0.745, 0.35))
  stitch.line(to: p(0.50, 0.21))
  stitch.line(to: p(0.255, 0.35))
  stitch.close()
  stitch.move(to: p(0.255, 0.535))
  stitch.line(to: p(0.745, 0.535))
  stitch.lineWidth = 0.011 * w
  stitch.lineCapStyle = cap
  stitch.setLineDash([0.022 * w, 0.02 * w], count: 2, phase: 0)
  look.prompt.withAlphaComponent(0.9).setStroke()
  stitch.stroke()
}

func run(_ args: [String]) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = args
  try! p.run()
  p.waitUntilExit()
  precondition(p.terminationStatus == 0, "\(args.joined(separator: " ")) failed")
}

func mkdir(_ dir: String) { try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }

func write(_ text: String, to path: String) { try! text.write(toFile: path, atomically: true, encoding: .utf8) }

let mobile = "../pocketterm-mobile"
let res = "\(mobile)/android/app/src/main/res"
for dir in ["assets/icon", "\(mobile)/assets/icon"] { mkdir(dir) }

// Windows: each size drawn on its own (the small art up to 24 px), packed by ImageMagick.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm-icon").path
mkdir(tmp)
func ico(_ look: Look, _ sizes: [Int], to path: String) {
  let pngs = sizes.map { n -> String in
    let png = "\(tmp)/\(n).png"
    render(look, size: CGFloat(n), inset: 0, radius: CGFloat(n) * 0.22, small: n <= 24, to: png)
    return png
  }
  run(["magick"] + pngs + [path])
}
// The app icon (window, taskbar, installer) and the tray item, which Windows shows at 16-32 px. The window's
// icon switched at runtime only needs the window's and the taskbar's sizes.
let windowSizes = [256, 128, 64, 48, 32, 24, 16]
let runtimeSizes = [64, 48, 40, 32, 24, 20, 16]
let traySizes = [48, 32, 24, 20, 16]

// The app's own icon: Catppuccin Mocha's.
render(mocha, size: 1024, inset: 0, radius: 0, to: "\(mobile)/assets/icon/ios.png")
// Android: a 108 dp layer of which a 72 dp middle shows (less on round masks); the pocket
// at 0.72 stays clear of every mask.
render(mocha, size: 1024, inset: 0, radius: 0, art: false, to: "\(mobile)/assets/icon/android-background.png")
render(
  mocha, size: 1024, inset: 0, radius: 0, gradient: false, scale: 0.72,
  to: "\(mobile)/assets/icon/android-foreground.png")
// macOS: Big Sur grid, 824 pt body inside the 1024 canvas.
render(mocha, size: 1024, inset: 100, radius: 185, to: "assets/icon/macos.png")
ico(mocha, windowSizes, to: "windows/runner/resources/app_icon.ico")
ico(mocha, traySizes, to: "assets/tray.ico")
// What the window goes back to from another theme's (lib/windows_host.dart).
ico(mocha, runtimeSizes, to: "assets/icon/windows-default.ico")

// Each other theme's.
for (name, resName, look) in themes {
  let title = name.prefix(1).uppercased() + name.dropFirst()
  // iOS: an alternate app icon set (Runner's ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES lists it), one opaque
  // 1024 image that Xcode scales.
  let set = "\(mobile)/ios/Runner/Assets.xcassets/AppIcon-\(title).appiconset"
  mkdir(set)
  render(look, size: 1024, inset: 0, radius: 0, to: "\(set)/icon-1024.png")
  run(["magick", "\(set)/icon-1024.png", "-alpha", "off", "\(set)/icon-1024.png"])
  write(
    """
    {
      "images" : [
        {
          "filename" : "icon-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "make_icon.swift",
        "version" : 1
      }
    }

    """, to: "\(set)/Contents.json")
  // Android: the adaptive icon's two layers at each density (108 dp), as for the default icon.
  for (dpi, px) in [("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)] {
    mkdir("\(res)/drawable-\(dpi)")
    render(
      look, size: CGFloat(px), inset: 0, radius: 0, art: false,
      to: "\(res)/drawable-\(dpi)/ic_launcher_\(resName)_background.png")
    render(
      look, size: CGFloat(px), inset: 0, radius: 0, gradient: false, scale: 0.72,
      to: "\(res)/drawable-\(dpi)/ic_launcher_\(resName)_foreground.png")
  }
  write(
    """
    <?xml version="1.0" encoding="utf-8"?>
    <!-- Drawn by apps/pocketterm-desktop/tool/make_icon.swift: the \(title) theme's launcher icon. -->
    <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
      <background android:drawable="@drawable/ic_launcher_\(resName)_background"/>
      <foreground android:drawable="@drawable/ic_launcher_\(resName)_foreground"/>
    </adaptive-icon>

    """, to: "\(res)/mipmap-anydpi-v26/ic_launcher_\(resName).xml")
  // macOS: the Dock icon while this theme shows, on the Big Sur grid at 512.
  render(look, size: 512, inset: 50, radius: 92.5, to: "assets/icon/macos-\(name).png")
  ico(look, runtimeSizes, to: "assets/icon/windows-\(name).ico")
  ico(look, traySizes, to: "assets/icon/tray-\(name).ico")
}
print("ok")
