#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals

/// What a terminal's fix (`fixTerminal`) tells the person next, and whether it failed (its button stays to try
/// again).
public struct TerminalFixResult: Equatable, Sendable {
  public var note: String
  public var failed: Bool
  public init(note: String, failed: Bool) {
    self.note = note
    self.failed = failed
  }
}

/// System Settings → Privacy & Security → Automation.
public let automationSettingsUrl = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

/// Opens `url` as `/usr/bin/open` does.
public func openUrl(_ url: String) async {
  _ = try? await runProcess("/usr/bin/open", [url])
}

/// A Mac terminal's one-click fix (`TermStatus.fix`), as Settings and the setup checklist offer it: kitty's lines
/// added to kitty.conf, or System Settings opened where Automation is allowed. `open`: how a URL is opened (tests
/// pass their own). WezTerm's install is the Windows app's.
public func fixTerminal(
  _ terminals: Terminals, _ s: TermStatus, open: @Sendable (String) async -> Void = openUrl
) async -> TerminalFixResult {
  switch s.fix {
  case .kittyConfig:
    do {
      try terminals.kitty?.configure()
      return TerminalFixResult(
        note: "Added to kitty.conf (the old one is kitty.conf.pocketterm-backup). "
          + "Quit and reopen kitty to let PocketTerm in.",
        failed: false)
    } catch {
      return TerminalFixResult(note: "Couldn't change kitty.conf: \(error)", failed: true)
    }
  case .automation:
    await open(automationSettingsUrl)
    return TerminalFixResult(note: "Turn on \(s.label) under PocketTerm, then come back here.", failed: false)
  case .install, nil:
    return TerminalFixResult(note: "", failed: false)
  }
}

/// The terminals the phone can't reach until the person acts: one that needs setup or a permission, one to install.
public func terminalsNeedingSetup(_ statuses: [TermStatus]) -> [TermStatus] {
  statuses.filter { $0.state == .setup || ($0.fix == .install && $0.state == .missing) }
}

/// No terminal app the phone could use is installed (tmux alone isn't one); one to install counts,
/// `terminalsNeedingSetup` has it.
public func noTerminalApp(_ statuses: [TermStatus]) -> Bool {
  !statuses.contains { $0.id != "tmux" && ($0.state != .missing || $0.fix == .install) }
}
#endif
