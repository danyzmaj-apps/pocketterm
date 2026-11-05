#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// `Terminals.tieGhostty`'s answer: Ghostty window key → the tty of the tmux
/// client it runs, and what was left that it couldn't tell apart.
public struct TieGhostty: Sendable, Hashable {
  public var ttys: [String: String]
  public var untold: String
  public init(ttys: [String: String], untold: String) {
    self.ttys = ttys
    self.untold = untold
  }
}

/// Every terminal on this Mac as one (TerminalModel.swift): their windows
/// merged (a terminal window showing tmux gives way to the tmux pane, which
/// can do more), each request routed to the window's own terminal, and new
/// windows opened where the person works. A host left out is nil.
public final class Terminals: @unchecked Sendable {
  /// The home folder, which the phone shows as ~.
  public let home: String
  public let kitty: Kitty?
  public let tmux: Tmux?
  public let wezterm: WezTerm?
  public let iterm: ITerm2?
  public let ghostty: Ghostty?

  /// App names, most recently used first (`lsappinfo`); tests pass their own.
  public let recency: @Sendable () async -> [String]

  /// The Mac's processes now (`ps`); tests pass their own.
  public let snapshot: @Sendable () async -> Procs

  private struct State {
    /// Terminal windows PocketTerm opened to show a tmux session: their key → the
    /// pane's (Ghostty tells no tty to match them by).
    var shows: [String: String] = [:]
    var problems: [String: String] = [:]
    /// What `tieGhostty` couldn't tell apart, as logged (once each).
    var untold: Set<String> = []
  }

  private let state = Guarded(State())

  public init(
    home: String, kitty: Kitty? = nil, tmux: Tmux? = nil, wezterm: WezTerm? = nil, iterm: ITerm2? = nil,
    ghostty: Ghostty? = nil, recency: @escaping @Sendable () async -> [String] = appsByRecency,
    snapshot: @escaping @Sendable () async -> Procs = Procs.snapshot
  ) {
    self.home = home
    self.kitty = kitty
    self.tmux = tmux
    self.wezterm = wezterm
    self.iterm = iterm
    self.ghostty = ghostty
    self.recency = recency
    self.snapshot = snapshot
  }

  /// The terminals of this Mac: all five (kitty's sockets in `kittyDir`).
  public static func standard(kittyDir: String = "/tmp", home: String? = nil) -> Terminals {
    let h = home ?? homeDir()
    return Terminals(
      home: h, kitty: Kitty(home: h, socketDir: kittyDir), tmux: Tmux(), wezterm: WezTerm(home: h), iterm: ITerm2(),
      ghostty: Ghostty())
  }

  /// In the order their windows are listed.
  public var hosts: [TerminalHost] {
    [kitty as TerminalHost?, tmux, wezterm, iterm, ghostty].compactMap { $0 }
  }

  /// The terminal apps (tmux isn't one), in the order Auto prefers them
  /// when none was used lately.
  public var apps: [TerminalHost] { [kitty as TerminalHost?, wezterm, iterm, ghostty].compactMap { $0 } }

  /// What each terminal said went wrong on the last `windows`, by id.
  public var problems: [String: String] { state.get.problems }

  public func hostOf(_ key: String) -> TerminalHost? { hosts.first { $0.owns(key) } }

  private func host(_ key: String) throws -> TerminalHost {
    guard let h = hostOf(key) else { throw TerminalException("That window is gone.") }
    return h
  }

  /// What window `key`'s terminal can do.
  public func capsOf(_ key: String) -> Set<TermCap> { hostOf(key)?.caps ?? [] }

  public func can(_ key: String, _ cap: TermCap) -> Bool { capsOf(key).contains(cap) }

