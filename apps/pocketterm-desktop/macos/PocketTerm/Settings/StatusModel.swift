import Combine
import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals
import SwiftUI

/// Something that needs the person on this computer: the tab it's on, a few words for the status line, the whole
/// of it for its list, and the button that does it where one can.
struct AttentionItem: Identifiable {
  let id: String
  let tab: SettingsTab
  let short: String
  let text: String
  let action: AttentionAction?
}

/// An attention item's button.
struct AttentionAction {
  let label: String
  let id: String
  let run: @MainActor () -> Void
}

/// What a one-click terminal fix said, with the fix it was for and whether it failed: shown until the terminal's
/// status no longer carries that fix, then the live status speaks.
struct FixNote {
  let fix: TermFix?
  let note: String
  let failed: Bool
}

/// How PocketTerm going into an agent went, since the window was last shown.
struct InstallNote {
  let text: String
  let kind: StatusKind
}

/// What Settings and the menu-bar panel know about this computer: the terminals, the agents, the phones, the
/// clock, and from them what needs attention. Settings' window is hidden, never rebuilt, so it looks again each time
/// the window is shown (`AppController.mainShown`).
@MainActor
final class StatusModel: ObservableObject {
  let app: AppController

  /// Still looking at the agents or the terminals: nothing is listed as needing attention meanwhile.
  @Published private(set) var checking = true
  @Published private(set) var items: [AttentionItem] = []

  /// The terminals as the bridge would find them, and their windows.
  @Published private(set) var terminals: [TermStatus]?
  @Published private(set) var windowCount = 0

  /// What a one-click fix said, by terminal id.
  @Published private(set) var fixed: [String: FixNote] = [:]

  /// Agents PocketTerm is going into, and how it went in each.
  @Published private(set) var installing: Set<Agent> = []
  @Published private(set) var installNotes: [Agent: InstallNote] = [:]

  /// An Install or Update waiting for the person's yes (the confirm sheet over the Settings tab showing).
  @Published var installRequest: AgentInstallRequest?

  /// Agent windows no live session claims, as of the last look at the terminals.
  @Published private(set) var unreported: [TermWindow] = []

  /// Who is signed in to the server, for the Account tab; nil until known.
  @Published private(set) var devices: [Device]?

  /// This computer's clock is too far off its server's (a VPS's, another computer's): phones drop what it sends.
  @Published private(set) var clock: String?

  /// Ghostty's config, for starting its new windows in tmux; nil without Ghostty. What it says, as of the last look.
  let ghosttyConfig: GhosttyConfig?
  @Published private(set) var ghosttyCommand: GhosttyCommand?

  /// PocketTerm's Ghostty line was an earlier one's and was made this one's while the app runs: its row says so.
  @Published private(set) var ghosttyUpgraded = false

  /// The status section lists what needs attention (Show / Hide), on every tab alike.
  @Published var showAttention = false

  private var watching: Set<AnyCancellable> = []
  private var liveChanges: Task<Void, Never>?
  private var lastTerminalOn: Bool

