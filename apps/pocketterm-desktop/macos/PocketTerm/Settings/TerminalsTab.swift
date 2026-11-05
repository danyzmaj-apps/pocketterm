import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals
import SwiftUI

/// Settings → Terminals: where new sessions open and how they're placed, then each terminal and its one-click
/// fix (Ghostty's with starting its new windows in tmux).
struct TerminalsTab: View {
  @EnvironmentObject private var app: AppController
  @EnvironmentObject private var status: StatusModel

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Picker(
          "New sessions open in", selection: Binding(get: { terminalAppValue }, set: { id in app.setTerminalApp(id) })
        ) {
          Text("Auto").tag("auto")
          ForEach(terminalApps, id: \.id) { h in Text(h.label).tag(h.id) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings-terminal-app")
        Text(opensInSub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        Picker("Place them", selection: Binding(get: { app.placement }, set: { p in app.setPlacement(p) })) {
          Text("Tab in the project’s window").tag(Placement.projectWindow)
          Text("New window").tag(Placement.newWindow)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings-placement")
        Text(placementSub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    Section {
      if let terminals = status.terminals {
        // Only tmux, and a terminal with an install fix, show while missing, with how to get it.
        ForEach(terminals.filter { $0.state != .missing || $0.id == "tmux" || $0.fix != nil }, id: \.id) { s in
          TerminalRow(s: s)
        }
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Looking for terminals…").foregroundStyle(.secondary)
        }
      }
    }
  }

  /// Auto, or one of the terminal apps found here (and the one chosen, should it be gone).
  private var terminalApps: [TerminalHost] {
    let chosen = app.terminalApp
    return app.terminals.apps.filter { h in
      h.id == chosen || (status.terminals?.contains { $0.id == h.id && $0.state != .missing } ?? false)
    }
  }

  private var terminalAppValue: String {
    let chosen = app.terminalApp
    return chosen == "auto" || terminalApps.contains { $0.id == chosen } ? chosen : "auto"
  }

  /// Where a session from the phone opens, and what tmux adds there.
  private var opensInSub: String {
    let chosen = app.terminals.apps.first { $0.id == app.terminalApp }
    let place = chosen.map { "Always \($0.label)" } ?? "Auto: the terminal app you used last"
    guard let tmux = status.terminals?.first(where: { $0.id == "tmux" }) else { return place }
    return tmux.state == .missing
      ? "\(place) · in Ghostty your phone can’t see the screen or answer: install tmux for full control"
      : "\(place) · in Ghostty they run in tmux, so your phone has full control"
  }

  private var placementSub: String {
    switch app.placement {
    case .projectWindow:
      "A new tab in the window that already has the project’s tabs; a new window when none does. "
        + "Sessions in your home folder (General) share a window too."
    case .newWindow: "A new window for every session."
    }
  }
}

/// A terminal: how it stands, and its one-click fix if it has one.
private struct TerminalRow: View {
  let s: TermStatus
  @EnvironmentObject private var app: AppController
  @EnvironmentObject private var status: StatusModel
  @State private var ghosttyError: String?

  var body: some View {
    let stateText =
      switch s.state {
      case .ready: "Ready"
      case .limited: "Limited"
      case .setup: "Needs setup"
      case .idle: "Not running"
      case .missing: "Not installed"
      }
    let note =
      status.fixed[s.id]?.note
      ?? (s.state == .missing || s.note.isEmpty || s.note == stateText
        ? (s.note.isEmpty ? stateText : s.note) : "\(stateText) · \(s.note)")
    let attention = s.state == .setup || (s.fix == .install && s.state == .missing)
    let kind: StatusKind =
      status.fixed[s.id]?.failed == true
      ? .error : attention || s.state == .limited ? .warn : s.state == .ready ? .ok : .info
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(s.label).fontWeight(.semibold)
          StatusText(kind, note).font(.callout)
        }
        Spacer(minLength: 8)
        if let fix = status.fixAction(s) {
          Button(fix.label) { fix.run() }
            .accessibilityIdentifier(fix.id)
        }
      }
      if s.id == "ghostty" && s.state != .missing { ghosttyTmux }
      InlineMessage(message: $ghosttyError, error: true)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-terminal-\(s.id)")
  }

  /// Ghostty's new windows in tmux with one click, where tmux is installed and the person's config sets no command
  /// of its own.
  @ViewBuilder private var ghosttyTmux: some View {
    let tmux = app.terminals.tmux?.installed ?? false
    if let command = status.ghosttyCommand {
      switch command.state {
      case .ours:
        note(
          status.ghosttyUpgraded
            ? "New Ghostty windows open in tmux with a title PocketTerm can match. Open new windows to use it."
            : "Open new Ghostty windows to get full control. Windows already open stay as they are.")
        Button("Remove") { setTmux(on: false) }
          .controlSize(.small)
          .accessibilityIdentifier("settings-ghostty-tmux")
      case .theirs where tmux:
        note(
          "Your Ghostty config already sets command = \(command.command), so PocketTerm leaves it alone. "
            + "Add tmux to that command yourself for full control.")
      case .none where tmux:
        note(ghosttyTmuxWhy)
        Button("Start new windows in tmux") { setTmux(on: true) }
          .controlSize(.small)
          .accessibilityIdentifier("settings-ghostty-tmux")
      default:
        EmptyView()
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }

  private func setTmux(on: Bool) {
    Task { ghosttyError = await status.ghosttyTmux(on: on) }
  }
}
