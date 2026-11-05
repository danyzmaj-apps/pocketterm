import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// Settings → Coding agents: PocketTerm in each agent (Install / Update), the default one, and the sessions
/// opened before PocketTerm was in them.
struct AgentsTab: View {
  var body: some View {
    Section {
      ForEach(Agent.allCases, id: \.self) { agent in AgentRow(agent: agent) }
    } footer: {
      Text(
        "The default agent is what a new session from your phone starts. PocketTerm talks to your phone "
          + "through a small add-on inside each agent."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct AgentRow: View {
  let agent: Agent
  @EnvironmentObject private var app: AppController
  @EnvironmentObject private var status: StatusModel
  @State private var showSessions = false

  var body: some View {
    let check = app.agents?[agent]
    let missing = app.agents != nil && check == nil
    let isDefault = agent == app.codingAgent
    let state = self.state(check)
    let sessions = status.unreported.filter { $0.agent == agent }
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(Integrations.name(agent)).fontWeight(.semibold)
          StatusText(state.kind, state.text).font(.callout)
        }
        Spacer(minLength: 8)
        if let action = action(check) {
          Button(action.label) { action.run() }
            .buttonStyle(.borderedProminent)
            .disabled(status.installing.contains(agent))
            .accessibilityIdentifier(action.id)
        }
        if isDefault {
          Text("Default")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(.separator))
            .accessibilityIdentifier("settings-default-\(agent.name)")
        }
      }
      if agent == .omp && !app.ompProfiles.isEmpty {
        Text("Profiles: default, \(app.ompProfiles.joined(separator: ", "))")
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("settings-omp-profiles")
      }
      if !sessions.isEmpty {
        unreportedText(sessions)
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        Button(showSessions ? "Hide sessions" : "Show sessions") { showSessions.toggle() }
          .controlSize(.small)
          .accessibilityIdentifier("settings-show-sessions-\(agent.name)")
        if showSessions {
          ForEach(sessions, id: \.key) { w in
            SessionToPickUp(window: w, id: "settings-unreported-\(w.key)")
          }
        }
      }
      if !isDefault && !missing {
        Button("Make default") { app.setCodingAgent(agent) }
          .controlSize(.small)
          .accessibilityIdentifier("settings-make-default-\(agent.name)")
      }
    }
    .padding(.vertical, 2)
    .opacity(missing ? 0.6 : 1)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-agent-\(agent.name)")
  }

  /// Where PocketTerm in the agent stands.
  private func state(_ check: AgentCheck?) -> InstallNote {
    if let note = status.installNotes[agent] { return note }
    guard app.agents != nil else { return InstallNote(text: "Checking…", kind: .working) }
    guard let check else { return InstallNote(text: "Not found on this computer", kind: .info) }
    if let problem = check.state.problem { return InstallNote(text: problem, kind: .warn) }
    switch integrationOf(check) {
    case .installed: return InstallNote(text: "PocketTerm installed, up to date", kind: .ok)
    case .off: return InstallNote(text: Integrations.modsOffHint, kind: .warn)
    case .outdated: return InstallNote(text: "PocketTerm here is out of date", kind: .warn)
    case .missing: return InstallNote(text: "PocketTerm isn’t installed here yet", kind: .warn)
    }
  }

  /// Install or Update where PocketTerm can go in and isn't current; Installing… while it goes in.
  private func action(_ check: AgentCheck?) -> AttentionAction? {
    if status.installing.contains(agent) { return status.agentAction(agent, "") }
    guard let check, !check.state.current, check.state.problem == nil else { return nil }
    return status.agentAction(agent, check.state.installed ? "Update" : "Install")
  }

  /// "2 sessions opened before PocketTerm: reopen each with omp -c" / "…: type /reload-plugins in each".
  private func unreportedText(_ sessions: [TermWindow]) -> Text {
    let n = sessions.count
    let command = Text(StatusModel.pickUpOf(agent, sessions)).font(commandFont)
    switch agent {
    case .omp:
      return Text("\(StatusModel.count(n, "session")) opened before PocketTerm: reopen \(n == 1 ? "it" : "each") with ")
        + command
    case .claude:
      return Text("\(StatusModel.count(n, "session")) opened before PocketTerm: type ") + command
        + Text(" in \(n == 1 ? "it" : "each")")
    }
  }
}
