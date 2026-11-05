import Foundation
import PocketTermKit

// What the Terminal list works out from the computer's state: its projects in a steady order, where each terminal
// sits on the computer, and why some agent windows show only as screens.

/// The sessions in one project folder.
struct SessionGroup: Equatable {
  let cwd: String
  let sessions: [LiveSummary]
}

/// Sessions by project folder, each project's in the computer's order (as it first saw them), so a session changing
/// state never moves.
///
/// [sort] orders the projects; by name, [home] goes by General, the name it shows under ([projectName]). By activity,
/// the projects in [ranked] keep its order, so the list doesn't reshuffle while it's looked at; projects not in it
/// yet go first, the most recently active first. An empty [ranked] ranks them all afresh.
func groupedSessions(
  _ sessions: [LiveSummary], _ sort: ProjectSort, ranked: [String] = [], home: String = ""
) -> [SessionGroup] {
  var byCwd: [String: [LiveSummary]] = [:]
  var cwds: [String] = []
  for s in sessions {
    if byCwd[s.cwd] == nil { cwds.append(s.cwd) }
    byCwd[s.cwd, default: []].append(s)
  }
  let order: [String]
  switch sort {
  case .name:
    func name(_ cwd: String) -> String { cwd == home ? "general" : baseName(cwd).lowercased() }
    order = cwds.sorted { a, b in
      if a.isEmpty != b.isEmpty { return !a.isEmpty }
      let (na, nb) = (name(a), name(b))
      return na != nb ? na < nb : a < b
    }
  case .activity:
    func latest(_ cwd: String) -> Date { byCwd[cwd]!.map { $0.at ?? .distantPast }.max()! }
    let known = Set(ranked)
    order =
      cwds.filter { !known.contains($0) }.sorted { latest($0) > latest($1) }
      + ranked.filter { byCwd[$0] != nil }
  }
  return order.map { SessionGroup(cwd: $0, sessions: byCwd[$0]!) }
}

/// A tab of an app window on the computer: the terminals in it (panes split in one tab share it), in list order;
/// [number] counts from 1 within its window.
struct MacTab: Hashable {
  let id: String
  let number: Int
  let panes: [TermWindow]
}

/// An app window on the computer (what Cmd+N opens) and its tabs. [app] names its terminal app; [number] counts from
/// 1 among that app's windows, so the phone can say "kitty window 2".
struct MacWindow: Hashable {
  let id: String
  let app: String
  let number: Int
  let tabs: [MacTab]
}

/// The app [w] shows in: the terminal app a tmux pane is shown in, else its own, named as [terminals] (the
/// computer's) name it.
func termApp(_ w: TermWindow, terminals: [TermStatus] = []) -> String {
  !w.via.isEmpty ? w.via : terminals.first { $0.id == w.app }?.label ?? termLabel(w.app)
}

/// [windows] as they sit on the computer: its app windows, each with its tabs, numbered in the order they first come
/// in [windows] (the computer's list order). A terminal that doesn't say its app window (an older computer) is left
/// out; one that doesn't say its tab is a tab of its own.
func macLayout(_ windows: [TermWindow], terminals: [TermStatus] = []) -> [MacWindow] {
  var osWindows: [String] = []
  var tabsOf: [String: [String]] = [:]
  var panesOf: [String: [String: [TermWindow]]] = [:]
  for w in windows where !w.osWindow.isEmpty {
    let tab = w.tabId.isEmpty ? w.key : w.tabId
    if tabsOf[w.osWindow] == nil { osWindows.append(w.osWindow) }
    if panesOf[w.osWindow]?[tab] == nil { tabsOf[w.osWindow, default: []].append(tab) }
    panesOf[w.osWindow, default: [:]][tab, default: []].append(w)
  }
  var perApp: [String: Int] = [:]
  return osWindows.map { id in
    let tabs = tabsOf[id]!
    let app = termApp(panesOf[id]![tabs[0]]![0], terminals: terminals)
    let number = (perApp[app] ?? 0) + 1
    perApp[app] = number
    return MacWindow(
      id: id, app: app, number: number,
      tabs: tabs.enumerated().map { MacTab(id: $1, number: $0 + 1, panes: panesOf[id]![$1]!) })
  }
}

/// Where each terminal of [layout] sits, by its key: "kitty window 2 · tab 1".
func macPlaces(_ layout: [MacWindow]) -> [String: String] {
  var places: [String: String] = [:]
  for w in layout {
    for t in w.tabs {
      for p in t.panes { places[p.key] = "\(w.app) window \(w.number) · tab \(t.number)" }
    }
  }
  return places
}

/// [layout] counted: "3 windows · 7 tabs".
func layoutCount(_ layout: [MacWindow]) -> String {
  let tabs = layout.reduce(0) { $0 + $1.tabs.count }
  return "\(layout.count) window\(layout.count == 1 ? "" : "s") · \(tabs) tab\(tabs == 1 ? "" : "s")"
}

/// The pane a tab shows for itself: the focused one, else its first.
func tabLead(_ t: MacTab) -> TermWindow { t.panes.first { $0.focused } ?? t.panes[0] }

/// The live session running in tab [t], if one is.
func tabSession(_ r: TerminalRemote, _ t: MacTab) -> LiveSummary? {
  let keys = Set(t.panes.map(\.key))
  return r.sessions.first { s in s.window.map(keys.contains) ?? false }
}

