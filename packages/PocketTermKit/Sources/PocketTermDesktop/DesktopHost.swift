#if os(macOS)
import Foundation

/// What the computer's own side does for the app: the main window, the menu-bar item, launch at login, keeping the
/// computer awake. `MacHost` is the Mac's; the SwiftUI app hands it the window and Dock-icon parts as closures.
@MainActor
public protocol DesktopHost: AnyObject {
  /// Starts listening. `onEvent`: openMain (the menu-bar item, the Dock icon), openSettings (its Settings… item, ⌘,),
  /// mainClosed (the window was closed: hidden, the app keeps running) and quitting (the app is about to quit: it
  /// waits up to a second for what `onEvent` does).
  func start(onEvent: @escaping @MainActor (String) async -> Void) async

  func showMain() async
  func hideMain() async

  /// Quits the app, after quitting has run.
  func quit() async

  /// What this computer calls itself.
  func deviceName() async -> String

  /// Seconds since the last keyboard or mouse input.
  func idleSeconds() async -> Int

  func launchAtLogin() async -> Bool

  /// Throws when the system didn't make it so (a login item it wants the person to allow first), saying where to
  /// allow it.
  func setLaunchAtLogin(on: Bool) async throws

  /// A folder picker; the folders chosen, none if cancelled.
  func pickFolders() async -> [String]

  /// Keeps the computer from idle sleep while `on` (the lid or the power button still sleep it).
  func setKeepAwake(on: Bool) async

  /// Shows `icon` (PocketTermKit's appIconFor names; "default" for the app's own) as the app's Dock icon while it
  /// runs.
  func setAppIcon(_ icon: String) async
}
#endif