  /// Every window of every terminal. A terminal window attached to tmux is
  /// left out for its tmux pane, which names it as `TermWindow.via`; a
  /// Ghostty window, which tells no tty, once `tieGhostty` tells which
  /// tmux client it runs (its tty is then remembered). An omp window with a
  /// tty carries the profile its command line names (`TermWindow.profile`).
  public func windows() async -> [TermWindow] {
    let procs = await snapshot()
    let hosts = hosts
    let results = await withTaskGroup(of: (Int, [TermWindow], String?).self) { group in
      for (i, h) in hosts.enumerated() {
        group.addTask {
          do {
            return (i, try await h.windows(procs), nil)
          } catch {
            return (i, [], (error as? TerminalException)?.message ?? "\(error)")
          }
        }
      }
      var out = [(Int, [TermWindow], String?)]()
      for await r in group { out.append(r) }
      return out.sorted { $0.0 < $1.0 }
    }
    let lists = results.map(\.1)
    var problems: [String: String] = [:]
    for (i, _, problem) in results { if let problem { problems[hosts[i].id] = problem } }
    state.with { $0.problems = problems }
    let clients = tmux?.clients ?? [:]
    var shows = state.get.shows
    if let ghostty, !clients.isEmpty, let g = hosts.firstIndex(where: { $0 === ghostty }),
      let t = hosts.firstIndex(where: { $0 === tmux })
    {
      let windows = lists[g]
      if windows.contains(where: { $0.tty.isEmpty }) {
        let tie = Self.tieGhostty(
          windows: windows, clients: clients, surfaces: ghostty.surfaceTtys(procs), panes: lists[t])
        for (window, tty) in tie.ttys {
          ghostty.learn(window, tty)
          shows[window] = clients[tty]!.pane
        }
        if !tie.untold.isEmpty && state.with({ $0.untold.insert(tie.untold).inserted }) {
          debugLog("PocketTerm: Ghostty windows in tmux not told apart, listed apart: \(tie.untold)")
        }
      }
    }
    let panes = clients.mapValues(\.pane)
    return Self.merge(hosts, lists, panes, shows).map { w in
      w.agent == .omp && !w.tty.isEmpty ? w.copyWith(profile: ompProfileOfArgs(procs.foreground(w.tty)?.args ?? "")) : w
    }
  }

  /// Which tmux client each of Ghostty's `windows` whose tty it doesn't
  /// tell runs (a window the person opened, its command tmux): of the
  /// `clients` on Ghostty's terminals (`surfaces`) not known as another
  /// window's, the one giving that window its title (tmux's `set-titles`,
  /// which PocketTerm's Ghostty line turns on, the session named in it);
  /// else, when every such terminal runs a client, the one whose pane
  /// (`panes`) is in the window's folder; else the one left when one window
  /// and one terminal are. Only a match that's the only one either way
  /// counts: `ttys`, window key → the client's tty. `untold`: the windows
  /// and clients left that might belong together (empty: none).
  public static func tieGhostty(
    windows: [TermWindow], clients: [String: TmuxClient], surfaces: Set<String>, panes: [TermWindow]
  ) -> TieGhostty {
    var open = windows.filter { $0.tty.isEmpty }
    // Each window whose tty isn't known on one of these.
    var free = surfaces.subtracting(windows.map(\.tty))
    // In tty order, so what's tied and what's said is the same each time.
    var on = clients.filter { free.contains($0.key) }.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
      .map { (tty: $0.key, client: $0.value) }
    var ttys: [String: String] = [:]
    func tieWhere(_ match: (TermWindow, TmuxClient) -> Bool) {
      for (tty, c) in on {
        let ws = open.filter { match($0, c) }
        if ws.count != 1 { continue }
        let w = ws[0]
        if on.filter({ match(w, $0.client) }).count != 1 { continue }
        ttys[w.key] = tty
        open.removeAll { $0 == w }
        free.remove(tty)
        on.removeAll { $0.tty == tty }
      }
    }

    tieWhere { w, c in !c.title.isEmpty && w.title == c.title }
    // A window running no tmux may be in any folder.
    if on.count == free.count {
      var cwds: [String: String] = [:]
      for pane in panes { cwds[pane.key] = pane.cwd }
      tieWhere { w, c in sameFolder(w.cwd, cwds[c.pane] ?? "") }
    }
    if open.count == 1 && free.count == 1, let tty = free.first, on.contains(where: { $0.tty == tty }) {
      ttys[open[0].key] = tty
      open.removeAll()
      on.removeAll()
    }
    let untold =
      open.isEmpty || on.isEmpty
      ? "" : "\(open.map(\.key).joined(separator: ", ")) / \(on.map(\.tty).joined(separator: ", "))"
    return TieGhostty(ttys: ttys, untold: untold)
  }

