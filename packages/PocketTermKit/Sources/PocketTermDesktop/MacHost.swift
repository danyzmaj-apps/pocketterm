#if os(macOS)
import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import PocketTermKit
import ServiceManagement

/// Where launch at login is kept: `SMAppService.mainApp`; tests pass their own.
public protocol LoginItem: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}

extension SMAppService: LoginItem {}

/// macOS didn't make launch at login so: `message` says where to change it.
public struct LaunchAtLoginError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
  public var errorDescription: String? { message }
}

/// The Mac's side: a menu-bar app with a main window, which has a Dock icon and a menu bar of its own only while
/// it's open. The SwiftUI app hands over its window (`showWindow`, `hideWindow`, `mainWindow`) and reports what
/// happens to it: `event` (openMain from the menu-bar item or the Dock icon, openSettings from ⌘,), `windowClosed`
/// and `quitting`.
@MainActor
public final class MacHost: DesktopHost {
  /// `showWindow` / `hideWindow`: bring the main window up (front, key) / take it away. `mainWindow`: the window a
  /// folder picker opens on as a sheet; a free-standing panel if nil. `iconDir`: where the themes' Dock icons are
  /// (`macos-<icon>.png`, apps/pocketterm-desktop/assets/icon/), the app's `Resources/icon` if nil. `loginItem`:
  /// `SMAppService.mainApp` if nil.
  public init(
    showWindow: @escaping @MainActor () -> Void,
    hideWindow: @escaping @MainActor () -> Void,
    mainWindow: @escaping @MainActor () -> NSWindow? = { nil },
    iconDir: String? = nil,
    loginItem: LoginItem? = nil
  ) {
    self.showWindow = showWindow
    self.hideWindow = hideWindow
    self.mainWindow = mainWindow
    self.iconDir = iconDir ?? Bundle.main.resourceURL?.appendingPathComponent("icon").path ?? "icon"
    self.loginItem = loginItem ?? SMAppService.mainApp
  }

  private let showWindow: @MainActor () -> Void
  private let hideWindow: @MainActor () -> Void
  private let mainWindow: @MainActor () -> NSWindow?
  private let iconDir: String
  private let loginItem: LoginItem
  private var onEvent: (@MainActor (String) async -> Void)?

  /// The theme's Dock icon (`setAppIcon`); nil: the app's own.
  private var appIcon: NSImage?

  /// The power assertion while kept awake.
  private(set) var awake: IOPMAssertionID?

  public func start(onEvent: @escaping @MainActor (String) async -> Void) async {
    self.onEvent = onEvent
  }

  /// The app tells what happened: openMain (the menu-bar item, the Dock icon clicked while PocketTerm runs),
  /// openSettings (Settings…, ⌘,).
  public func event(_ name: String) {
    guard let onEvent else { return }
    Task { await onEvent(name) }
  }

  /// The main window was closed (⌘W, the red button): back to the menu bar, PocketTerm keeps running.
  public func windowClosed() {
    NSApp.setActivationPolicy(.accessory)
    event("mainClosed")
  }

  /// PocketTerm is quitting (`applicationShouldTerminate`): the controller takes its address out of cli.json so
  /// the terminal's integrations stop calling a port nobody owns now. Returns once it has, or after `limit` at
  /// most.
  public func quitting(within limit: Duration = .seconds(1)) async {
    guard let onEvent else { return }
    _ = try? await firstOf(limit) { @MainActor in await onEvent("quitting") }
  }

  public func showMain() async {
    // A real app while the window is open: Dock icon, menu bar, ⌘-Tab.
    NSApp.setActivationPolicy(.regular)
    if let appIcon { NSApp.applicationIconImage = appIcon }
    showWindow()
    activate()
  }

  /// Back to the menu bar: no Dock icon, no menu bar of its own.
  public func hideMain() async {
    hideWindow()
    NSApp.setActivationPolicy(.accessory)
  }

  /// Makes PocketTerm the active app, so the menu bar, ⌘W and ⌘Q are PocketTerm's.
  ///
  /// Since macOS 14 `NSApp.activate()` is only a request, and macOS turns it down when the user's last input went
  /// to another app (a click on the menu bar item doesn't count). Opening the app through LaunchServices (what the
  /// Dock and `open -a` do) is always honoured, so that's the fallback.
  private func activate() {
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      MainActor.assumeIsolated {
        guard !NSApp.isActive else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
      }
    }
  }

  /// Quits the app; `applicationShouldTerminate` runs `quitting` first.
  public func quit() async {
    // From the run loop, not this main-queue job: terminate's modal wait for .terminateLater runs inside its
    // caller, and GCD never drains the main queue re-entrantly, so the reply (a main-actor Task) would never run.
    RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
  }

  public func deviceName() async -> String {
    await Task.detached { Host.current().localizedName ?? "Mac" }.value
  }

  public func idleSeconds() async -> Int {
    let any = CGEventType(rawValue: ~0)!
    return Int(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any).rounded(.down))
  }

  public func launchAtLogin() async -> Bool { loginItem.status == .enabled }

  /// What to do when macOS keeps PocketTerm out of the login items.
  public static let loginItemsHint = "Allow PocketTerm in System Settings > General > Login Items."

  /// What to do when macOS keeps PocketTerm in the login items after it was turned off.
  public static let stillStartsHint =
    "macOS still starts PocketTerm at login. Turn it off in System Settings > General > Login Items."

  /// Throws when the system didn't make it so (a login item it wants the person to allow first), saying where to
  /// allow it.
  public func setLaunchAtLogin(on: Bool) async throws {
    let now: Bool
    do {
      if on { try loginItem.register() } else { try loginItem.unregister() }
      // Registered, but macOS waits for the person to allow it.
      if on && loginItem.status == .requiresApproval { throw LaunchAtLoginError(Self.loginItemsHint) }
      now = loginItem.status == .enabled
    } catch let e as LaunchAtLoginError {
      throw e
    } catch {
      throw LaunchAtLoginError(error.localizedDescription)
    }
    if now != on { throw LaunchAtLoginError(on ? Self.loginItemsHint : Self.stillStartsHint) }
  }

  /// Settings → Project folders → Add folder…; a sheet on the main window.
  public func pickFolders() async -> [String] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = true
    panel.message = "Folders that hold your projects"
    panel.prompt = "Add"
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    let response: NSApplication.ModalResponse = await withCheckedContinuation { done in
      if let window = mainWindow() {
        panel.beginSheetModal(for: window) { done.resume(returning: $0) }
      } else {
        panel.begin { done.resume(returning: $0) }
      }
    }
    return response == .OK ? panel.urls.map(\.path) : []
  }

  /// Keeps the computer from idle sleep (as `caffeinate -i`); the assertion goes when PocketTerm does.
  public func setKeepAwake(on: Bool) async {
    if !on {
      if let awake { IOPMAssertionRelease(awake) }
      awake = nil
      return
    }
    if awake != nil { return }
    var id = IOPMAssertionID(0)
    let r = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "PocketTerm keeps this Mac awake for the phone" as CFString, &id)
    if r == kIOReturnSuccess {
      awake = id
    } else {
      debugLog("PocketTerm: keep awake: IOPMAssertionCreateWithName \(r)")
    }
  }

  /// The theme's Dock icon while the window is open; "default", the app's own (Finder and a quit app's Dock tile
  /// always show the bundle's).
  public func setAppIcon(_ icon: String) async {
    appIcon = icon == "default" ? nil : NSImage(contentsOfFile: "\(iconDir)/macos-\(icon).png")
    NSApp.applicationIconImage = appIcon
  }
}
#endif
