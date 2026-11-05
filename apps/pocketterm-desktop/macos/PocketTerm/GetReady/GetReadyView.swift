import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals
import SwiftUI

/// The setup checklist: what this computer and the phone need after the first sign-in here, each step checking
/// itself off as it gets done. The signed-in window until it's finished (`AppController.getReadyDone`); Settings'
/// status bar opens it again.
///
/// 1. Coding agents: each agent found (omp, Claude Code) with whether PocketTerm is in it; Install puts it there once
///    the person read why and confirmed (`confirmAgentInstall`), never on its own. Agent sessions opened before it
///    are listed with what picks it up there, until they report.
/// 2. Terminals: the Mac's, each with its fix.
/// 3. Project folders (optional): the usual ones found in the home folder.
/// 4. Your phone: the pairing QR, until a phone has signed in.
struct GetReadyView: View {
  @EnvironmentObject var app: AppController

  /// How often the terminals' windows and the phone are looked at.
  var poll: TimeInterval = 3
  /// How long looking goes on once the window is hidden; while it shows, it keeps looking.
  var lookHidden: TimeInterval = 10 * 60

  private enum Step: String { case agents, terminals, folders, phone }
  private enum Status { case done, action, optional, working }

  /// Agents PocketTerm is going into now, and why it didn't go into others.
  @State private var installing = Set<Agent>()
  @State private var failed: [Agent: String] = [:]
  /// Agent windows no live session claims; nil until looked at.
  @State private var unreported: [TermWindow]?
  /// The terminals as the card last found them.
  @State private var terminals: [TermStatus]?
  /// When looking stops, the window being hidden; nil while it shows.
  @State private var lookUntil: Date?
  @State private var installRequest: AgentInstallRequest?

