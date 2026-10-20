// Draws the app icon: a phone showing a terminal prompt, leaning out of a jeans pocket, on the app's dark gradient.
//   swift tool/make_icon.swift   (in apps/pocketterm-desktop)
//     → ../pocketterm-mobile/assets/icon/ios.png (square, opaque)
//       ../pocketterm-mobile/assets/icon/android-background.png, android-foreground.png
//         (Android's adaptive icon: the gradient, and the pocket alone inside the safe zone)
//       assets/icon/macos.png (rounded, padded)
//       windows/runner/resources/app_icon.ico, assets/tray.ico (rounded, full bleed; needs ImageMagick's `magick`)
// Then in each app: fvm dart run flutter_launcher_icons
import AppKit

/// [gradient]/[art]: which layers to draw; [scale]: the art's size around
/// the centre (Android's mask shows only the middle of its foreground);
/// [small]: the art for 24 px and under (see [drawArt]).
func render(
  size: CGFloat, inset: CGFloat, radius: CGFloat, gradient: Bool = true, art: Bool = true, scale: CGFloat = 1,
  small: Bool = false, to path: String
) {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  if gradient {
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(
      starting: NSColor(red: 0.20, green: 0.24, blue: 0.40, alpha: 1),
      ending: NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
    )!.draw(in: shape, angle: -60)
  }
  if art {
    // Small: the art fills more of the body, nudged down so the phone clears the top edge.
    let s = small ? 1.3 : scale
    let area = body.insetBy(dx: body.width * (1 - s) / 2, dy: body.height * (1 - s) / 2)
    drawArt(in: small ? area.offsetBy(dx: 0, dy: -0.04 * body.height) : area, small: small)
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
func drawArt(in rect: NSRect, small: Bool = false) {
  // Unit coordinates inside the body, y up.
  func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
  let w = rect.width

  // A phone showing a terminal prompt, leaning right out of the pocket; the pocket covers its lower half.
  // Phone coordinates: centred on its pivot, y up, in units of [w] (logo.dart draws the same shapes).
  NSGraphicsContext.saveGraphicsState()
  let tilt = NSAffineTransform()
  tilt.translateX(by: p(0.5, 0.64).x, yBy: p(0.5, 0.64).y)
  tilt.rotate(byDegrees: -10)
  tilt.concat()
  let phone = NSBezierPath(
    roundedRect: NSRect(x: -0.15 * w, y: -0.26 * w, width: 0.30 * w, height: 0.50 * w), xRadius: 0.056 * w,
    yRadius: 0.056 * w)
  NSColor(red: 0.055, green: 0.063, blue: 0.094, alpha: 1).setFill()
  phone.fill()
  phone.lineWidth = (small ? 0.03 : 0.018) * w
  NSColor(red: 0.91, green: 0.914, blue: 0.933, alpha: 1).setStroke()
  phone.stroke()
  // The prompt: ">_" in the stitching's yellow.
  let yellow = NSColor(red: 1, green: 0.82, blue: 0.36, alpha: 1)
  let chevron = NSBezierPath()
  chevron.move(to: NSPoint(x: -0.085 * w, y: 0.14 * w))
  chevron.line(to: NSPoint(x: -0.019 * w, y: 0.0896 * w))
  chevron.line(to: NSPoint(x: -0.085 * w, y: 0.0392 * w))
  chevron.lineWidth = (small ? 0.05 : 0.034) * w
  chevron.lineCapStyle = .round
  chevron.lineJoinStyle = .round
  yellow.setStroke()
  chevron.stroke()
  yellow.setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 0.01 * w, y: 0.028 * w, width: 0.08 * w, height: 0.032 * w), xRadius: 0.016 * w,
    yRadius: 0.016 * w
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
  NSGradient(
    starting: NSColor(red: 0.55, green: 0.62, blue: 1.0, alpha: 1),
    ending: NSColor(red: 0.36, green: 0.42, blue: 0.86, alpha: 1)
  )!.draw(in: pocket, angle: -90)
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
  stitch.lineCapStyle = .round
  stitch.setLineDash([0.022 * w, 0.02 * w], count: 2, phase: 0)
  NSColor(red: 1, green: 0.82, blue: 0.36, alpha: 0.9).setStroke()
  stitch.stroke()
}

for dir in ["assets/icon", "../pocketterm-mobile/assets/icon"] {
  try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}
render(size: 1024, inset: 0, radius: 0, to: "../pocketterm-mobile/assets/icon/ios.png")
// Android: a 108 dp layer of which a 72 dp middle shows (less on round masks); the pocket
// at 0.72 stays clear of every mask.
render(size: 1024, inset: 0, radius: 0, art: false, to: "../pocketterm-mobile/assets/icon/android-background.png")
render(
  size: 1024, inset: 0, radius: 0, gradient: false, scale: 0.72, to: "../pocketterm-mobile/assets/icon/android-foreground.png")
// macOS: Big Sur grid, 824 pt body inside the 1024 canvas.
render(size: 1024, inset: 100, radius: 185, to: "assets/icon/macos.png")
// Windows: each size drawn on its own (the small art up to 24 px), packed by ImageMagick. The app
// icon (window, taskbar, installer) and the tray item, which Windows shows at 16-32 px.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm-icon").path
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
func ico(_ sizes: [Int], to path: String) {
  let pngs = sizes.map { n -> String in
    let png = "\(tmp)/\(n).png"
    render(size: CGFloat(n), inset: 0, radius: CGFloat(n) * 0.22, small: n <= 24, to: png)
    return png
  }
  let magick = Process()
  magick.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  magick.arguments = ["magick"] + pngs + [path]
  try! magick.run()
  magick.waitUntilExit()
  precondition(magick.terminationStatus == 0, "magick failed for \(path)")
}
ico([256, 128, 64, 48, 32, 24, 16], to: "windows/runner/resources/app_icon.ico")
ico([48, 32, 24, 20, 16], to: "assets/tray.ico")
print("ok")
