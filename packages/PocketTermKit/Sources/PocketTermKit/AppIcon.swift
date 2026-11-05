import Combine
import Foundation

/// The app icon that goes with [choice]: `default` (the bundle's own icon, Catppuccin Mocha's) for System and
/// Catppuccin, else `dawn` (Rosé Pine) or `tokyoNight`, the alternates the native sides know by these names
/// (apps/pocketterm-desktop/tool/make_icon.swift draws them all).
public func appIconFor(_ choice: ThemeChoice) -> String {
  switch choice {
  case .system, .catppuccin: "default"
  case .rosePine: "dawn"
  case .tokyoNight: "tokyoNight"
  }
}

/// Keeps the app icon on [appearance]'s choice: [apply] gets [appIconFor]'s name now and after each change
/// of choice, one call at a time in that order; a failure is only logged. Returns what stops it.
@MainActor
public func followAppIcon(
  _ appearance: Appearance, _ apply: @escaping @MainActor (String) async throws -> Void
) -> @MainActor () -> Void {
  var shown: String?
  var last: Task<Void, Never>?
  // `$choice` gives the current choice at once, then each new one.
  let subscription = appearance.$choice.sink { choice in
    let icon = appIconFor(choice)
    if icon == shown { return }
    shown = icon
    let previous = last
    last = Task { @MainActor in
      await previous?.value
      do {
        try await apply(icon)
      } catch {
        debugLog("PocketTerm: app icon \(icon): \(error)")
      }
    }
  }
  return { subscription.cancel() }
}
