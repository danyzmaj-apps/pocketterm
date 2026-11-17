import AppKit
import Combine
import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals

/// How a project's terminals share Desk's window.
enum DeskLayout: String, CaseIterable, Identifiable {
  /// The focused terminal alone.
  case single
  /// The focused terminal large on the left, the others stacked beside it.
  case focus
  /// Every terminal, in rows and columns.
  case grid

  var id: String { rawValue }

  var label: String {
    switch self {
    case .single: "Single"
    case .focus: "Focus"
    case .grid: "Grid"
    }
  }

  var symbol: String {
    switch self {
    case .single: "rectangle"
    case .focus: "rectangle.leadinghalf.inset.filled"
    case .grid: "square.grid.2x2"
    }
  }
}

/// Where a Desk terminal stands, most urgent first.
enum DeskState: Equatable {
  /// Its agent waits for an answer: a question, an approval, a plan.
  case needs(String)
  /// Its agent's run ended while you looked elsewhere.
  case finished
  /// Its agent's last run failed.
  case failed
  /// Its agent works.
  case working
  /// A program runs in it (a dev server, a build).
  case running(String)
  /// A shell or an agent at rest.
  case idle

  /// Waits for the person: what Next That Needs You goes through.
  var wantsYou: Bool {
    switch self {
    case .needs, .finished, .failed: true
    default: false
    }
  }

  /// How urgent, for ordering: lower first.
  var rank: Int {
    switch self {
    case .needs: 0
    case .failed: 1
    case .finished: 2
    case .working: 3
    case .running: 4
    case .idle: 5
    }
  }

  /// What the sidebar and the pane header say of it.
  var words: String {
    switch self {
    case .needs(let what): what
    case .finished: "Finished"
    case .failed: "Last run failed"
    case .working: "Working…"
    case .running(let program): program
    case .idle: "Idle"
    }
  }
}

/// A command a project runs often (`npm run dev`), one click (or ⌘K) away.
struct DeskCommand: Hashable, Identifiable {
  var command: String
  /// Saved by the person, not found in the project (package.json's scripts).
  var saved: Bool
  var id: String { command }
}

/// Desk's state: its terminals (tmux sessions, `Desk`) grouped by project, how each stands (the coding sessions'
/// hub), which project and terminal have the focus, and each project's layout, git state, ports and commands.
@MainActor
final class DeskModel: ObservableObject {
  let app: AppController
  let desk: Desk
  private let prefs: UserDefaultsPreferenceStore

  /// Every terminal, oldest first.
  @Published private(set) var sessions: [DeskSession] = []
  /// Each terminal's state, by session name.
  @Published private(set) var states: [String: DeskState] = [:]
  /// The project showing.
  @Published private(set) var project: String?
  /// Each project's focused terminal, by session name.
  @Published private(set) var focused: [String: String] = [:]
  /// The focused terminal fills the window (Zoom), whatever the layout.
  @Published var zoomed = false
  @Published var paletteShown = false
  @Published var inspectorShown: Bool {
    didSet { prefs.setBool(Self.inspectorKey, inspectorShown) }
  }
  @Published private(set) var git: [String: DeskGit] = [:]
  /// Ports listening under each terminal, by session name.
  @Published private(set) var ports: [String: [Int]] = [:]
  @Published private(set) var found: [String: [DeskCommand]] = [:]
  /// Git repositories under the Project folders (Settings → Phone), for ⌘K.
  @Published private(set) var discovered: [String] = []
  @Published var sidebarShown = true
  /// What went wrong last (a failed tmux command), shown until the next action.
  @Published var error: String?
  /// tmux is missing: Desk can't run.
  @Published private(set) var noTmux = false

  /// Bumped to ask the focused terminal to take the keyboard.
  @Published private(set) var focusTick = 0