  /// Whether `a` and `b` are one folder as a terminal and tmux tell it
  /// (`/private/tmp` is `/tmp`); never for an empty one.
  static func sameFolder(_ a: String, _ b: String) -> Bool {
    !a.isEmpty && !b.isEmpty
      && (Paths.equals(a, b) || Paths.equals("/private\(a)", b) || Paths.equals(a, "/private\(b)"))
  }

  /// `lists` (one per host of `hosts`) as one list: a window whose tty is a
  /// tmux client's in `clients` (tty → pane key), or which `shows` a pane,
  /// gives way to that pane's tmux session: its panes take the window's
  /// place in the list, its app window and tab (`TermWindow.osWindow`,
  /// `TermWindow.tabId`: where they are on screen) and its app's label as
  /// `via`. A session two windows show goes where the first one is.
  public static func merge(
    _ hosts: [TerminalHost], _ lists: [[TermWindow]], _ clients: [String: String], _ shows: [String: String]
  ) -> [TermWindow] {
    let tmuxAt = hosts.firstIndex { $0.id == "tmux" }
    let panes = tmuxAt.map { lists[$0] } ?? []
    var paneByKey: [String: TermWindow] = [:]
    for w in panes { paneByKey[w.key] = w }
    // A pane's tmux session (its osWindow) when tmux tells it, else just the pane.
    func session(_ pane: TermWindow) -> String { pane.osWindow.isEmpty ? pane.key : pane.osWindow }
    // Each session's panes, in tmux's order.
    var bySession: [String: [TermWindow]] = [:]
    for w in panes { bySession[session(w), default: []].append(w) }
    func shown(_ host: Int, _ w: TermWindow) -> String? {
      hosts[host].id == "tmux" ? nil : (shows[w.key] ?? (w.tty.isEmpty ? nil : clients[w.tty]))
    }
    // The sessions an app window shows: their panes go there, not where tmux lists them.
    var shownSessions = Set<String>()
    for (i, list) in lists.enumerated() {
      for w in list {
        if let pane = shown(i, w), let p = paneByKey[pane] { shownSessions.insert(session(p)) }
      }
    }
    var out: [TermWindow] = []
    var placed = Set<String>()
    for (i, list) in lists.enumerated() {
      let host = hosts[i]
      for w in list {
        if i == tmuxAt {
          if !shownSessions.contains(session(w)) { out.append(w) }
          continue
        }
        guard let pane = shown(i, w) else {
          out.append(w)
          continue
        }
        // Its pane gone from tmux's list meanwhile: neither shows.
        guard let p = paneByKey[pane], placed.insert(session(p)).inserted else { continue }
        for s in bySession[session(p)]! {
          out.append(
            s.copyWith(
              via: host.label, osWindow: w.osWindow.isEmpty ? nil : w.osWindow, tabId: w.tabId.isEmpty ? nil : w.tabId))
        }
      }
    }
    return out
  }