  init(app: AppController) {
    self.app = app
    ghosttyConfig = app.terminals.ghostty == nil ? nil : GhosttyConfig.standard(home: app.terminals.home)
    lastTerminalOn = app.terminalOn
    // Each show of the window (and the first, at launch) looks again.
    app.$mainShown.removeDuplicates().sink { [weak self] _ in
      Task { @MainActor in self?.shown() }
    }.store(in: &watching)
    // A sign-in: the phones, devices and clock are the new account's.
    app.$user.map { $0?.id }.removeDuplicates().dropFirst().sink { [weak self] _ in
      Task { @MainActor in
        self?.devices = nil
        self?.clock = nil
        self?.startCheck()
      }
    }.store(in: &watching)
    // objectWillChange fires before the change: the items are made again once it landed.
    app.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.appChanged() }
    }.store(in: &watching)
    let changes = app.live.changes
    liveChanges = Task { [weak self] in
      for await _ in changes { await self?.checkUnreported() }
    }
  }

  deinit { liveChanges?.cancel() }

  /// "Looking for terminals…", or "2 terminal windows · 1 coding session".
  var terminalsLine: String {
    guard terminals != nil else { return "Looking for terminals…" }
    return "\(Self.count(windowCount, "terminal window")) · \(Self.count(app.live.sessions.count, "coding session"))"
  }

  /// "1 terminal window", "2 terminal windows".
  static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

  private func shown() {
    installNotes = [:]
    startCheck()
  }

  private func appChanged() {
    // Terminal from phone switched (here or in the menu-bar panel): the terminals' line counts again.
    if app.terminalOn != lastTerminalOn {
      lastTerminalOn = app.terminalOn
      Task { await checkTerminals() }
    }
    refresh()
  }

  /// What the system, the terminals and the agents say now, without waiting for it.
  func startCheck() {
    Task { await app.refreshLaunchAtLogin() }
    Task { await checkTerminals() }
    Task {
      await app.checkAgents()
      refresh()
    }
    if app.user != nil && app.server != nil {
      Task {
        await app.checkPhone()
        refresh()
      }
    }
    Task { await checkDevices() }
    Task { await checkClock() }
  }

  /// `check`, waited for (the menu-bar panel's look).
  func check() async {
    await app.refreshLaunchAtLogin()
    async let terminals: Void = checkTerminals()
    async let agents: Void = app.checkAgents()
    async let devices: Void = checkDevices()
    async let clock: Void = checkClock()
    if app.user != nil && app.server != nil { await app.checkPhone() }
    _ = await (terminals, agents, devices, clock)
    refresh()
  }

  func checkDevices() async {
    guard app.user != nil, app.server != nil else { return }
    do {
      devices = try await app.serverDevices()
    } catch {
      debugLog("PocketTerm: devices not listed: \(error)")
    }
  }

  /// Whether this computer's clock is far off its server's, while signed in to one; the server built into this
  /// app keeps this computer's own time.
  private func checkClock() async {
    guard let backend = app.backend, app.server != nil, app.hosting == nil else { return }
    let health = await backend.health()
    if health.error == nil {
      clock = Backend.clockWarning(health.clockOffset)
      refresh()
    }
  }

  func checkTerminals() async {
    let statuses = await app.terminals.statuses()
    var upgraded = false
    if let config = ghosttyConfig, let tmux = app.terminals.tmux?.executable {
      do {
        upgraded = try config.upgrade(tmux)
      } catch {
        debugLog("PocketTerm: Ghostty config not upgraded: \(error)")
      }
    }
    let command = ghosttyConfig?.read()
    let windows = await app.terminals.windows()
    terminals = statuses
    for t in statuses {
      if let f = fixed[t.id], f.fix != t.fix { fixed[t.id] = nil }
    }
    ghosttyCommand = command
    if upgraded { ghosttyUpgraded = true }
    windowCount = windows.count
    unreported = app.unreportedAgentWindows(windows)
    refresh()
  }

  /// A coding session came or went: the agent windows it claims change.
  private func checkUnreported() async {
    let windows = await app.terminals.windows()
    unreported = app.unreportedAgentWindows(windows)
    refresh()
  }

  // ---------------------------------------------------------------- doing

  /// Settings' one click for `s`: `fixTerminal` on the Mac.
  func fix(_ s: TermStatus) async {
    let result = await fixTerminal(app.terminals, s)
    fixed[s.id] = FixNote(fix: s.fix, note: result.note, failed: result.failed)
    refresh()
    await checkTerminals()
  }

  /// Ghostty's new windows in tmux, or back to the shell; what went wrong, if something did.
  func ghosttyTmux(on: Bool) async -> String? {
    guard let config = ghosttyConfig else { return nil }
    var failure: String?
    do {
      if on, let tmux = app.terminals.tmux?.executable {
        try config.add(tmux)
      } else if !on {
        try config.remove()
      }
    } catch {
      failure = "\(error)"
    }
    await checkTerminals()
    return failure
  }

  /// Asks to install (or update) PocketTerm in `agent`: the confirm sheet, then `install`.
  func askInstall(_ agent: Agent) {
    let update = app.agents?[agent].map { integrationOf($0) == .outdated } ?? false
    installRequest = AgentInstallRequest(agent: agent, update: update)
  }

  /// Installs (or updates) PocketTerm in `agent` once the person confirmed it; its row says how it went.
  func install(_ agent: Agent) {
    installing.insert(agent)
    installNotes[agent] = nil
    refresh()
    Task {
      var error: String?
      do {
        try await app.installAgent(agent)
      } catch let e {
        error = "Couldn’t install PocketTerm in \(Integrations.name(agent)): \(e)"
      }
      // Whether it runs: mods may be off.
      let modsOff = app.agents?[agent]?.modsOff ?? false
      installing.remove(agent)
      if let error {
        installNotes[agent] = InstallNote(text: error, kind: .error)
      } else if modsOff {
        installNotes[agent] = InstallNote(text: "Installed · \(Integrations.modsOffHint)", kind: .warn)
      } else {
        let text =
          switch agent {
          case .omp: "Installed · restart your omp sessions to load it (\(agent.resume))"
          case .claude: "Installed · type \(agent.pickUp) in open Claude Code sessions to load it"
          }
        installNotes[agent] = InstallNote(text: text, kind: .ok)
      }
      refresh()
    }
  }

  /// Phone → Project folders → Add folder…: the picked folders join the list, each once.
  func addFolders() {
    Task {
      let picked = await app.host.pickFolders()
      if picked.isEmpty { return }
      var roots = app.projectRoots
      for p in picked where !roots.contains(p) { roots.append(p) }
      app.setProjectRoots(roots)
    }
  }

  /// What picks PocketTerm up in `windows` (all running `agent`): in their omp profile when they share one; the
  /// default's command when they're in several (each window's own shows under Show sessions).
  static func pickUpOf(_ agent: Agent, _ windows: [TermWindow]) -> String {
    let profiles = Set(windows.map(\.profile))
    return agent.pickUpIn(profiles.count == 1 ? profiles.first! : "")
  }

  /// `s`'s one-click fix, as its row and the status section offer it.
  func fixAction(_ s: TermStatus) -> AttentionAction? {
    switch s.fix {
    case .kittyConfig where fixed[s.id].map(\.failed) ?? true:
      AttentionAction(label: "Set up", id: "settings-fix-\(s.id)") { [weak self] in Task { await self?.fix(s) } }
    case .automation:
      AttentionAction(label: "Allow…", id: "settings-fix-\(s.id)") { [weak self] in Task { await self?.fix(s) } }
    // WezTerm's installer is the Windows app's.
    default:
      nil
    }
  }

  /// `agent`'s Install (or Update) as `label`, or that it's going in.
  func agentAction(_ agent: Agent, _ label: String) -> AttentionAction {
    if installing.contains(agent) {
      return AttentionAction(label: "Installing…", id: "settings-install-\(agent.name)") {}
    }
    return AttentionAction(label: label, id: "settings-install-\(agent.name)") { [weak self] in
      self?.askInstall(agent)
    }
  }

  // ---------------------------------------------------------------- attention

  private func refresh() {
    let now = app.agents == nil || terminals == nil
    if checking != now { checking = now }
    items = now ? [] : attention()
  }

  /// What needs the person on this computer, each with the button that does it where one can.
  private func attention() -> [AttentionItem] {
    var items: [AttentionItem] = []
    if let agents = app.agents {
      if agents.isEmpty {
        items.append(
          AttentionItem(
            id: "no-agent", tab: .agents, short: "No coding agent found",
            text: "No coding agent found: install omp or Claude Code, and PocketTerm offers to set it up here",
            action: nil))
      }
      for agent in Agent.allCases {
        guard let check = agents[agent] else { continue }
        let name = Integrations.name(agent)
        let failed = installNotes[agent].flatMap { $0.kind == .error ? $0.text : nil }
        switch integrationOf(check) {
        case .installed:
          break
        case .off:
          items.append(
            AttentionItem(
              id: "agent-\(agent.name)", tab: .agents, short: "\(name) has mods off", text: Integrations.modsOffHint,
              action: nil))
        case .outdated:
          items.append(
            AttentionItem(
              id: "agent-\(agent.name)", tab: .agents, short: "PocketTerm in \(name) is out of date",
              text: failed ?? "PocketTerm in \(name) is out of date", action: agentAction(agent, "Update")))
        case .missing:
          let problem = check.state.problem
          items.append(
            AttentionItem(
              id: "agent-\(agent.name)", tab: .agents, short: problem ?? "PocketTerm isn’t installed in \(name)",
              text: problem ?? failed ?? "PocketTerm isn’t installed in \(name)",
              action: problem == nil ? agentAction(agent, "Install") : nil))
        }
      }
    }
    for agent in Agent.allCases {
      let windows = unreported.filter { $0.agent == agent }
      let n = windows.count
      if n == 0 { continue }
      let short =
        switch agent {
        case .claude: "\(Self.count(n, "Claude Code session")) to reload"
        case .omp: "\(Self.count(n, "omp session")) to reopen"
        }
      let text =
        switch agent {
        case .claude:
          "\(Self.count(n, "Claude Code session")) opened before PocketTerm: type \(agent.pickUp) in \(n == 1 ? "it" : "them")"
        case .omp:
          "\(Self.count(n, "omp session")) opened before PocketTerm: quit omp in \(n == 1 ? "it" : "them") and run "
            + Self.pickUpOf(agent, windows)
        }
      items.append(AttentionItem(id: "unreported-\(agent.name)", tab: .agents, short: short, text: text, action: nil))
    }
    let statuses = terminals ?? []
    for s in terminalsNeedingSetup(statuses) {
      items.append(
        AttentionItem(
          id: "terminal-\(s.id)", tab: .terminals, short: "\(s.label) needs setup",
          // Their notes name the terminal already.
          text: fixed[s.id]?.note ?? (s.note.isEmpty ? "\(s.label) needs setup" : s.note), action: fixAction(s)))
    }
    if terminals != nil && noTerminalApp(statuses) {
      items.append(
        AttentionItem(
          id: "no-terminal", tab: .terminals, short: "No terminal app found",
          text: "No terminal app found: PocketTerm works with kitty, iTerm2, Ghostty and WezTerm", action: nil))
    }
    if let clock {
      items.append(AttentionItem(id: "clock", tab: .account, short: "This computer’s clock is off", text: clock, action: nil))
    }
    if let off = app.phoneClockOff {
      let minutes = Int((abs(off) / 60).rounded())
      items.append(
        AttentionItem(
          id: "phone-clock", tab: .phone, short: "A phone’s clock is off",
          text: "A phone’s clock is \(minutes) minutes \(off < 0 ? "behind" : "ahead of") this computer’s, so "
            + "what it sends is refused: turn on automatic date and time on both", action: nil))
    }
    if let h = app.hosting, h.state != .ready, h.state != .checking {
      let open = h.state == .tailscaleOff || h.state == .loggedOut
      let text =
        switch h.state {
        case .noTailscale: "Tailscale isn’t installed, so phones can’t reach the server on this computer"
        case .tailscaleOff: "Tailscale isn’t running, so phones can’t reach the server on this computer"
        case .loggedOut: "Tailscale is signed out, so phones can’t reach the server on this computer"
        default: "Tailscale doesn’t serve this computer’s server, so phones can’t reach it: see Account"
        }
      items.append(
        AttentionItem(
          id: "hosting", tab: .account, short: "Phones can’t reach your server", text: text,
          action: open
            ? AttentionAction(label: "Open Tailscale", id: "attention-open-tailscale") {
              Task { await h.tailscale.open() }
            } : nil))
    } else if let old = app.hosting?.renamedFrom {
      items.append(
        AttentionItem(
          id: "renamed", tab: .account, short: "Tailscale address changed",
          text: "This computer’s Tailscale address changed from \(old.host ?? ""): each phone must scan its code again",
          action: AttentionAction(label: "Add a phone…", id: "attention-add-phone-renamed") { [weak self] in
            self?.app.hosting?.renameSeen()
            AppModel.shared.addPhone()
          }))
    }
    if app.phoneSignedIn == false {
      items.append(
        AttentionItem(
          id: "no-phone", tab: .phone, short: "No phone yet", text: "No phone signed in yet",
          action: AttentionAction(label: "Add a phone…", id: "attention-add-phone") { AppModel.shared.addPhone() }))
    }
    if app.projectRoots.isEmpty {
      items.append(
        AttentionItem(
          id: "no-folders", tab: .phone, short: "No project folders",
          text: "No project folders: your phone can’t list your projects",
          action: AttentionAction(label: "Add folder…", id: "attention-add-folder") { [weak self] in
            self?.addFolders()
          }))
    }
    return items
  }
}
