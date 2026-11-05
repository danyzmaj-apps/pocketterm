import UIKit

/// The home screen icon per theme (PocketTermKit's appIconFor): the asset catalog's alternate icons,
/// AppIcon-<Theme> (ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES in project.yml, drawn by
/// apps/pocketterm-desktop/tool/make_icon.swift), or the app's own, Catppuccin Mocha's, for "default" (System and
/// Catppuccin). iOS confirms every change with an alert of its own, so the icon showing already isn't set again,
/// and it only takes the change from an active app: one asked for before that waits for it.
///
/// 0.1.7's AppIcon-Gruvbox stays in the bundle (an update can't install while the showing icon is missing), now
/// with the app's own picture; Gruvbox is gone and its kept choice reads as Catppuccin, so at launch [set] gets
/// "default" and moves a phone still showing AppIcon-Gruvbox to the app's own icon.
enum AppIcons {
  /// 0.1.2's Mocha alternate, now the app's own icon: still set on a phone that had picked it, and the same
  /// picture, so it counts as the app's own rather than costing an alert to clear. The bundle must keep it
  /// (AppIcon-Mocha.appiconset): 0.1.3 build 260 dropped it, and that update failed to install on such phones.
  private static let retired: Set<String> = ["AppIcon-Mocha"]

  /// The alternate icon's name for [icon] (appIconFor's: `default`, `dawn`, `tokyoNight`).
  static func alternateName(_ icon: String) -> String? {
    icon == "default" ? nil : "AppIcon-" + icon.prefix(1).uppercased() + icon.dropFirst()
  }

  static func set(_ icon: String) async throws {
    let app = UIApplication.shared
    let name = alternateName(icon)
    let showing = app.alternateIconName.flatMap { retired.contains($0) ? nil : $0 }
    guard app.supportsAlternateIcons, showing != name else { return }
    if app.applicationState != .active {
      for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
        break
      }
      return try await set(icon)
    }
    try await app.setAlternateIconName(name)
  }
}

/// Keeps the screen on while a terminal's screen shows.
enum KeepAwake {
  static func set(_ on: Bool) { UIApplication.shared.isIdleTimerDisabled = on }
}
