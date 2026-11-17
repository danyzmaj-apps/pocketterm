import AppKit
import PocketTermDesktop
import SwiftUI

/// Desk's window, beside the main one: made the first time it opens, hidden (not closed) by ⌘W and the red
/// button. Its terminals keep running in tmux either way.
@MainActor
final class DeskWindow: NSObject, NSWindowDelegate {
  private weak var appModel: AppModel?
  private(set) var model: DeskModel?
  private var window: NSWindow?

  var isVisible: Bool { window?.isVisible ?? false }
  var nsWindow: NSWindow? { isVisible ? window : nil }

  func attach(_ appModel: AppModel) {
    self.appModel = appModel
  }

  /// Opens Desk (front, key), then `then` with its model: what Desk's menu items do from anywhere.
  func show(then: ((DeskModel) -> Void)? = nil) {
    guard let appModel else { return }
    let w = make(appModel)
    appModel.host.showOther { w.makeKeyAndOrderFront(nil) }
    model?.visible = true
    if let model {
      then?(model)
      model.takeKeyboard()
    }
  }

  private func make(_ appModel: AppModel) -> NSWindow {
    if let window { return window }
    let model = DeskModel(app: appModel.app, prefs: appModel.prefs)
    self.model = model
    let host = NSHostingController(rootView: DeskView(model: model).appEnvironment(appModel))
    host.sizingOptions = []
    let w = NSWindow(contentViewController: host)
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    w.title = "Desk (Beta)"
    w.minSize = NSSize(width: 760, height: 440)
    let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let width = min(1360, visible.width - 60), height = min(860, visible.height - 60)
    w.setFrame(
      NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: false)
    if appModel.windows.remembersFrames { w.setFrameAutosaveName("PocketTermDesk") }
    w.isReleasedWhenClosed = false
    w.identifier = NSUserInterfaceItemIdentifier("pocketterm-desk-window")
    w.tabbingMode = .disallowed
    w.delegate = self
    window = w
    return w
  }

  // ⌘W / the red button: hidden; the terminals keep running, and the Dock icon goes unless another window shows.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    model?.visible = false
    model?.windowKey = false
    appModel?.host.toMenuBar()
    return false
  }

  func windowDidBecomeKey(_ notification: Notification) { model?.windowKey = true }
  func windowDidResignKey(_ notification: Notification) { model?.windowKey = false }

  func windowDidMiniaturize(_ notification: Notification) { model?.visible = false }
  func windowDidDeminiaturize(_ notification: Notification) { model?.visible = true }
}