  /// Agents' runs that ended while their terminal wasn't in front, by window key.
  private var unseen = Set<String>()
  /// Whether each agent session was busy on the last look, by window key.
  private var wasBusy: [String: Bool] = [:]
  /// Projects by when they were shown last, latest first (⌘K's order).
  private var recent: [String] = []
  private var listener: HubListener?
  private var poll: Task<Void, Never>?
  private var looking = false
  /// The window shows: Desk polls only then.
  var visible = false {
    didSet { visible ? start() : stop() }
  }
  /// Desk's window is the key window (a run ending in its front terminal is seen).
  var windowKey = false

  private static let pinnedKey = "desk_projects"
  private static let layoutKey = "desk_layouts"
  private static let commandsKey = "desk_commands"
  private static let inspectorKey = "desk_inspector"
  private static let lastKey = "desk_project"

  init(app: AppController, prefs: UserDefaultsPreferenceStore) {
    self.app = app
    // A test build's stand-in terminals may have none: one on their tmux (or this Mac's).
    self.desk = app.terminals.desk ?? Desk(tmux: app.terminals.tmux ?? Tmux())
    self.prefs = prefs
    inspectorShown = prefs.bool(Self.inspectorKey) ?? true
    project = prefs.string(Self.lastKey)
    listener = app.live.onChange { [weak self] in self?.hubChanged() }
  }

  // ------------------------------------------------------------ looking

  private func start() {
    guard poll == nil else { return }
    poll = Task { [weak self] in
      var n = 0
      while !Task.isCancelled {
        await self?.look(details: n % 4 == 0)
        n += 1
        try? await Task.sleep(for: .milliseconds(1500))
      }
    }
    Task { discovered = await app.terminals.projects(app.projectRoots) }
  }

  private func stop() {
    poll?.cancel()
    poll = nil
  }

  /// The terminals now, and with `details` the showing project's git state, ports and commands.
  func look(details: Bool = false) async {
    if looking { return }
    looking = true
    defer { looking = false }
    noTmux = !desk.tmux.installed
    let procs = await Procs.snapshot()
    do {
      let list = try await desk.sessions(procs)
      if list != sessions { sessions = list }
    } catch {
      self.error = "\(error)"
    }
    if project == nil || !projects.contains(project!) { project = projects.first }
    restate()
    guard details, let project else { return }
    await lookAt(project, procs)
  }

  private func lookAt(_ project: String, _ procs: Procs) async {
    let mine = sessions(in: project)
    async let g = Desk.git(project)
    async let p = Desk.listening(under: mine.map(\.pid), procs)
    let (gitNow, portsNow) = await (g, p)
    if git[project] != gitNow { git[project] = gitNow }
    var byName: [String: [Int]] = [:]
    for s in mine { if let list = portsNow[s.pid], !list.isEmpty { byName[s.name] = list } }
    for s in mine where ports[s.name] != byName[s.name] { ports[s.name] = byName[s.name] }
    let scripts = Self.packageScripts(project)
    let saved = savedCommands(project)
    let all = saved.map { DeskCommand(command: $0, saved: true) }
      + scripts.filter { !saved.contains($0) }.map { DeskCommand(command: $0, saved: false) }
    if found[project] != all { found[project] = all }
  }

