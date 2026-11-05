import AppKit
import SwiftUI

/// PocketTerm's menu-bar item: a click opens its panel (status, Terminal from phone, what needs attention, the
/// ways in); a right click (or ⌃-click) the short menu the Flutter app had.
@MainActor
final class StatusItem: NSObject, NSPopoverDelegate {
  private let model: AppModel
  private let item: NSStatusItem
  private let popover = NSPopover()

  init(model: AppModel) {
    self.model = model
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()
    if let button = item.button {
      button.image = Self.pocketIcon()
      button.target = self
      button.action = #selector(clicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.setAccessibilityIdentifier("menu-bar-item")
    }
    popover.behavior = .transient
    popover.animates = false
    popover.delegate = self
    popover.contentViewController = NSHostingController(
      rootView: MenuBarView(close: { [weak self] in self?.popover.performClose(nil) }).appEnvironment(model))
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      let menu = NSMenu()
      menu.addItem(withTitle: "Open PocketTerm", action: #selector(openMain), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
      menu.addItem(model.updater.menuItem())
      menu.addItem(.separator())
      menu.addItem(withTitle: "Quit PocketTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
      item.menu = menu
      item.button?.performClick(nil)
      item.menu = nil
      return
    }
    if popover.isShown {
      popover.performClose(nil)
    } else {
      // A fresh look at this computer each time it opens.
      Task { await model.status.check() }
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  @objc private func openMain() { model.openMain() }
  @objc private func openSettings() { model.openSettings() }

  /// The menu bar mark: the app icon's pocket with a phone showing a ">_" prompt tucked in, drawn as a template
  /// so macOS tints it for light and dark menu bars.
  static func pocketIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      // The phone, tilted right, behind the pocket: an outline with a ">_" prompt.
      NSGraphicsContext.saveGraphicsState()
      let tilt = NSAffineTransform()
      tilt.translateX(by: 9, yBy: 11.8)
      tilt.rotate(byDegrees: -10)
      tilt.concat()
      NSColor.black.set()
      let phone = NSBezierPath(roundedRect: NSRect(x: -3, y: -5, width: 6, height: 9), xRadius: 1.5, yRadius: 1.5)
      phone.lineWidth = 1.3
      phone.stroke()
      let prompt = NSBezierPath()
      prompt.move(to: NSPoint(x: -1.6, y: 2.2))
      prompt.line(to: NSPoint(x: -0.4, y: 1.4))
      prompt.line(to: NSPoint(x: -1.6, y: 0.6))
      prompt.move(to: NSPoint(x: 0.4, y: 0.6))
      prompt.line(to: NSPoint(x: 1.6, y: 0.6))
      prompt.lineWidth = 1
      prompt.lineCapStyle = .round
      prompt.lineJoinStyle = .round
      prompt.stroke()
      NSGraphicsContext.restoreGraphicsState()

      let pocket = NSBezierPath()
      pocket.move(to: NSPoint(x: 3, y: 8.6))
      pocket.line(to: NSPoint(x: 15, y: 8.6))
      pocket.line(to: NSPoint(x: 15, y: 4.2))
      pocket.line(to: NSPoint(x: 9, y: 0.9))
      pocket.line(to: NSPoint(x: 3, y: 4.2))
      pocket.close()
      pocket.lineJoinStyle = .round
      // Hollow pocket: clears the phone where the pocket covers it.
      NSGraphicsContext.current?.compositingOperation = .clear
      pocket.fill()
      NSGraphicsContext.current?.compositingOperation = .sourceOver
      pocket.lineWidth = 1.5
      pocket.stroke()
      let hem = NSBezierPath()
      hem.move(to: NSPoint(x: 4.5, y: 6.7))
      hem.line(to: NSPoint(x: 13.5, y: 6.7))
      hem.lineWidth = 1
      hem.setLineDash([1.4, 1.2], count: 2, phase: 0)
      hem.stroke()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "PocketTerm"
    return image
  }
}
