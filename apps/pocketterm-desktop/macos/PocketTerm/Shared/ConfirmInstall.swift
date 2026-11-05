import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// PocketTerm to go into `agent` (`update`: replacing an older copy there), waiting for the person's yes.
struct AgentInstallRequest: Identifiable {
  let agent: Agent
  let update: Bool
  var id: String { "\(agent.rawValue)-\(update)" }
}

/// What a confirm-install sheet says: `title`, why it's needed (`why`), what it changes (`what`, with `command`
/// shown as typed when there is one) and how to take it out again (`undo`).
struct InstallConfirmation: Identifiable {
  let title: String
  let why: String
  let what: String
  var command: String?
  var undo: String?
  var action = "Install"
  var id: String { title }
}

/// Asks before something is installed on this computer; `onYes` runs once the person pressed the action, nothing is
/// installed without it.
struct ConfirmInstallSheet: View {
  let confirmation: InstallConfirmation
  let onYes: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SheetLayout(title: confirmation.title, width: 460) {
      Text(confirmation.why).fixedSize(horizontal: false, vertical: true)
      Text(confirmation.what).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let command = confirmation.command {
        Text(command)
          .font(commandFont)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
      }
      if let undo = confirmation.undo {
        Text(undo).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    } buttons: {
      Button("Not now", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
      Button(confirmation.action) {
        dismiss()
        onYes()
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("confirm-install-go")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("confirm-install")
  }
}

/// The confirmation for PocketTerm going into `agent` (`update`: replacing an older copy there), with where
/// `integrations` puts it shown below `home` as `~`.
func agentInstallConfirmation(
  _ agent: Agent, _ integrations: Integrations, home: String, update: Bool = false
) -> InstallConfirmation {
  let name = Integrations.name(agent)
  func tilde(_ dir: String) -> String {
    dir.hasPrefix(home + "/") ? "~/" + dir.dropFirst(home.count + 1) : dir
  }
  let verb = update ? "Update" : "Install"
  let ompDirs = agent == .omp ? integrations.ompDirs : []
  let why =
    update
    ? "The copy of PocketTerm in \(name) is older than this app. Updating it keeps your phone working with "
      + "your \(name) sessions."
    : "So your phone sees your \(name) sessions as conversations, not just their screen: read the replies, "
      + "answer questions and approvals, and get a notification when a run finishes. Without it, \(name) "
      + "windows show on your phone only as a screen."
  let what: String
  let command: String?
  let undo: String
  switch agent {
  case .omp:
    what =
      "\(update ? "Replaces" : "Copies") PocketTerm\u{2019}s omp extension (pocketterm-live.ts) "
      + "\(update ? "in" : "into") \(ompDirs.map(tilde).joined(separator: " and ")). Open omp sessions load it once "
      + "you restart them with \(agent.resume)."
    command = nil
    undo = "To take it out later, delete pocketterm-live.ts from \(ompDirs.count > 1 ? "those folders" : "that folder")."
  case .claude:
    what =
      "\(update ? "Replaces" : "Copies") PocketTerm\u{2019}s Claude Code plugin "
      + "\(update ? "in" : "to") \(tilde(integrations.claudeDir)) and has Claude Code "
      + "\(update ? "update" : "install") it. Open Claude Code sessions load it when you type \(agent.pickUp)."
    command =
      update
      ? "claude plugin marketplace update pocketterm\nclaude plugin update pocketterm@pocketterm"
      : "claude plugin marketplace add \(tilde(integrations.claudeDir))\nclaude plugin install pocketterm@pocketterm"
    undo = "To take it out later, run claude plugin uninstall pocketterm@pocketterm."
  }
  return InstallConfirmation(
    title: "\(verb) PocketTerm in \(name)?", why: why, what: what, command: command, undo: undo, action: verb)
}

private struct ConfirmAgentInstall: ViewModifier {
  @EnvironmentObject var app: AppController
  @Binding var request: AgentInstallRequest?
  let onConfirm: (Agent) -> Void

  func body(content: Content) -> some View {
    content.sheet(item: $request) { r in
      ConfirmInstallSheet(
        confirmation: agentInstallConfirmation(r.agent, app.integrations, home: app.terminals.home, update: r.update)
      ) { onConfirm(r.agent) }
    }
  }
}

extension View {
  /// Asks before PocketTerm goes into an agent (`request` set shows it); `onConfirm` hears the agent once the person
  /// said yes, and nothing happens otherwise.
  func confirmAgentInstall(
    _ request: Binding<AgentInstallRequest?>, onConfirm: @escaping (Agent) -> Void
  ) -> some View {
    modifier(ConfirmAgentInstall(request: request, onConfirm: onConfirm))
  }

  /// Asks before something else is installed (`confirmation` set shows it); `onConfirm` runs on yes.
  func confirmInstall(
    _ confirmation: Binding<InstallConfirmation?>, onConfirm: @escaping (InstallConfirmation) -> Void
  ) -> some View {
    sheet(item: confirmation) { c in ConfirmInstallSheet(confirmation: c) { onConfirm(c) } }
  }
}
