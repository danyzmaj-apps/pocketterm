import Cocoa
import FlutterMacOS
import ServiceManagement
import Sparkle

/// The main window, from MainMenu.xib: a regular window, so it behaves like
/// any app's — while it's open PocketTerm has a Dock icon and its menu bar, ⌘W
/// closes it, ⌘Q quits. Closed, PocketTerm goes back to living in the menu bar.
class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var channel: FlutterMethodChannel!
  private var statusItem: NSStatusItem?

  override func awakeFromNib() {
    // Runs before any window shows: PocketTerm starts in the menu bar, and Dart
    // (the local API, the terminal bridge) works whether the window is open or not.
    let engine = FlutterEngine(name: "pocketterm", project: nil, allowHeadlessExecution: true)
    RegisterGeneratedPlugins(registry: engine)
    channel = FlutterMethodChannel(name: "pocketterm/native", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    engine.run(withEntrypoint: nil)
    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    controller.backgroundColor = NSColor(red: 0.09, green: 0.094, blue: 0.114, alpha: 1)

    contentViewController = controller
    styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    minSize = NSSize(width: 480, height: 360)
    let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    // Settings' two columns of cards fit; the checklist and the setup scroll in it.
    let w = min(760, visible.width - 80), h = min(600, visible.height - 80)
    setFrame(NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h), display: false)
    setFrameAutosaveName("PocketTermMain")  // remembers where you put it
    isReleasedWhenClosed = false
    delegate = self

    setupStatusItem()
    // A throwaway profile (tool/smoke) is driven through accessibility: turn
    // Flutter's tree on as VoiceOver would, once the view is in the window.
    if !(ProcessInfo.processInfo.environment["POCKETTERM_PROFILE"] ?? "").isEmpty {
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: NSNotification.Name("NSApplicationDidChangeAccessibilityEnhancedUserInterfaceNotification"),
          object: NSApp, userInfo: ["AXEnhancedUserInterface": true])
      }
    }
    super.awakeFromNib()
  }

  // MARK: - Dart → native

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "showMain":
      showMain()
      result(nil)
    case "hideMain":
      hideMain()
      result(nil)
    case "deviceName":
      result(Host.current().localizedName ?? "Mac")
    case "launchAtLogin":
      result(SMAppService.mainApp.status == .enabled)
    case "setLaunchAtLogin":
      do {
        if args["enabled"] as? Bool == true {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
        if args["enabled"] as? Bool == true && SMAppService.mainApp.status == .requiresApproval {
          // Registered, but macOS waits for the person to allow it.
          result(FlutterError(
            code: "launch_at_login",
            message: "Allow PocketTerm in System Settings > General > Login Items.",
            details: nil))
          return
        }
        result(SMAppService.mainApp.status == .enabled)
      } catch {
        result(FlutterError(code: "launch_at_login", message: error.localizedDescription, details: nil))
      }
    case "startDrag":
      if let event = NSApp.currentEvent, let window = event.window { window.performDrag(with: event) }
      result(nil)
    case "idleSeconds":
      result(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!))
    case "quit":
      NSApp.terminate(nil)
      result(nil)
    case "pickFolders":
      // Settings → Project folders → Add folder…; a sheet on this (the main) window.
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = true
      panel.canCreateDirectories = true
      panel.message = "Folders that hold your projects"
      panel.prompt = "Add"
      panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
      panel.beginSheetModal(for: self) { response in
        result(response == .OK ? panel.urls.map { $0.path } : [])
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// PocketTerm is quitting: Dart takes its address out of cli.json (lib/local_api.dart)
  /// so the terminal's integrations stop calling a port nobody owns now.
  /// [done] runs once Dart has, or after a second at most.
  func quitting(_ done: @escaping () -> Void) {
    var finished = false
    let finish = {
      if finished { return }
      finished = true
      done()
    }
    channel.invokeMethod("quitting", arguments: nil) { _ in finish() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: finish)
  }

  private func showMain() {
    // A real app while the window is open: Dock icon, menu bar, ⌘-Tab.
    NSApp.setActivationPolicy(.regular)
    makeKeyAndOrderFront(nil)
    activate()
  }

  /// Back to the menu bar: no Dock icon, no menu bar of its own.
  private func hideMain() {
    orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  /// Makes PocketTerm the active app, so the menu bar, ⌘W and ⌘Q are PocketTerm's.
  ///
  /// Since macOS 14 `NSApp.activate()` is only a request, and macOS turns it
  /// down when the user's last input went to another app (a click on the
  /// menu bar item doesn't count). Opening the app through LaunchServices
  /// (what the Dock and `open -a` do) is always honoured, so that's the
  /// fallback.
  private func activate() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      guard !NSApp.isActive else { return }
      let config = NSWorkspace.OpenConfiguration()
      config.activates = true
      NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }
  }

  /// Once PocketTerm really is active, the main window (if open) takes the keyboard.
  func becameActive() {
    if isVisible { makeKeyAndOrderFront(nil) }
  }

  /// App menu → Preferences… (⌘,).
  @objc func openSettingsFromMenu() {
    channel.invokeMethod("openSettings", arguments: nil)
  }

  /// Dock icon clicked while PocketTerm runs (AppDelegate).
  func reopen() {
    channel.invokeMethod("openMain", arguments: nil)
  }

  // MARK: - Window events → Dart

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // ⌘W / the red button: hide (the window is reused), back to the menu bar.
    hideMain()
    channel.invokeMethod("mainClosed", arguments: nil)
    return false
  }

  /// ⌘W hides the main window like in any Mac app. Caught here, before the
  /// Flutter view: a focused text field otherwise keeps the keystroke and it
  /// never reaches the File menu.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  // MARK: - Menu bar icon

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      button.image = Self.pocketIcon()
      button.target = self
      button.action = #selector(statusClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    statusItem = item
  }

  /// The menu bar mark: the app icon's pocket with a phone showing a ">_"
  /// prompt tucked in, drawn as a template so macOS tints it for light and dark menu bars.
  private static func pocketIcon() -> NSImage {
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

  @objc private func statusClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      let menu = NSMenu()
      menu.addItem(withTitle: "Open PocketTerm", action: #selector(menuMain), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "").target = self
      menu.addItem(
        withTitle: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
      ).target = AppDelegate.updater
      menu.addItem(.separator())
      menu.addItem(withTitle: "Quit PocketTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
      statusItem?.menu = menu
      statusItem?.button?.performClick(nil)
      statusItem?.menu = nil
    } else {
      channel.invokeMethod("openMain", arguments: nil)
    }
  }

  @objc private func menuMain() { channel.invokeMethod("openMain", arguments: nil) }
  @objc private func menuSettings() { channel.invokeMethod("openSettings", arguments: nil) }
}