  /// `npm run <script>` for each of package.json's scripts (pnpm, yarn or bun where its lockfile is).
  private static func packageScripts(_ dir: String) -> [String] {
    let url = URL(fileURLWithPath: dir).appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: url),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let scripts = json["scripts"] as? [String: Any]
    else { return [] }
    let fm = FileManager.default
    func has(_ name: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name)) }
    let runner =
      has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun run" : "npm run"
    return scripts.keys.sorted().map { "\(runner) \($0)" }
  }

  private func hubChanged() {
    let sessions = app.live.sessions
    for s in sessions {
      guard let window = s.window else { continue }
      let before = wasBusy[window] ?? false
      wasBusy[window] = s.busy
      // A run ended, not into a question: unseen unless its terminal is the one in front.
      if before && !s.busy && s.ask == nil && !inFront(window) { unseen.insert(window) }
    }
    restate()
  }

  /// Whether window `key` is the focused terminal of the project showing, in the key window.
  private func inFront(_ key: String) -> Bool {
    guard windowKey, let s = focusedSession, s.key == key else { return false }
    return true
  }

  private func restate() {
    var byWindow: [String: LiveSession] = [:]
    for s in app.live.sessions { if let w = s.window { byWindow[w] = s } }
    var next: [String: DeskState] = [:]
    for s in sessions {
      if let live = byWindow[s.key] {
        let status = activityStatus(busy: live.busy, ask: live.ask)
        if status.state == .needs, let ask = live.ask {
          next[s.name] = .needs(Self.asking(ask))
        } else if live.busy {
          next[s.name] = .working
        } else if live.failed {
          next[s.name] = .failed
        } else if unseen.contains(s.key) {
          next[s.name] = .finished
        } else {
          next[s.name] = .idle
        }
      } else if s.busy {
        next[s.name] = .running(s.program)
      } else {
        next[s.name] = .idle
      }
    }
    if next != states { states = next }
  }

  private static func asking(_ ask: LiveAsk) -> String {
    switch ask.kind {
    case .approval: ask.tool.isEmpty ? "Wants approval" : "Approve \(ask.tool)?"
    case .plan: "Plan to review"
    case .questions: ask.questions?.first.map { $0.header.isEmpty ? "Has a question" : $0.header } ?? "Has a question"
    case .menu: "Waiting"
    }
  }

  // ------------------------------------------------------------ what shows

  /// Projects in the sidebar: pinned ones in their order, then ones with terminals, by name.
  var projects: [String] {
    let pinned = pinnedProjects
    let others = Set(sessions.map(\.project)).subtracting(pinned).sorted {
      Self.name($0).localizedStandardCompare(Self.name($1)) == .orderedAscending
    }
    return pinned + others
  }

  var pinnedProjects: [String] { prefs.stringList(Self.pinnedKey) ?? [] }

  func isPinned(_ project: String) -> Bool { pinnedProjects.contains(project) }

  func setPinned(_ project: String, _ on: Bool) {
    var list = pinnedProjects.filter { $0 != project }
    if on { list.append(project) }
    prefs.setStringList(Self.pinnedKey, list)
    objectWillChange.send()
  }

  /// A project's folder name; General for the home folder.
  static func name(_ project: String) -> String { Terminals.projectName(project, home: NSHomeDirectory()) }

  func sessions(in project: String) -> [DeskSession] { sessions.filter { $0.project == project } }

  func state(_ s: DeskSession) -> DeskState { states[s.name] ?? .idle }

  /// The most urgent state of a project's terminals.
  func state(of project: String) -> DeskState? {
    sessions(in: project).map(state).min { $0.rank < $1.rank }
  }

  /// What a terminal is called: the name it was given, its agent session's title, its agent, or what runs in it.
  func title(_ s: DeskSession) -> String {
    if !s.label.isEmpty { return s.label }
    if let live = app.live.sessions.first(where: { $0.window == s.key }), !live.title.isEmpty { return live.title }
    if let agent = s.agent { return agent.label }
    return s.busy ? s.program : "Shell"
  }

  func symbol(_ s: DeskSession) -> String {
    switch s.agent {
    case .some: "sparkles"
    case nil: s.kind == "run" ? "play" : "terminal"
    }
  }

  /// Terminals waiting for the person, most urgent first, then oldest.
  var waiting: [DeskSession] {
    sessions.filter { state($0).wantsYou }.sorted { state($0).rank < state($1).rank }
  }

  var focusedSession: DeskSession? {
    guard let project else { return nil }
    let mine = sessions(in: project)
    return mine.first { $0.name == focused[project] } ?? mine.first
  }

  /// The project's layout (Focus until changed).
  func layout(_ project: String) -> DeskLayout {
    (prefs.string("\(Self.layoutKey).\(project)")).flatMap(DeskLayout.init(rawValue:)) ?? .focus
  }

  func setLayout(_ layout: DeskLayout) {
    guard let project else { return }
    prefs.setString("\(Self.layoutKey).\(project)", layout.rawValue)
    zoomed = false
    objectWillChange.send()
    takeKeyboard()
  }

  /// The terminals showing, in their places.
  var shown: [DeskSession] {
    guard let project else { return [] }
    let mine = sessions(in: project)
    guard let f = focusedSession else { return [] }
    if zoomed { return [f] }
    switch layout(project) {
    case .single: return [f]
    case .focus: return [f] + mine.filter { $0.name != f.name }
    case .grid: return mine
    }
  }

  /// ⌘⇧↩: the focused terminal alone, and back.
  func toggleZoom() {
    guard focusedSession != nil else { return NSSound.beep() }
    zoomed.toggle()
    takeKeyboard()
  }

  var commands: [DeskCommand] { project.flatMap { found[$0] } ?? [] }

  /// The coding agents on this Mac (all of them until PocketTerm has looked), the one set in Settings first.
  var agents: [Agent] {
    let found = app.agents.map { a in Agent.allCases.filter { a[$0] != nil } } ?? Agent.allCases
    let list = found.isEmpty ? Agent.allCases : found
    return list.filter { $0 == app.codingAgent } + list.filter { $0 != app.codingAgent }
  }

  /// What ⌘⇧T starts: the coding agent set in Settings, if it's here.
  var defaultAgent: Agent { agents.first ?? .omp }

  // ------------------------------------------------------------ moving around

  func show(project: String, session: String? = nil) {
    if self.project != project { zoomed = false }
    self.project = project
    prefs.setString(Self.lastKey, project)
    recent.removeAll { $0 == project }
    recent.insert(project, at: 0)
    if let session { focus(session) } else { takeKeyboard() }
    if !sessions.contains(where: { $0.project == project }) || git[project] == nil {
      Task { await look(details: true) }
    }
  }

  /// Gives terminal `name` the focus (and the keyboard); seen once it has.
  func focus(_ name: String) {
    guard let s = sessions.first(where: { $0.name == name }) else { return }
    if project != s.project { show(project: s.project) }
    focused[s.project] = name
    if unseen.remove(s.key) != nil { restate() }
    takeKeyboard()
  }

  func takeKeyboard() { focusTick += 1 }

  /// ⌘1…⌘9: the project's terminal `n` (1-based, in the sidebar's order).
  func focus(number n: Int) {
    guard let project else { return }
    let mine = sessions(in: project)
    guard n >= 1, n <= mine.count else { return NSSound.beep() }
    focus(mine[n - 1].name)
  }

  /// ⌘⇧] / ⌘⇧[: the next or previous terminal of the project, round.
  func cycle(_ step: Int) {
    guard let project, let f = focusedSession else { return }
    let mine = sessions(in: project)
    guard let i = mine.firstIndex(of: f), mine.count > 1 else { return }
    focus(mine[(i + step + mine.count) % mine.count].name)
  }

  /// ⌘J: the next terminal that waits for you, after the focused one, across projects.
  func nextWaiting() {
    let list = waiting
    guard !list.isEmpty else { return NSSound.beep() }
    if let f = focusedSession, let i = list.firstIndex(of: f) {
      focus(list[(i + 1) % list.count].name)
    } else {
      focus(list[0].name)
    }
  }

  /// Projects for ⌘K: the one shown before this first (⌘K, Return goes back), then by recency, then the rest.
  var paletteProjects: [String] {
    var order = recent.filter { $0 != project }
    if let project { order.append(project) }
    for p in projects + discovered where !order.contains(p) { order.append(p) }
    return order
  }

  // ------------------------------------------------------------ changing

  /// A new terminal in the project showing (or `project`): a shell, which then starts `agent` or runs `command`.
  func new(agent: Agent? = nil, command: String? = nil, in project: String? = nil) {
    guard let project = project ?? self.project ?? projects.first else {
      error = "Open a project first (⌘K)."
      return
    }
    let typed = agent.map { $0.commandIn("") } ?? command
    let kind = agent?.name ?? (command == nil ? "shell" : "run")
    Task {
      do {
        error = nil
        let s = try await desk.create(project: project, kind: kind, label: command ?? "", command: typed)
        await look()
        show(project: project)
        focus(s.name)
      } catch {
        self.error = "\(error)"
      }
    }
  }

  /// Ends terminal `s` (asks first while something runs in it).
  func end(_ s: DeskSession, confirmed: Bool = false) {
    if !confirmed && s.busy {
      let alert = NSAlert()
      alert.messageText = "End “\(title(s))”?"
      alert.informativeText = "\(s.program) is still running in it. Ending the terminal stops it."
      alert.addButton(withTitle: "End")
      alert.addButton(withTitle: "Cancel")
      alert.buttons[0].hasDestructiveAction = true
      guard alert.runModal() == .alertFirstButtonReturn else { return takeKeyboard() }
    }
    Task {
      do {
        try await desk.end(s.name)
        DeskTerminals.shared.drop(s.name)
        await look()
        takeKeyboard()
      } catch {
        self.error = "\(error)"
      }
    }
  }

  func endFocused() {
    guard let s = focusedSession else { return NSSound.beep() }
    end(s)
  }

  func rename(_ s: DeskSession, to label: String) {
    Task {
      do {
        try await desk.rename(s.name, to: label.trimmingCharacters(in: .whitespacesAndNewlines))
        await look()
      } catch {
        self.error = "\(error)"
      }
    }
  }

  /// Opens a project with nothing running yet: pinned, so it stays in the sidebar.
  func open(project: String) {
    if !projects.contains(project) { setPinned(project, true) }
    show(project: project)
  }

  /// Chooses a folder to open as a project.
  func chooseProject() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open"
    panel.message = "A project folder"
    panel.directoryURL = URL(fileURLWithPath: app.projectRoots.first ?? NSHomeDirectory())
    guard panel.runModal() == .OK, let url = panel.url else { return takeKeyboard() }
    open(project: url.path)
  }

  /// Takes a project out of the sidebar, ending its terminals (asks first when any are there).
  func close(project: String) {
    let mine = sessions(in: project)
    if !mine.isEmpty {
      let alert = NSAlert()
      alert.messageText = "Close \(Self.name(project))?"
      alert.informativeText = "Its \(mine.count == 1 ? "terminal ends" : "\(mine.count) terminals end"), and what runs in them stops."
      alert.addButton(withTitle: "Close")
      alert.addButton(withTitle: "Cancel")
      alert.buttons[0].hasDestructiveAction = true
      guard alert.runModal() == .alertFirstButtonReturn else { return }
    }
    setPinned(project, false)
    Task {
      for s in mine {
        try? await desk.end(s.name)
        DeskTerminals.shared.drop(s.name)
      }
      if self.project == project { self.project = nil }
      await look()
    }
  }

  private func savedCommands(_ project: String) -> [String] {
    prefs.stringList("\(Self.commandsKey).\(project)") ?? []
  }

  func save(command: String) {
    guard let project else { return }
    let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !c.isEmpty else { return }
    prefs.setStringList("\(Self.commandsKey).\(project)", savedCommands(project).filter { $0 != c } + [c])
    Task { await look(details: true) }
  }

  func forget(command: String) {
    guard let project else { return }
    prefs.setStringList("\(Self.commandsKey).\(project)", savedCommands(project).filter { $0 != command })
    Task { await look(details: true) }
  }
}
