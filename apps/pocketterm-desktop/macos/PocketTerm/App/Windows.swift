import AppKit
import Combine
import PocketTermDesktop
import SwiftUI

/// Which window PocketTerm's "main window" is now: the setup window (first-run setup, sign-in, the setup
/// checklist) until this computer is signed in and ready, Settings after (lib/main_window.dart's routing).
enum WindowRoute: Equatable {
  case setup, settings

  static func of(backend: Bool, signedIn: Bool, getReadyDone: Bool) -> WindowRoute {
    backend && signedIn && getReadyDone ? .settings : .setup
  }
}

/// The two windows and which one shows: MacHost's showWindow / hideWindow. Closing either only hides it
/// (⌘W, the red button), and PocketTerm goes back to the menu bar.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
  private weak var model: AppModel?
  private var setupWindow: NSWindow?
  private var settingsWindow: NSWindow?
  private var tabs: SettingsTabsController?
  private var watching: Set<AnyCancellable> = []
  /// A window should be on screen (shown and not closed since).
  private var shown = false
  /// Windows keep their place in the standard defaults; a test build's throwaway profile leaves the person's alone.
  var remembersFrames = true
  private(set) var route = WindowRoute.setup

  func attach(_ model: AppModel) {
    self.model = model
    route = currentRoute()
    // Every change to the controller may move the window (signed in, the checklist done, signed out).
    model.app.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.follow() } }
    }.store(in: &watching)
  }

  private func currentRoute() -> WindowRoute {
    guard let app = model?.app else { return .setup }
    return WindowRoute.of(backend: app.backend != nil, signedIn: app.user != nil, getReadyDone: app.getReadyDone)
  }

  private func follow() {
    let next = currentRoute()
    guard next != route else { return }
    route = next
    model?.ui.objectWillChange.send()
    guard shown else { return }
    window(for: next == .setup ? .settings : .setup)?.orderOut(nil)
    present()
  }

  /// The window showing, for sheets and panels (the folder picker).
  var visibleWindow: NSWindow? {
    [setupWindow, settingsWindow].compactMap { $0 }.first { $0.isVisible }
  }

  func show() {
    shown = true
    present()
  }

  func hideAll() {
    shown = false
    setupWindow?.orderOut(nil)
    settingsWindow?.orderOut(nil)
  }

  /// PocketTerm became the active app: its window takes the keyboard.
  func becameActive() {
    if let w = visibleWindow { w.makeKeyAndOrderFront(nil) }
  }

  private func window(for route: WindowRoute) -> NSWindow? { route == .setup ? setupWindow : settingsWindow }

  private func present() {
    let w = route == .setup ? makeSetupWindow() : makeSettingsWindow()
    w.makeKeyAndOrderFront(nil)
  }

  private func makeSetupWindow() -> NSWindow {
    if let setupWindow { return setupWindow }
    let host = NSHostingController(rootView: MainWindowView().appEnvironment(model!))
    host.sizingOptions = []
    let w = NSWindow(contentViewController: host)
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.title = "PocketTerm"
    w.minSize = NSSize(width: 520, height: 420)
    let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    // The checklist and the setup scroll in it.
    let width = min(760, visible.width - 80), height = min(640, visible.height - 80)
    w.setFrame(
      NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: false)
    if remembersFrames { w.setFrameAutosaveName("PocketTermMain") }  // remembers where you put it
    w.isReleasedWhenClosed = false
    w.identifier = NSUserInterfaceItemIdentifier("pocketterm-setup-window")
    w.delegate = self
    setupWindow = w
    return w
  }

  private func makeSettingsWindow() -> NSWindow {
    if let settingsWindow { return settingsWindow }
    let tabs = SettingsTabsController(model: model!)
    let w = NSWindow(contentViewController: tabs)
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    w.toolbarStyle = .preference
    w.minSize = NSSize(width: 600, height: 420)
    w.setContentSize(NSSize(width: 680, height: 620))
    w.center()
    if remembersFrames { w.setFrameAutosaveName("PocketTermSettings") }
    w.isReleasedWhenClosed = false
    w.identifier = NSUserInterfaceItemIdentifier("pocketterm-settings-window")
    w.delegate = self
    self.tabs = tabs
    settingsWindow = w
    return w
  }

  // ⌘W / the red button: hide (the window is reused), back to the menu bar.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    shown = false
    model?.host.windowClosed()
    return false
  }
}

/// Settings: a toolbar of tabs (Phone, Coding agents, Terminals, Account) as in every Mac app's Settings, each a
/// grouped form. A tab with something that needs attention carries a dot on its icon.
@MainActor
final class SettingsTabsController: NSTabViewController {
  private let model: AppModel
  private var watching: Set<AnyCancellable> = []

  init(model: AppModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
    tabStyle = .toolbar
    transitionOptions = []
    for tab in SettingsTab.allCases {
      let host = NSHostingController(rootView: SettingsTabView(tab: tab).appEnvironment(model))
      host.sizingOptions = []
      // The window takes the selected tab's title, as Settings windows do.
      host.title = tab.label
      let item = NSTabViewItem(viewController: host)
      item.label = tab.label
      item.identifier = tab.rawValue
      item.image = Self.icon(tab, dot: false)
      addTabViewItem(item)
    }
    selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: model.ui.settingsTab) ?? 0
    model.ui.$settingsTab.removeDuplicates().sink { [weak self] tab in
      guard let self, let i = SettingsTab.allCases.firstIndex(of: tab), i != self.selectedTabViewItemIndex else {
        return
      }
      self.selectedTabViewItemIndex = i
    }.store(in: &watching)
    model.status.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.markTabs() } }
    }.store(in: &watching)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
    super.tabView(tabView, didSelect: item)
    if let id = item?.identifier as? String, let tab = SettingsTab(rawValue: id), model.ui.settingsTab != tab {
      model.ui.settingsTab = tab
    }
  }

  override func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = super.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: flag)
    if let tab = tabViewItems.first(where: { NSToolbarItem.Identifier(($0.identifier as? String) ?? "") == id })
      .flatMap({ ($0.identifier as? String).flatMap(SettingsTab.init(rawValue:)) })
    {
      item?.view?.setAccessibilityIdentifier("settings-tab-\(tab.rawValue)")
    }
    return item
  }

  /// A dot on the tabs whose things need attention (the Flutter tabs' `settings-tab-dot-<name>`).
  private func markTabs() {
    let attention = Set(model.status.items.map(\.tab))
    for item in tabViewItems {
      guard let tab = (item.identifier as? String).flatMap(SettingsTab.init(rawValue:)) else { continue }
      item.image = Self.icon(tab, dot: attention.contains(tab))
      item.toolTip = attention.contains(tab) ? "Needs attention" : nil
    }
  }

  private static func icon(_ tab: SettingsTab, dot: Bool) -> NSImage? {
    guard let symbol = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label) else { return nil }
    guard dot else { return symbol }
    let size = NSSize(width: max(symbol.size.width, 20), height: max(symbol.size.height, 20))
    let image = NSImage(size: size, flipped: false) { rect in
      // The symbol in the label color, then a red dot over its top right corner.
      let tinted = symbol.copy() as! NSImage
      tinted.isTemplate = true
      NSColor.labelColor.set()
      tinted.draw(
        in: NSRect(
          x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
          width: symbol.size.width, height: symbol.size.height))
      rect.fill(using: .sourceIn)
      NSColor.systemRed.setFill()
      NSBezierPath(ovalIn: NSRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 7, height: 7)).fill()
      return true
    }
    image.accessibilityDescription = "\(tab.label), needs attention"
    return image
  }
}
