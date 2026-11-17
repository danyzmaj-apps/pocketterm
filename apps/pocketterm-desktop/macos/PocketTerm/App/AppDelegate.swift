import AppKit
import PocketTermDesktop

/// A menu-bar app with a window: no Dock icon or menu bar until the window opens (MacHost switches the activation
/// policy), never quits when the window closes, and cleans up before it quits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var model: AppModel!
  private var quitting = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    // A test build's screenshots in light and dark, whatever this Mac uses (the UI tests).
    switch testHooks()["POCKETTERM_APPEARANCE"] {
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    default: break
    }
    model = AppModel()
    NSApp.mainMenu = MainMenu.make(model)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    model.launch()
  }

  // pocketterm://setup?… (a setup link), a phone's code opened on this Mac.
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { model.open(url) }
  }

  // Closing the window never quits; PocketTerm stays in the menu bar.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  // Quit (the menus, ⌘Q, logging out): the local API leaves cli.json and the built-in server stops first (a
  // second at most), then the app goes.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting { return .terminateLater }
    quitting = true
    Task {
      await model.host.quitting()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  // The Dock icon clicked (or the LaunchServices activation MacHost asks for): the window back, unless one shows.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if model.windows.visibleWindow == nil && !model.desk.isVisible { model.openMain() }
    return true
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    if model.windows.visibleWindow == nil, let desk = model.desk.nsWindow {
      desk.makeKeyAndOrderFront(nil)
    } else {
      model.windows.becameActive()
    }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// The menu bar while a window is open: the app menu (About, Check for Updates…, Settings… ⌘,, Quit ⌘Q), File (new
/// terminals, Close Window ⌘W), Edit (for the text fields: paste a setup link), Desk (moving around it) and Window.
///
/// Desk's keys are ⌘ ones only (a terminal never gets ⌘, so none is taken from the programs in it), few, and those
/// Mac apps use for the same: ⌘K go to anything, ⌘J the next terminal waiting for you, ⌘1…⌘9 a terminal of the
/// project, ⌘⇧[ ⌘⇧] the one before or after, ⌘T ⌘⇧T a new terminal or agent, ⌘⇧W end one, ⌘⇧↩ zoom.
@MainActor
enum MainMenu {
  static func make(_ model: AppModel) -> NSMenu {
    let main = NSMenu()

    let app = NSMenu(title: "PocketTerm")
    app.addItem(
      withTitle: "About PocketTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    app.addItem(model.updater.menuItem())
    app.addItem(.separator())
    let settings = Target { model.openSettings() }
    app.addItem(item("Settings…", ",", settings))
    app.addItem(.separator())
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.submenu = NSMenu(title: "Services")
    NSApp.servicesMenu = services.submenu
    app.addItem(services)
    app.addItem(.separator())
    app.addItem(withTitle: "Hide PocketTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let others = app.addItem(
      withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    others.keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit PocketTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    add(app, to: main)

    let file = NSMenu(title: "File")
    file.addItem(desk("New Terminal", "t") { $0.new() })
    file.addItem(desk("New Agent Session", "t", [.command, .shift]) { $0.new(agent: $0.defaultAgent) })
    file.addItem(desk("Open Project…", "o") { $0.chooseProject() })
    file.addItem(.separator())
    file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    file.addItem(desk("End Terminal", "w", [.command, .shift]) { $0.endFocused() })
    add(file, to: main)

    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    add(edit, to: main)

    let go = NSMenu(title: "Desk")
    let open = Target { model.openDesk() }
    targets.append(open)
    go.addItem(item("Open Desk", "", open))
    go.addItem(.separator())
    go.addItem(desk("Go to…", "k") { $0.paletteShown.toggle() })
    go.addItem(desk("Next Waiting for You", "j") { $0.nextWaiting() })
    go.addItem(.separator())
    go.addItem(desk("Next Terminal", "]", [.command, .shift]) { $0.cycle(1) })
    go.addItem(desk("Previous Terminal", "[", [.command, .shift]) { $0.cycle(-1) })
    let numbers = NSMenu(title: "Terminal")
    for n in 1...9 { numbers.addItem(desk("Terminal \(n)", "\(n)") { $0.focus(number: n) }) }
    let numbered = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
    numbered.submenu = numbers
    go.addItem(numbered)
    go.addItem(.separator())
    let layouts = NSMenu(title: "Layout")
    for l in DeskLayout.allCases { layouts.addItem(desk(l.label, "") { $0.setLayout(l) }) }
    let layout = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
    layout.submenu = layouts
    go.addItem(layout)
    go.addItem(desk("Zoom Terminal", "\r", [.command, .shift]) { $0.toggleZoom() })
    go.addItem(.separator())
    go.addItem(desk("Toggle Sidebar", "s", [.command, .control]) { $0.sidebarShown.toggle() })
    go.addItem(desk("Toggle Project Details", "i", [.command, .option]) { $0.inspectorShown.toggle() })
    add(go, to: main)

    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(.separator())
    window.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    NSApp.windowsMenu = window
    add(window, to: main)

    targets.append(settings)
    return main
  }

  /// The closures' targets, kept alive with the menu.
  private static var targets: [Target] = []

  private static func add(_ menu: NSMenu, to main: NSMenu) {
    let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
    item.submenu = menu
    main.addItem(item)
  }

  private static func item(_ title: String, _ key: String, _ target: Target) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: key)
    item.target = target
    return item
  }

  /// A Desk menu item: opens Desk (when it isn't in front), then does `action` there.
  private static func desk(
    _ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, _ action: @escaping (DeskModel) -> Void
  ) -> NSMenuItem {
    let target = Target { AppModel.shared.openDesk(then: action) }
    targets.append(target)
    let i = item(title, key, target)
    i.keyEquivalentModifierMask = modifiers
    return i
  }
}

/// A menu item's action as a closure.
@MainActor
final class Target: NSObject {
  private let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func run() { action() }
}