  var body: some View {
    let left = self.left
    Form {
      Section {
      } header: {
        VStack(alignment: .leading, spacing: 6) {
          Text("Get this computer ready").font(.title2.weight(.semibold)).foregroundStyle(.primary)
          Text(
            "A few things so your phone sees your coding sessions and terminals. Each one checks itself off when "
              + "it\u{2019}s done."
          )
          .font(.body)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
      }
      step(.agents, "Your coding agents", agentsStatus) { agentsBody }
      step(.terminals, "Your terminals", terminalsStatus) {
        MacTerminalsCard(poll: poll, onStatuses: { terminals = $0 })
      }
      step(.folders, "Project folders", foldersStatus, optional: true) { foldersBody }
      step(.phone, "Your phone", phoneStatus) { phoneBody }
      Section {
        HStack(alignment: .center, spacing: 12) {
          if !left.isEmpty {
            Text(
              "Still to do: \(left.joined(separator: " and ")). Settings keeps track of what\u{2019}s left."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("get-ready-left")
          }
          Spacer(minLength: 0)
          Button {
            app.setGetReadyDone(true)
          } label: {
            Text("Done").frame(minWidth: 80)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("get-ready-done")
        }
      }
    }
    .formStyle(.grouped)
    .confirmAgentInstall($installRequest) { agent in Task { await install(agent) } }
    .task {
      Task { await app.checkAgents() }
      while !Task.isCancelled {
        await look()
        try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
      }
    }
    .task {
      for await _ in app.live.changes { await lookAtWindows() }
    }
    .onChange(of: app.mainShown) { _ in
      lookUntil = nil
      Task {
        await app.checkAgents()
        await look()
      }
    }
    .onChange(of: app.mainHidden) { hidden in
      if hidden, lookUntil == nil { lookUntil = Date().addingTimeInterval(lookHidden) }
    }
  }

  // MARK: - Looking

  private func install(_ agent: Agent) async {
    installing.insert(agent)
    failed[agent] = nil
    do {
      try await app.installAgent(agent)
    } catch {
      failed[agent] = "\(error)"
    }
    installing.remove(agent)
    await lookAtWindows()
  }

  private func ask(_ agent: Agent) {
    let update = app.agents?[agent].map { integrationOf($0) == .outdated } ?? false
    installRequest = AgentInstallRequest(agent: agent, update: update)
  }

  private func look() async {
    if let lookUntil, Date() > lookUntil { return }
    await lookAtWindows()
    if !(app.phoneSignedIn ?? false) { await app.checkPhone() }
  }

  private func lookAtWindows() async {
    let windows = await app.terminals.windows()
    unreported = app.unreportedAgentWindows(windows)
  }

  // MARK: - State

  private var agentsStatus: Status {
    guard let agents = app.agents, installing.isEmpty else { return .working }
    let ready =
      !agents.isEmpty && agents.values.allSatisfy { integrationOf($0) == .installed } && (unreported?.isEmpty ?? true)
    return ready ? .done : .action
  }

  private var terminalsStatus: Status {
    guard let t = terminals else { return .working }
    return terminalsNeedingSetup(t).isEmpty && !noTerminalApp(t) ? .done : .action
  }

  private var foldersStatus: Status { app.projectRoots.isEmpty ? .optional : .done }

  private var phoneStatus: Status { app.phoneSignedIn == true ? .done : .action }

  /// The essential steps not done yet, by name, for the Done button.
  private var left: [String] {
    (agentsStatus != .done ? ["your coding agents"] : []) + (terminalsStatus != .done ? ["your terminals"] : [])
  }

  // MARK: - Steps

  private func step<Content: View>(
    _ step: Step, _ title: String, _ status: Status, optional: Bool = false,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Section {
      content()
    } header: {
      HStack(spacing: 8) {
        sign(status, large: true)
        Text(title).font(.headline).foregroundStyle(.primary)
        if optional && status != .done {
          Text("Optional").font(.callout).foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("get-ready-\(step.rawValue)")
    }
  }

  @ViewBuilder private func sign(_ status: Status, large: Bool = false, error: Bool = false) -> some View {
    Group {
      switch status {
      case .done: Image(systemName: large ? "checkmark.circle.fill" : "checkmark").foregroundStyle(.green)
      case .action:
        Image(systemName: error ? "exclamationmark.circle" : (large ? "exclamationmark.circle.fill" : "exclamationmark.triangle"))
          .foregroundStyle(error ? Color.red : Color.orange)
      case .optional: Image(systemName: large ? "circle" : "minus").foregroundStyle(.secondary)
      case .working: ProgressView().controlSize(.small)
      }
    }
    .frame(width: 18)
  }

  private func line(_ status: Status, _ text: String, error: Bool = false) -> some View {
    line(status, text, error: error) { EmptyView() }
  }

  private func line<Trailing: View>(
    _ status: Status, _ text: String, error: Bool = false, @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      sign(status, error: error)
      Text(text)
        .foregroundStyle(error ? Color.red : (status == .optional ? Color.secondary : Color.primary))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      trailing()
    }
  }

  // MARK: Agents

  @ViewBuilder private var agentsBody: some View {
    let unreported = self.unreported ?? []
    if let agents = app.agents {
      if agents.isEmpty && installing.isEmpty {
        line(
          .action,
          "No coding agent found. PocketTerm works with omp and Claude Code: install one, then come back here.")
      } else {
        ForEach(Agent.allCases, id: \.self) { agentLine($0, agents[$0]) }
      }
    } else {
      line(.working, "Looking for omp and Claude Code…")
    }
    if !unreported.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Sessions that were already open")
          .fontWeight(.semibold)
          .accessibilityIdentifier("get-ready-open-sessions")
        note(
          "PocketTerm talks to your phone through a small add-on inside omp and Claude Code. An agent loads "
            + "add-ons when it starts, so sessions opened before PocketTerm don\u{2019}t have it yet: your phone sees "
            + "only their screen, not the conversation. Do this once in each; new sessions don\u{2019}t need it.")
        ForEach(Agent.allCases.filter { a in unreported.contains { $0.agent == a } }, id: \.self) { agent in
          switch agent {
          case .claude: note("\(Integrations.name(agent)): type \(agent.pickUp) in it. Nothing restarts.")
          case .omp:
            note(
              "\(Integrations.name(agent)): quit it and run \(agent.pickUp). You\u{2019}re back in the same "
                + "conversation.")
          }
        }
        note(
          "Afterwards your phone shows the conversation: answer questions and approvals there and get a "
            + "notification when a run finishes.")
      }
      ForEach(unreported, id: \.key) { w in
        SessionToPickUp(window: w, id: "get-ready-unreported-\(w.key)")
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private func agentLine(_ agent: Agent, _ check: AgentCheck?) -> some View {
    let name = Integrations.name(agent)
    if installing.contains(agent) {
      line(.working, "Installing PocketTerm in \(name)…")
    } else if let error = failed[agent] {
      line(.action, "Couldn't install PocketTerm in \(name): \(error)", error: true) {
        Button("Retry") { ask(agent) }
      }
    } else if let check {
      if let problem = check.state.problem {
        line(.action, problem)
      } else {
        switch integrationOf(check) {
        case .installed: line(.done, "PocketTerm is installed in \(name)")
        case .off: line(.action, Integrations.modsOffHint)
        case .outdated:
          line(.action, "PocketTerm in \(name) is out of date") { Button("Update") { ask(agent) } }
        case .missing:
          line(.action, "PocketTerm isn\u{2019}t installed in \(name)") { Button("Install") { ask(agent) } }
        }
      }
    } else {
      line(.optional, "\(name) not found: install it later and PocketTerm offers it in Settings")
    }
  }

  // MARK: Folders

  /// Where projects usually live, below the home folder.
  private static let usual: Set<String> = [
    "Dev", "Developer", "Projects", "projects", "code", "Code", "src", "repos", "dev", "git",
  ]

  /// The usual project folders that exist here and aren't added yet. The home folder is listed rather than each name
  /// tried, so a Mac's case-insensitive disk doesn't offer ~/Projects twice.
  private func suggestions() -> [String] {
    let home = app.terminals.home
    let roots = Set(app.projectRoots)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []  // No home folder to look in.
    let found = names.filter { Self.usual.contains($0) }.map { "\(home)/\($0)" }.filter { path in
      // A link to a folder isn't one (as Dart's listSync without following links).
      let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
      return type == .typeDirectory
    }
    return found.sorted().filter { !roots.contains($0) }
  }

  private func addFolders(_ picked: [String]) {
    if picked.isEmpty { return }
    var all = app.projectRoots
    for p in picked where !all.contains(p) { all.append(p) }
    app.setProjectRoots(all)
  }

  @ViewBuilder private var foldersBody: some View {
    let home = app.terminals.home
    Text("Your phone lists the git repositories in these and starts new projects there.")
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    ForEach(app.projectRoots, id: \.self) { r in line(.done, tildePath(r, home: home)) }
    FlowLayout(spacing: 8) {
      ForEach(suggestions(), id: \.self) { s in
        Button {
          addFolders([s])
        } label: {
          Label(tildePath(s, home: home), systemImage: "plus")
        }
        .accessibilityIdentifier("get-ready-folder-\(s)")
      }
      Button("Choose folder…") {
        Task { addFolders(await app.host.pickFolders()) }
      }
      .accessibilityIdentifier("get-ready-choose-folder")
    }
  }

  // MARK: Phone

  @ViewBuilder private var phoneBody: some View {
    if app.phoneSignedIn ?? false {
      Text("A phone is signed in. To add another: Settings \u{2192} Phone \u{2192} Add a phone\u{2026}")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if let h = app.hosting {
      HostedPhone(server: h)
    } else {
      PhonePairing(tailscale: app.backend?.host.hasSuffix(".ts.net") ?? false)
    }
  }
}

/// A computer running the server: the phone's code needs Tailscale's address, so its state shows until Tailscale
/// serves it.
private struct HostedPhone: View {
  @ObservedObject var server: BuiltInServer

  var body: some View {
    if server.state != .ready {
      HostingStatusView(server: server)
    } else {
      PhonePairing(tailscale: true)
    }
  }
}

/// The phone's QR; through Tailscale (this computer's server, or another computer's), the phone needs it too.
private struct PhonePairing: View {
  let tailscale: Bool

  var body: some View {
    if tailscale {
      Text(phoneTailscaleNote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("get-ready-phone-tailscale")
    }
    VStack(spacing: 10) {
      PairingQrView()
      Text(
        "PocketTerm for iPhone is on TestFlight and for Android on Google Play internal testing, for invited testers."
      )
      .font(.caption)
      .multilineTextAlignment(.center)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
  }
}

/// Buttons in rows that wrap at the width they get, as Flutter's Wrap.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(proposal.width ?? .infinity, subviews)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(bounds.width, subviews) {
      var x = bounds.minX
      for i in row.items {
        let size = subviews[i].sizeThatFits(.unspecified)
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var items: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
    var rows = [Row()]
    for i in subviews.indices {
      let size = subviews[i].sizeThatFits(.unspecified)
      let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
      if needed > maxWidth && !rows[rows.count - 1].items.isEmpty {
        rows.append(Row())
      }
      var row = rows[rows.count - 1]
      row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.items.append(i)
      rows[rows.count - 1] = row
    }
    return rows.filter { !$0.items.isEmpty }
  }
}