  /// How each installed terminal stands, for Settings and the phone. A
  /// limited terminal whose phone sessions run in tmux (`viaTmux`) is ready
  /// for those; its limit stays, for the windows opened in it directly.
  public func statuses() async -> [TermStatus] {
    let procs = await snapshot()
    let hosts = hosts
    return await withTaskGroup(of: (Int, TermStatus).self) { group in
      for (i, h) in hosts.enumerated() {
        group.addTask { [self] in
          do {
            let s = try await h.status(procs)
            guard s.state == .limited && viaTmux(h) else { return (i, s) }
            let note = dartTrim(
              "\(dartTrim(dartReplaceFirst(s.note, h.limits, ""))) Sessions from your phone run in tmux, "
                + "with full control. In windows you open yourself: \(h.limits)")
            return (i, TermStatus(s.id, s.label, .ready, note: note, fix: s.fix))
          } catch {
            return (i, TermStatus(h.id, h.label, .limited, note: (error as? TerminalException)?.message ?? "\(error)"))
          }
        }
      }
      var out = [(Int, TermStatus)]()
      for await r in group { out.append(r) }
      return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  /// Where an agent runs, from the `term` its extension reports
  /// (`windowOfTerm`); for Ghostty, which tells nothing to match, the window
  /// PocketTerm opened on the agent's tty, else the Ghostty window in the
  /// agent's folder `cwd` its session (`title`, `agent`) is in, of those not
  /// `claimed` by other sessions (`Ghostty.byFolder`; then its tty is
  /// remembered).
  public func locate(
    _ term: JSONObject?, cwd: String = "", title: String = "", agent: Agent = .omp, claimed: Set<String> = []
  ) async -> String? {
    guard let term else { return nil }
    if let socket = term["TMUX"]?.string, !socket.isEmpty { tmux?.learn(socket.components(separatedBy: ",")[0]) }
    if let key = windowOfTerm(term) { return key }
    guard let ghostty, term["TERM_PROGRAM"]?.string == "ghostty" else { return nil }
    let tty = term["tty"]?.string ?? ""
    if !tty.isEmpty, let known = ghostty.byTty(tty) { return known }
    let found = await ghostty.byFolder(cwd, await snapshot(), tty: tty, title: title, agent: agent, claimed: claimed)
    if let found, !tty.isEmpty { ghostty.learn(found, tty) }
    return found
  }

  // ------------------------------------------------------------ requests

  public func lines(_ key: String, history: Bool = false) async throws -> [String] {
    try await host(key).lines(key, history: history)
  }

  public func plainScreen(_ key: String) async throws -> String { try await host(key).plainScreen(key) }

  public func colors(_ key: String) async throws -> JSONObject? { try await host(key).colors(key) }

  public func send(_ key: String, _ text: String, enter: Bool) async throws {
    try await host(key).send(key, text, enter: enter)
  }

  public func type(_ key: String, _ text: String) async throws { try await host(key).type(key, text) }

  public func pressKeys(_ key: String, _ names: [String]) async throws { try await host(key).pressKeys(key, names) }

  /// One of `phoneKeys` (what the phone may press).
  public func press(_ key: String, _ name: String) async throws {
    if !phoneKeys.contains(name) { throw TerminalException("Unknown key: \(name)") }
    try await pressKeys(key, [name])
  }

  /// Closes window `key`; for a tmux pane a terminal window shows (one
  /// PocketTerm opened to show it, or a Ghostty window tied to its client),
  /// that window too keeping the focus where it is (Ghostty comes to the
  /// front as it closes it).
  public func close(_ key: String) async throws {
    var guis: [String] = []
    for (gui, pane) in state.get.shows where pane == key && !guis.contains(gui) { guis.append(gui) }
    for (tty, c) in tmux?.clients ?? [:] where c.pane == key {
      if let gui = ghostty?.byTty(tty), !guis.contains(gui) { guis.append(gui) }
    }
    if guis.isEmpty { return try await host(key).close(key) }
    try await keepFront(app: hostOf(guis[0])?.bundleId) {
      try await host(key).close(key)
      for gui in guis {
        _ = state.with { $0.shows.removeValue(forKey: gui) }
        do {
          try await host(gui).close(gui)
        } catch is TerminalException {
          // Already gone with its tmux (Ghostty closes it itself).
        }
      }
    }
  }

  // ------------------------------------------------------------ new windows

  /// The terminal app new windows open in: `choice` (an app's id) if it's
  /// installed; else (Auto) the running one used most recently; else the
  /// first installed of `apps`.
  public func opensIn(_ choice: String) async -> TerminalHost {
    let procs = await snapshot()
    var statuses: [String: TermStatus] = [:]
    for h in apps {
      statuses[h.id] = (try? await h.status(procs)) ?? TermStatus(h.id, h.label, .limited)
    }
    return Self.pickApp(apps, statuses, choice, await recency())
  }

  /// `opensIn`'s choice among `apps`, given their `statuses` and the apps by
  /// `recency`: a chosen app that's installed; else the usable one used
  /// last; else the first usable one; else the first that can be started
  /// (kitty can't be: it must listen first).
  public static func pickApp(
    _ apps: [TerminalHost], _ statuses: [String: TermStatus], _ choice: String, _ recency: [String]
  ) -> TerminalHost {
    if let chosen = apps.first(where: { $0.id == choice }), statuses[choice]?.state != .missing { return chosen }
    for name in recency {
      if let h = apps.first(where: { $0.appName == name }), statuses[h.id]?.usable ?? false { return h }
    }
    return apps.first { statuses[$0.id]?.usable ?? false }
      ?? apps.first { $0.id != "kitty" && statuses[$0.id]?.state == .idle }
      ?? apps.last!
  }

  /// Whether a window `host` opens runs in tmux: the app can't press keys
  /// or show its screen, and tmux can.
  public func viaTmux(_ host: TerminalHost) -> Bool {
    (tmux?.installed ?? false) && !(host.caps.contains(.keys) && host.caps.contains(.read))
  }

  /// How the phone names where a new session opens: "kitty", "Ghostty (in tmux)".
  public func describe(_ host: TerminalHost) -> String { viaTmux(host) ? "\(host.label) (in tmux)" : host.label }

  /// A new window in `cwd` in `host` running the login shell, which then
  /// starts `agent` if given, in omp `profile` ("" the default), with
  /// `flags` after its command: with `Placement.projectWindow` a tab in
  /// `host`'s window that holds `cwd`'s tabs (`projectWindow`). Its key (the
  /// tmux pane's, where `viaTmux`) and where it went, as the phone says it.
  public func launch(
    _ cwd: String, host: TerminalHost, agent: Agent? = nil, placement: Placement = .projectWindow,
    profile: String = "", flags: String = ""
  ) async throws -> Opened {
    if !directoryExists(cwd) { throw TerminalException("No such folder: \(cwd)") }
    let into = placement == .projectWindow ? Self.projectWindow(await windows(), host, cwd, home: home) : nil
    let key: String
    if viaTmux(host), let tmux {
      key = try await tmux.launch(cwd, command: nil, into: nil)
      do {
        let gui = try await host.launch(cwd, command: tmux.attach(tmux.lastSession!), into: into)
        state.with { $0.shows[gui] = key }
      } catch {
        try? await tmux.close(key)
        throw error
      }
    } else {
      key = try await host.launch(cwd, command: nil, into: into)
    }
    // The shell reads it once it's up: the terminal holds what's typed.
    if let agent {
      let command = agent.commandIn(profile)
      try await send(key, flags.isEmpty ? command : "\(command) \(flags)", enter: true)
    }
    let place =
      into == nil
      ? "a new \(host.label) window" : "a new tab in the \(host.label) window with \(Self.projectName(cwd, home: home))"
    return Opened(window: key, where: place)
  }

  /// How a project folder is named to the person: its folder's name, and
  /// General for the home folder (where a session about nothing in
  /// particular starts).
  public static func projectName(_ cwd: String, home: String) -> String {
    sameFolder(cwd, home) ? "General" : Paths.basename(cwd)
  }

  /// The window of `host` (its `TermWindow.osWindow`) whose tabs are most
  /// in `cwd` (in it or under it; the home folder only itself, as nearly
  /// everything is under it), of `windows`; the first such in the list on a
  /// tie; nil when no tab of `host`'s is there. A tmux pane counts for the
  /// app window showing it.
  public static func projectWindow(_ windows: [TermWindow], _ host: TerminalHost, _ cwd: String, home: String)
    -> String?
  {
    func inProject(_ dir: String) -> Bool { sameFolder(dir, cwd) || under(dir, cwd, home) }
    var order: [String] = []
    var tabs: [String: Set<String>] = [:]
    for w in windows {
      let mine = w.via.isEmpty ? w.app == host.id : w.via == host.label
      if !mine || w.osWindow.isEmpty || !inProject(w.cwd) { continue }
      if tabs[w.osWindow] == nil { order.append(w.osWindow) }
      tabs[w.osWindow, default: []].insert(w.tabId.isEmpty ? w.key : w.tabId)
    }
    var best: String?
    for window in order where best == nil || tabs[window]!.count > tabs[best!]!.count { best = window }
    return best
  }

  /// Whether `dir` is somewhere under `project` (not the home folder `home`).
  private static func under(_ dir: String, _ project: String, _ home: String) -> Bool {
    if sameFolder(project, home) || dir.isEmpty || project.isEmpty { return false }
    func bare(_ d: String) -> String { d.dartStartsWith("/private/") ? (d as NSString).substring(from: 8) : d }
    return Paths.isWithin(bare(project), bare(dir))
  }

  /// Git repositories up to three levels under `roots` (the Mac's Project
  /// folders setting), for the phone's New session list. A symlinked folder
  /// is followed (under the link's own path), each real folder once: a
  /// link loop, or two roots that are one folder, list nothing twice.
  public func projects(_ roots: [String]) async -> [String] {
    // Each repository by its real folder: under that path when it's found there too, else the first link to it.
    var found: [String: String] = [:]
    // Each real folder walked, with how deep it was walked from there.
    var seen: [String: Int] = [:]
    func walk(_ dir: String, _ depth: Int) {
      guard let real = realPath(dir) else { return }
      if dir == real && found[real] != nil { found[real] = real }
      if (seen[real] ?? -1) >= depth { return }
      seen[real] = depth
      guard let entries = listNames(dir) else { return }
      if entries.contains(".git") {
        found[real] = dir == real ? real : found[real] ?? dir
        return
      }
      if depth == 0 { return }
      for name in entries {
        if name.dartStartsWith(".") || name == "node_modules" { continue }
        let path = Paths.join(dir, name)
        let kind = fileKind(path)
        if kind == .directory || (kind == .link && fileKind(path, followLinks: true) == .directory) {
          walk(path, depth - 1)
        }
      }
    }

    for root in roots {
      let dir = (root as NSString).length > 1 && root.dartEndsWith("/") ? String(root.utf16.dropLast())! : root
      if directoryExists(dir) { walk(dir, 3) }
    }
    return Array(found.values).dartSorted()
  }

  private static let badName = TermRegex(#"[/\\:]"#)

  /// A new project folder `name` under `root`, which must be one of `roots`
  /// (the Mac's Project folders setting); its path. Only the folder is made.
  public func createProject(_ root: String, _ name: String, roots: [String]) throws -> String {
    if !roots.contains(root) { throw TerminalException("Not one of your project folders: \(root)") }
    let n = dartTrim(name)
    if n.isEmpty || Self.badName.hasMatch(n) || n.dartStartsWith(".") || n.utf16.contains(where: { $0 < 0x20 || $0 == 0x7f })
    {
      throw TerminalException(
        #"A project name can’t be empty, contain /, \, : or control characters, or start with a dot."#)
    }
    if !directoryExists(root) { throw TerminalException("No such folder: \(root)") }
    let path = Paths.join(root, n)
    if fileKind(path, followLinks: true) != .notFound {
      throw TerminalException("There is already something named \(n) there.")
    }
    if mkdir(path, 0o777) != 0 {
      throw TerminalException("Couldn’t create \(path): \(String(cString: strerror(errno)))")
    }
    return path
  }

  /// The phone's New project: `createProject`, then a window in it as
  /// `launch` (a window of its own: no tab is in a folder just made).
  /// Should no window open, the folder goes again (while still empty), so
  /// trying again with the same name works.
  public func launchNewProject(
    _ root: String, _ name: String, roots: [String], host: TerminalHost, agent: Agent? = nil, profile: String = ""
  ) async throws -> Opened {
    let cwd = try createProject(root, name, roots: roots)
    do {
      return try await launch(cwd, host: host, agent: agent, placement: .newWindow, profile: profile)
    } catch {
      // Something put in it meanwhile: it stays.
      rmdir(cwd)
      throw error
    }
  }
}
#endif
