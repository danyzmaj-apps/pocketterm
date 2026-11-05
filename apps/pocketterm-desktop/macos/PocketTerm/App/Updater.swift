import Combine
import Sparkle
import SwiftUI

/// Sparkle, checking the GitHub releases' appcast (Info.plist SUFeedURL). Not in debug builds (they aren't signed
/// for updating) nor in test builds (a smoke copy must not replace itself).
@MainActor
final class Updater: ObservableObject {
  private let controller: SPUStandardUpdaterController
  private var watching: AnyCancellable?

  /// Whether Check for Updates… can run now (not while a check is on).
  @Published private(set) var canCheck = false

  init() {
    #if DEBUG || POCKETTERM_SMOKE
      let start = false
    #else
      let start = true
    #endif
    controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
    watching = controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
      .sink { [weak self] in self?.canCheck = $0 }
  }

  /// Whether the updater runs in this build.
  var active: Bool { controller.updater.sessionInProgress || canCheck }

  func checkForUpdates() { controller.checkForUpdates(nil) }

  /// The menus' item: Sparkle's own action, so it greys out while a check runs.
  func menuItem() -> NSMenuItem {
    let item = NSMenuItem(
      title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: "")
    item.target = controller
    return item
  }

  /// The version this is, as the About box has it.
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
  }
}