/// How the profile filter names [profile]: nil is every profile, "" the default.
func profileLabel(_ profile: String?) -> String {
  switch profile {
  case nil: "All profiles"
  case "": "default"
  case let name?: name
  }
}

/// What a terminal's state is called when it says nothing more.
func termStateWord(_ s: TermState) -> String {
  switch s {
  case .ready: "ready"
  case .limited: "limited"
  case .setup: "needs setup on the computer"
  case .idle: "not running"
  case .missing: "not installed"
  }
}

/// Why [agent]'s windows show only as screens, from where PocketTerm stands in it ([integration], nil from a
/// computer that doesn't say) on [computer].
func screensOnly(_ agent: Agent, _ integration: AgentIntegration?, _ computer: String) -> String {
  let (name, app, command) =
    switch agent {
    case .omp: ("omp", "omp", "omp")
    case .claude: ("Claude", "Claude Code", "claude")
    }
  let mod = agent == .omp ? "extension" : "plugin"
  // What loads it in a session that's already open: Claude Code reloads in place, omp restarts on the conversation.
  let pickUp =
    switch agent {
    case .omp: "restart omp there (\(agent.resume) keeps the conversation)"
    case .claude: "type \(agent.pickUp) in these sessions (nothing restarts)"
    }
  switch integration {
  case .missing:
    return "PocketTerm isn\u{2019}t installed in \(app) on \(computer). On the computer: PocketTerm Settings → Install, "
      + "then \(pickUp)."
  case .installed:
    switch agent {
    case .omp:
      return "These omp sessions started before PocketTerm was installed in omp. Quit omp in them and run "
        + "\(agent.resume) to see them here as conversations."
    case .claude:
      return "These Claude sessions started before PocketTerm was installed in Claude Code. Type \(agent.pickUp) "
        + "in them (nothing restarts) to see them here as conversations."
    }
  case .outdated:
    return "PocketTerm in \(app) is out of date on \(computer). On the computer: PocketTerm Settings → Update, then "
      + "\(pickUp)."
  case .off:
    return "\(app) on \(computer) has mods turned off, so PocketTerm\u{2019}s \(mod) doesn\u{2019}t run. There: run "
      + "\(command) /login, start \(command) once, then \(pickUp)."
  case nil:
    return "These \(name) windows show only as screens: PocketTerm\u{2019}s \(app) \(mod) isn\u{2019}t reporting from "
      + "them. It may be out of date (update it in PocketTerm\u{2019}s Settings on the computer), or \(name) there "
      + "started before it was installed. Then \(pickUp) to see it above, as a conversation."
  }
}

/// The hint over the windows: how many agent windows the phone can switch to the conversation view.
func switchHint(_ switchable: Int) -> String {
  switchable == 1
    ? "1 session shows only its screen. Tap it to switch it to the conversation view."
    : "\(switchable) sessions show only their screen. Tap one to switch it to the conversation view."
}

/// A folded project's one line: how many sessions, and what needs you or is working, so folding never hides a
/// question.
struct FoldedSummary: Equatable {
  let count: Int
  let asking: Int
  let working: Int

  init(_ sessions: [LiveSummary]) {
    count = sessions.count
    asking = sessions.filter { $0.ask != nil }.count
    working = sessions.filter { $0.busy && $0.ask == nil }.count
  }

  var sessionsText: String { "\(count) session\(count == 1 ? "" : "s")" }
  var askingText: String? { asking == 0 ? nil : " · \(asking == 1 ? "1 needs" : "\(asking) need") you" }
  var workingText: String? { working == 0 ? nil : " · \(working) working" }
}

/// What the New session sheet lists for [query]: General (the home folder) unless the search is for something else,
/// the folder typed as a path, the folders windows are open in, then the computer's other projects.
struct NewSessionPlaces: Equatable {
  /// General shows.
  let general: Bool
  /// The folder typed as a path, if one is (not General's).
  let typed: String?
  let places: [String]
  /// The folders windows are open in.
  let open: Set<String>
  /// The computer has Project folders, none of them set.
  let noRoots: Bool
  /// Nothing to pick and nowhere to make a project: the sheet says where to add a Project folder.
  let noRootsHint: Bool

  init(_ remote: TerminalRemote, query: String) {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    var openOrdered: [String] = []
    for w in remote.windows where !openOrdered.contains(w.cwd) { openOrdered.append(w.cwd) }
    let open = Set(openOrdered)
    let home = remote.home
    // General stands for the home folder; it gives way only to a search for something else.
    general = !home.isEmpty && words.allSatisfy { "general ~".contains($0) }
    places = (openOrdered.filter { !$0.isEmpty && $0 != home } + remote.projects.filter { !open.contains($0) && $0 != home })
      .filter { p in
        let short = shortPath(remote, p).lowercased()
        return words.allSatisfy { short.contains($0) }
      }
    let t = typedPath(query, home: home)
    typed = general && t == home ? nil : t
    self.open = open
    // nil roots: a computer that predates Project folders, and can't make a project.
    noRoots = remote.roots?.isEmpty ?? false
    noRootsHint = remote.online && noRoots && places.isEmpty && typed == nil
  }
}
