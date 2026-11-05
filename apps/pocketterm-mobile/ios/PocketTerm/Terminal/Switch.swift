import PocketTermKit
import SwiftUI

/// Whether [w] is a coding agent's window that shows only as a screen and the phone can switch it to the
/// conversation view: no live session claims it, PocketTerm is installed in its agent on the computer (so a
/// restarted or reloaded agent reports), and its terminal presses keys and types.
func canSwitch(_ remote: TerminalRemote, _ w: TermWindow) -> Bool {
  switchable(w, agents: remote.agents, sessions: remote.sessions)
}

/// [canSwitch] on the computer's [agents] and live [sessions].
func switchable(_ w: TermWindow, agents: [Agent: AgentIntegration], sessions: [LiveSummary]) -> Bool {
  guard let agent = w.agent else { return false }
  return agents[agent] == .installed && w.can(.keys) && w.can(.type) && !sessions.contains { $0.window == w.key }
}

/// How long the phone waits for the switched agent to report as a session.
let switchWait: Duration = .seconds(25)

/// An agent the switch sheet asks about.
private struct SwitchOffer: Identifiable {
  let agent: Agent
  var id: String { agent.rawValue }
}

/// The top of a screen-only agent window's page ([canSwitch]): a banner offering the switch to the conversation
/// view, then "Switching…" until the agent reports as a live session in this window, whose page then replaces this
/// one; or, after [switchWait], that it didn't come back.
struct SwitchBanner: View {
  @ObservedObject var home: HomeModel
  @ObservedObject var remote: TerminalRemote
  let window: String

  private enum Phase { case idle, switching, failed }

  @State private var phase = Phase.idle

  /// The agent being switched: its window's program is a shell for a moment while omp restarts.
  @State private var agent = Agent.omp

  /// What its session page does about a run the switch stopped.
  @State private var after = AfterSwitch.nothing
  @State private var offer: SwitchOffer?
  @State private var timeout: Task<Void, Never>?

  var body: some View {
    let w = remote.window(window)
    let online = remote.online
    Group {
      switch phase {
      case .idle:
        if let w, let a = w.agent, canSwitch(remote, w) {
          bar("switch-offer", "This \(a.labelIn(w.profile)) session shows only its screen") {
            Button("Switch to conversation") { offer = SwitchOffer(agent: a) }
              .font(.subheadline.weight(.semibold))
              .disabled(!online)
              .accessibilityIdentifier("switch-open")
              .appTip(.switchButton)
          }
        }
      case .switching:
        bar("switching", "Switching…") { ProgressView().controlSize(.small) }
      case .failed:
        bar("switch-failed", "It didn\u{2019}t come back as a conversation.") {
          Button("Try again") { offer = SwitchOffer(agent: agent) }
            .font(.subheadline.weight(.semibold))
            .disabled(!online)
            .accessibilityIdentifier("switch-retry")
        }
      }
    }
    .animation(.snappy, value: phase)
    .sheet(item: $offer) { o in
      SwitchSheet(remote: remote, window: window, agent: o.agent) { picked in
        offer = nil
        if let picked { start(o.agent, picked) }
      }
      .presentationDetents([.medium, .large])
      .toasts()
    }
    .onChange(of: remote.sessions) { _, _ in check() }
    .onDisappear { stop() }
  }

  private func bar(_ id: String, _ text: String, @ViewBuilder action: () -> some View) -> some View {
    // Narrow (large text): the text wraps rather than pushing the action off.
    HStack(spacing: 12) {
      Text(text)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      action()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id)
    .transition(.move(edge: .top).combined(with: .opacity))
  }

  private func stop() {
    timeout?.cancel()
    timeout = nil
  }

  private func start(_ agent: Agent, _ after: AfterSwitch) {
    phase = .switching
    self.agent = agent
    self.after = after
    stop()
    timeout = Task {
      try? await Task.sleep(for: switchWait)
      if Task.isCancelled || phase != .switching { return }
      timeout = nil
      phase = .failed
    }
    Task {
      do {
        try await remote.switchToConversation(window, agent)
      } catch {
        guard phase == .switching else { return }
        stop()
        phase = .idle
        Haptics.failed()
        Toaster.shared.show(errorText(error))
      }
    }
  }

  /// The agent reported from this window: its session's page takes this one's place.
  private func check() {
    guard phase == .switching, let s = remote.sessions.first(where: { $0.window == window }) else { return }
    stop()
    phase = .idle
    home.switched(window: window, key: s.key, after: after)
  }
}

/// What switching [agent] in [window] does, asked before it's done. omp restarts, so the sheet first asks the
/// computer whether it's at work, warns that restarting stops it and offers to have it carry on. Answers what the
/// session page does about the stopped run once confirmed, nil if not.
struct SwitchSheet: View {
  @ObservedObject var remote: TerminalRemote
  let window: String
  let agent: Agent
  let onPick: (AfterSwitch?) -> Void

  /// omp: whether it's at work; nil while the computer is asked. Claude Code isn't asked: nothing restarts.
  @State private var busy: Bool?

  init(remote: TerminalRemote, window: String, agent: Agent, onPick: @escaping (AfterSwitch?) -> Void) {
    self.remote = remote
    self.window = window
    self.agent = agent
    self.onPick = onPick
    _busy = State(initialValue: agent == .omp ? nil : false)
  }

  var body: some View {
    let omp = agent == .omp
    // Landscape or large text: the sheet scrolls rather than running off the screen.
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Switch to conversation")
          .font(.title3.weight(.semibold))
        Text(
          omp
            ? "PocketTerm restarts omp in this window and picks the same conversation back up "
              + "(\(Agent.omp.resumeIn(remote.window(window)?.profile ?? ""))). Nothing is lost."
            : "PocketTerm types \(Agent.claude.pickUp) in it. Nothing restarts."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        if busy == true {
          Label(
            "It\u{2019}s working right now, and restarting stops it. Restart and continue has it carry on; "
              + "Just restart leaves it stopped.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.subheadline)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("switch-busy")
        }
        switch busy {
        case nil:
          ProgressView()
            .frame(maxWidth: .infinity, minHeight: 48)
            .accessibilityIdentifier("switch-probing")
        case true?:
          // omp at work: restart and have it carry on, or just restart, stacked so both read in full.
          VStack(spacing: 8) {
            Button { pick(.send) } label: { Text("Restart and continue").frame(maxWidth: .infinity) }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .accessibilityIdentifier("switch-continue")
            Button { pick(.offer) } label: { Text("Just restart").frame(maxWidth: .infinity) }
              .buttonStyle(.bordered)
              .controlSize(.large)
              .accessibilityIdentifier("switch-confirm")
            notNow
          }
        case false?:
          HStack(spacing: 12) {
            Spacer()
            notNow
            Button(omp ? "Restart now" : "Switch") { pick(.nothing) }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .accessibilityIdentifier("switch-confirm")
          }
        }
      }
      .padding(20)
    }
    .task {
      guard busy == nil else { return }
      // Unknown: offered without the warning.
      let b = (try? await remote.probe(window)) ?? false
      busy = b
    }
  }

  private var notNow: some View {
    Button("Not now") { onPick(nil) }
      .controlSize(.large)
      .foregroundStyle(.primary)
      .accessibilityIdentifier("switch-cancel")
  }

  private func pick(_ after: AfterSwitch) {
    Haptics.picked()
    onPick(after)
  }
}
