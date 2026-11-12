import PocketTermKit
import SwiftUI

/// What the list remembers between its builds without them showing anything new: by activity, the projects' order as
/// last shown, kept until the list is pulled to refresh or the sort changes.
private final class ListMemory {
  var ranked: [String] = []
}

/// A row's own name being edited: [row] its key, [own] the name the computer gives it, [look] how it looks now.
struct RowEdit: Identifiable {
  let row: String
  let own: String
  let look: TileLook
  var id: String { row }
}

/// The home page's body: the computer's coding sessions by project, in a steady order, and its other terminal
/// windows. Tapping a project's heading folds it; its context menu offers a new session there and folding. Rows swipe
/// to Rename, Color and End session (Close window), and their context menu says where they sit on the computer.
struct TerminalList: View {
  @ObservedObject var home: HomeModel
  @ObservedObject var app: AppModel
  @ObservedObject var tips: TipsController
  @ObservedObject var remote: TerminalRemote

  /// The computer's name, for advice about it; nil says "the computer".
  let computer: String?

  @State private var memory = ListMemory()
  /// Pulled to refresh: the list builds again with the activity order ranked afresh.
  @State private var refreshed = 0
  /// The project a new session is starting in.
  @State private var launching: String?
  @State private var closing: TermWindow?
  @State private var renaming: RowEdit?
  @State private var coloring: RowEdit?
  @State private var layoutShown = false
  @State private var newSession = false

  @EnvironmentObject private var look: Appearance

  private var desktop: String { remote.desktopId }
  private var folded: Set<String> { app.collapsedProjects }
  private var sort: ProjectSort { app.projectSort }
  private var looks: [String: TileLook] { app.tileLooks(desktop) }

  // MARK: Building

  var body: some View {
    // Read so a refresh builds the list again, ranked afresh.
    let _ = refreshed
    let model = ListModel(remote, app: app, ranked: memory.ranked)
    if sort == .activity { memory.ranked = model.groups.map(\.cwd) }
    let looks = self.looks
    return List {
      if model.sessions.isEmpty && model.windows.isEmpty { emptyRows }
      if !model.layout.isEmpty || model.groups.count > 1 || model.showFilter { controls(model) }
      if let filter = model.filter, model.groups.isEmpty, !model.sessions.isEmpty {
        Section {
          VStack(spacing: 8) {
            Text("No sessions from \(profileLabel(filter)) here.")
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
            Button("Show all") { app.setProfileFilter(desktop, nil) }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("profile-filter-show-all")
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .listRowBackground(Color.clear)
          .accessibilityIdentifier("profile-filter-empty")
        }
      }
      ForEach(Array(model.groups.enumerated()), id: \.element.cwd) { i, g in
        project(g, projects: model.groups.count, first: i == 0, model: model, looks: looks)
      }
      if !model.windows.isEmpty { windowsSection(model, looks: looks) }
    }
    .listStyle(.insetGrouped)
    .animation(.snappy, value: model.rowKeys)
    .refreshable {
      memory.ranked = []
      remote.hello()
      try? await Task.sleep(for: .milliseconds(600))
      refreshed += 1
    }
    .safeAreaInset(edge: .top, spacing: 0) { LinkNoteBar(remote: remote) }
    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    .closeConfirmation(remote: remote, window: $closing)
    .sheet(item: $renaming) { edit in
      RenameSheet(edit: edit) { name in setLook(edit.row, edit.look.withName(name == edit.own ? nil : name)) }
        .toasts()
    }
    .sheet(item: $coloring) { edit in
      ColorSheet(current: edit.look.color) { color in setLook(edit.row, edit.look.withColor(color)) }
        .toasts()
    }
    .sheet(isPresented: $layoutShown) {
      LayoutSheet(remote: remote) { session, window in
        layoutShown = false
        if let session { home.openSession(session) } else { home.openWindow(window) }
      }
      .themed(appearance)
      .toasts()
    }
    .sheet(isPresented: $newSession) {
      NewSessionSheet(remote: remote, app: app) { opened, agent in
        newSession = false
        home.opened(opened, agent: agent)
      }
      .themed(appearance)
      .toasts()
    }
  }

  /// At the bottom: the orchestrator's bar, and + for a new session beside it.
  private var bottomBar: some View {
    HStack(alignment: .bottom, spacing: 12) {
      OrchestratorBar(home: home, remote: remote)
        .frame(maxWidth: .infinity)
      Button {
        newSession = true
      } label: {
        Image(systemName: "plus")
          .font(.title2.weight(.semibold))
          .frame(width: 52, height: 52)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.circle)
      .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
      .accessibilityLabel("New session")
      .accessibilityIdentifier("add")
      .appTip(.newSession)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }

  // MARK: Controls

  /// Above the projects, on one line: how many app windows and tabs the computer has open (when it says where its
  /// terminals sit); which omp profile's sessions show (when the computer has more than the default) and how the
  /// projects are ordered (when there are some to order).
  private func controls(_ model: ListModel) -> some View {
    Section {
      HStack(spacing: 4) {
        if !model.layout.isEmpty {
          Button {
            layoutShown = true
          } label: {
            Label(layoutCount(model.layout), systemImage: "macwindow.on.rectangle")
              .lineLimit(1)
          }
          .accessibilityHint("Shows the windows and tabs open on \(computer ?? "the computer")")
          .accessibilityIdentifier("layout-summary")
        }
        Spacer(minLength: 8)
        if model.showFilter {
          Menu {
            Picker(
              "Show sessions from",
              selection: Binding(get: { model.filter }, set: { app.setProfileFilter(desktop, $0) })
            ) {
              Text(profileLabel(nil)).tag(String?.none)
                .accessibilityIdentifier("profile-filter-all")
              Text(profileLabel("")).tag(String?.some(""))
                .accessibilityIdentifier("profile-filter-default")
              ForEach(model.profiles, id: \.self) { name in
                Text(name).tag(String?.some(name))
                  .accessibilityIdentifier("profile-filter-\(name)")
              }
            }
            .pickerStyle(.inline)
          } label: {
            Label(profileLabel(model.filter), systemImage: "line.3.horizontal.decrease.circle")
              .lineLimit(1)
          }
          .accessibilityLabel(profileLabel(model.filter))
          .accessibilityHint("Show sessions from: picks the omp profile whose sessions show")
          .accessibilityIdentifier("profile-filter")
        }
        if model.groups.count > 1 {
          Menu {
            Picker(
              "Sort projects",
              selection: Binding(get: { sort }, set: { setSort($0) })
            ) {
              ForEach(ProjectSort.allCases, id: \.self) { s in
                Text(s.label).tag(s).accessibilityIdentifier("project-sort-\(s.rawValue)")
              }
            }
            .pickerStyle(.inline)
          } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
              .lineLimit(1)
          }
          .accessibilityLabel(sort.label)
          .accessibilityHint("Sort projects")
          .accessibilityIdentifier("project-sort")
        }
      }
      .font(.footnote)
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
    .listSectionSpacing(.compact)
  }

  private func setSort(_ s: ProjectSort) {
    if s == sort { return }
    memory.ranked = []
    withAnimation(.snappy) { app.setProjectSort(s) }
  }

  // MARK: Projects

  /// A project's sessions under its name. Tapping the name folds it to one summary row; its context menu offers a
  /// new session there and folding.
  private func project(
    _ g: SessionGroup, projects: Int, first: Bool, model: ListModel, looks: [String: TileLook]
  ) -> some View {
    let isFolded = folded.contains(g.cwd)
    return Section {
      if isFolded {
        summary(g)
      } else {
        ForEach(g.sessions, id: \.key) { s in
          sessionRow(s, model: model, look: looks[s.key] ?? TileLook())
        }
      }
    } header: {
      HStack(spacing: 6) {
        Button {
          fold(g.cwd)
        } label: {
          HStack(spacing: 6) {
            Text(projectName(remote, g.cwd))
              .lineLimit(1)
            Image(systemName: "chevron.down")
              .font(.caption2.weight(.semibold))
              .rotationEffect(.degrees(isFolded ? -90 : 0))
              .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isFolded ? "Folded" : "")
        .accessibilityHint(isFolded ? "Unfolds it" : "Folds it")
        .accessibilityIdentifier("project-\(g.cwd)")
        if launching == g.cwd {
          ProgressView()
            .controlSize(.small)
            .accessibilityIdentifier("project-launching-\(g.cwd)")
        }
        // Its actions in a menu of their own: in a list's section header a context menu never shows (the long
        // press opened the first row's menu, or ended as a tap that folded the project).
        Menu {
          projectMenu(g.cwd, projects: projects)
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.body)
            .frame(minWidth: 32, minHeight: 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(projectName(remote, g.cwd)) actions")
        .accessibilityIdentifier("project-actions-\(g.cwd)")
      }
      .appTip(.projectHeading, enabled: first)
    }
  }

  private func setFolded(_ cwds: Set<String>) {
    withAnimation(.snappy) { app.setCollapsedProjects(cwds) }
  }

  private func fold(_ cwd: String) {
    Haptics.picked()
    var f = folded
    if f.remove(cwd) == nil { f.insert(cwd) }
    setFolded(f)
  }

  /// A folded project's one row: how many sessions, and what needs you or is working, so folding never hides a
  /// question.
  private func summary(_ g: SessionGroup) -> some View {
    let s = FoldedSummary(g.sessions)
    let color: Color = s.asking > 0 ? .orange : s.working > 0 ? look.theme.tint : .secondary
    var line = Text(s.sessionsText)
    if let asking = s.askingText { line = line + Text(asking).foregroundStyle(Color.orange) }
    if let working = s.workingText { line = line + Text(working).foregroundStyle(look.theme.tint) }
    return Button {
      fold(g.cwd)
    } label: {
      Label {
        line.foregroundStyle(.secondary).lineLimit(1)
      } icon: {
        Image(systemName: "sparkles").foregroundStyle(color)
      }
    }
    .tint(.primary)
    .accessibilityHint("Unfolds it")
    .accessibilityIdentifier("project-summary-\(g.cwd)")
  }

  /// What a project heading's context menu offers: a new session there, folding it, and folding the others.
  @ViewBuilder
  private func projectMenu(_ cwd: String, projects: Int) -> some View {
    let isFolded = folded.contains(cwd)
    let others = projects > 1
    Section(cwd.isEmpty ? projectName(remote, cwd) : shortPath(remote, cwd)) {
      // Somewhere unknown has nowhere to start one.
      if !cwd.isEmpty {
        Button {
          launchHere(cwd)
        } label: {
          Label("New \(remote.agent.labelIn(newProfile())) session here", systemImage: "plus")
        }
        .disabled(!remote.online || launching != nil)
        .accessibilityIdentifier("project-menu-new")
      }
      Button {
        fold(cwd)
      } label: {
        Label(isFolded ? "Unfold" : "Fold", systemImage: isFolded ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
      }
      .accessibilityIdentifier("project-menu-fold")
      if others {
        Button {
          var f = folded.union(remote.sessions.map(\.cwd))
          f.remove(cwd)
          setFolded(f)
        } label: {
          Label("Fold all others", systemImage: "arrow.down.and.line.horizontal.and.arrow.up")
        }
        .accessibilityIdentifier("project-menu-fold-others")
      }
      if others && !folded.isEmpty {
        Button {
          setFolded([])
        } label: {
          Label("Unfold all", systemImage: "arrow.up.and.line.horizontal.and.arrow.down")
        }
        .accessibilityIdentifier("project-menu-unfold-all")
      }
    }
  }

  /// The omp profile a session started here runs in: the New session sheet's last pick, while the computer still has
  /// it.
  private func newProfile() -> String {
    let profile = app.newSessionProfile(desktop)
    return remote.agent == .omp && remote.profiles.contains(profile) ? profile : ""
  }

  /// Starts the agent in a new window in [cwd], opens its session and says where it opened.
  private func launchHere(_ cwd: String) {
    guard launching == nil else { return }
    launching = cwd
    let remote = remote
    let home = home
    let profile = newProfile()
    Task {
      defer { launching = nil }
      do {
        let opened = try await remote.launch(cwd, startAgent: true, profile: profile)
        home.app.analytics.event("session_started", ["kind": .string("agent"), "project": .string("existing")])
        // Still this computer's list: its session opens (and says where), even if the list was left meanwhile.
        if home.remote === remote { home.opened(opened, agent: true) }
      } catch {
        Haptics.failed()
        Toaster.shared.show(errorText(error))
      }
    }
  }

  // MARK: Rows

  /// A session's row; its project is the heading above it.
  private func sessionRow(_ s: LiveSummary, model: ListModel, look tile: TileLook) -> some View {
    let own = s.title.isEmpty ? s.agent.label : s.title
    let title = tile.name ?? own
    let w = s.window.flatMap(remote.window)
    let state = Finished.shared.state(s)
    let words = sessionState(s)
    let facts = sessionFacts(s)
    let value = [state.label, words, facts].filter { !$0.isEmpty }.joined(separator: ", ")
    let switchDone = s.window != nil && s.window == tips.switchedWindow
    let row = Button {
      home.openSession(s.key)
    } label: {
      SessionRowLabel(
        key: s.key, title: title, state: state, words: words, facts: facts, badge: w.map(termBadge), ctx: s.ctx)
    }
    .tint(.primary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier("session-\(s.key)")
    return
      row
      .listRowBackground(rowBackground(tile))
      .rowActions(row: s.key, own: own, look: tile, window: w, list: self)
      .appTip(.switchDone, enabled: switchDone)
      .appTip(.swipeRow, enabled: s.key == model.swipeTipRow)
  }

  /// The other windows: those no live session claims, under a hint when some show only their screen.
  @ViewBuilder
  private func windowsSection(_ model: ListModel, looks: [String: TileLook]) -> some View {
    Section {
      ForEach(model.windows, id: \.key) { w in
        windowRow(w, model: model, look: looks[w.key] ?? TileLook())
      }
    } header: {
      Text(model.sessions.isEmpty ? "Windows" : "Other windows")
        .accessibilityIdentifier("windows-heading")
    } footer: {
      let hints = windowHints(model)
      if !hints.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(hints, id: \.id) { hint in
            Text(hint.text).accessibilityIdentifier(hint.id)
          }
        }
      }
    }
  }

  /// What the windows' footer says: how many agent windows switch to the conversation view, and why an agent's
  /// others show only as screens (its PocketTerm integration doesn't report: out of date, or installed after it
  /// started in a window the phone can't switch).
  private func windowHints(_ model: ListModel) -> [WindowsHint] {
    var hints: [WindowsHint] = []
    if model.switchable > 0 { hints.append(WindowsHint(id: "switch-tip", text: switchHint(model.switchable))) }
    for agent in Agent.allCases where model.windows.contains(where: { $0.agent == agent && !canSwitch(remote, $0) }) {
      let text = screensOnly(agent, remote.agents[agent], computer ?? "the computer")
      hints.append(WindowsHint(id: "\(agent.command)-screens-only", text: text))
    }
    return hints
  }

  /// A window's row.
  private func windowRow(_ w: TermWindow, model: ListModel, look tile: TileLook) -> some View {
    let own = w.title.isEmpty ? w.program : w.title
    let title = tile.name ?? own
    let detail = "\(w.profile.isEmpty ? w.program : "\(w.program) · \(w.profile)") · \(shortPath(remote, w.cwd))"
    // The rows here are the windows no live session claims: an agent's shows only as a screen.
    let screenOnly = w.agent != nil
    let badge = termBadge(w)
    let value = ([screenOnly ? "Screen only" : nil, badge, detail] as [String?]).compactMap { $0 }
      .joined(separator: ", ")
    let row = Button {
      home.openWindow(w.key)
    } label: {
      WindowRowLabel(window: w, title: title, badge: badge, detail: detail, screenOnly: screenOnly)
    }
    .tint(.primary)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier("term-\(w.key)")
    return
      row
      .listRowBackground(rowBackground(tile))
      .rowActions(row: w.key, own: own, look: tile, window: w, list: self)
      .appTip(.switchOpen, enabled: w.key == model.switchTipRow)
      .appTip(.swipeRow, enabled: w.key == model.swipeTipRow)
  }

  /// The row's background: the list's own, tinted in the person's colour when they gave it one.
  private func rowBackground(_ tile: TileLook) -> some View {
    ZStack {
      Color(.secondarySystemGroupedBackground)
      if let c = tile.color { argbColor(c).opacity(0.22) }
    }
    .animation(.smooth, value: tile.color)
  }

  fileprivate func rename(_ row: String, own: String, look: TileLook) {
    renaming = RowEdit(row: row, own: own, look: look)
  }

  fileprivate func recolor(_ row: String, own: String, look: TileLook) {
    coloring = RowEdit(row: row, own: own, look: look)
  }

  fileprivate func close(_ w: TermWindow) {
    Haptics.held()
    closing = w
  }

  fileprivate var online: Bool { remote.online }

  fileprivate func place(_ w: TermWindow) -> String? {
    macPlaces(macLayout(remote.windows, terminals: remote.terminals))[w.key]
  }

  private func setLook(_ row: String, _ tile: TileLook) {
    var all = looks
    if tile.name == nil && tile.color == nil { all[row] = nil } else { all[row] = tile }
    withAnimation(.smooth) { app.setTileLooks(desktop, all) }
  }

  // MARK: Nothing runs

  /// Nothing runs: where a new session opens, and what each terminal that isn't ready needs (tmux: when it isn't
  /// installed).
  @ViewBuilder
  private var emptyRows: some View {
    let online = remote.online
    let unready = remote.terminals.filter { $0.state != .ready && ($0.state != .missing || $0.id == "tmux") }
    let hint = online && remote.error == nil
    if hint || (online && !unready.isEmpty) {
      Section {
        VStack(spacing: 12) {
          if hint {
            Text("Nothing runs in \(remote.opensIn ?? "your terminal"). Tap + to start \(remote.agent.label).")
              .foregroundStyle(.secondary)
          }
          if online {
            ForEach(unready, id: \.id) { t in
              Text("\(t.label): \(t.note.isEmpty ? termStateWord(t.state) : t.note)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("terminal-\(t.id)")
            }
          }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
      }
    }
  }
}

/// What the list shows, worked out once per build from the computer's state and the person's choices.
private struct ListModel {
  /// The sessions, but the orchestrator's: it has its own bar, not a place in the list (its window is still
  /// claimed).
  let sessions: [LiveSummary]
  /// The omp profiles besides the default, sorted.
  let profiles: [String]
  let showFilter: Bool
  /// The profile whose sessions show; nil for all.
  let filter: String?
  let groups: [SessionGroup]
  let layout: [MacWindow]
  /// The windows no live session claims.
  let windows: [TermWindow]
  /// Agent windows the phone can switch to the conversation view.
  let switchable: Int
  /// The rows that carry the switch tour's first tip and the swipe tip: the first that can.
  let switchTipRow: String?
  let swipeTipRow: String?
  let rowKeys: [String]

  @MainActor
  init(_ remote: TerminalRemote, app: AppModel, ranked: [String]) {
    let sessions = remote.sessions.filter { !$0.orchestrator }
    self.sessions = sessions
    // The omp profiles there are: the default, the computer's, and any a session runs in.
    let known = Set([""] + remote.profiles + sessions.map(\.profile))
    let showFilter = known.count > 1
    self.showFilter = showFilter
    profiles = known.filter { !$0.isEmpty }.sorted()
    // A profile no longer there reads as all of them; the kept choice stays for when it's back.
    let kept = app.profileFilter(remote.desktopId)
    let filter = showFilter && kept.map(known.contains) == true ? kept : nil
    self.filter = filter
    let visible = filter.map { f in sessions.filter { $0.profile == f } } ?? sessions
    let groups = groupedSessions(visible, app.projectSort, ranked: ranked, home: remote.home)
    self.groups = groups
    let claimed = Set(remote.sessions.compactMap(\.window))
    layout = macLayout(remote.windows, terminals: remote.terminals)
    let windows = remote.windows.filter { !claimed.contains($0.key) }
    self.windows = windows
    let canSwitchRows = windows.filter { canSwitch(remote, $0) }
    switchable = canSwitchRows.count
    switchTipRow = canSwitchRows.first?.key
    func closes(_ window: String?) -> Bool { window.flatMap(remote.window)?.can(.close) ?? false }
    let folded = app.collapsedProjects
    swipeTipRow =
      groups.lazy.filter { !folded.contains($0.cwd) }.flatMap(\.sessions).first { closes($0.window) }?.key
      ?? windows.first { closes($0.key) }?.key
    rowKeys = groups.flatMap { g in folded.contains(g.cwd) ? [g.cwd] : g.sessions.map(\.key) } + windows.map(\.key)
  }
}

/// A row's state at a glance (Flutter's coloured border, its working snake and its flash): an SF Symbol in the
/// state's colour, pulsing while working and bouncing once when it starts needing you.
private struct StateSymbol: View {
  let state: TileState
  @EnvironmentObject private var look: Appearance

  var body: some View {
    Image(systemName: state.symbol)
      .foregroundStyle(state.color(look.theme))
      .symbolEffect(.pulse, options: .repeating, isActive: state == .working)
      .symbolEffect(.bounce, value: state == .needsYou)
      .contentTransition(.symbolEffect(.replace))
      .frame(width: 22)
      .accessibilityHidden(true)
  }
}

extension View {
  /// [row]'s swipe (Rename, Color, then End session or Close window for a window that can close, while online) and
  /// its context menu (where it sits on the computer, then the same).
  fileprivate func rowActions(row: String, own: String, look: TileLook, window w: TermWindow?, list: TerminalList)
    -> some View
  {
    let closable = w.map { $0.can(.close) } == true && list.online
    let closeLabel = w?.agent != nil ? "End session" : "Close window"
    return
      self
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if closable, let w {
          Button {
            list.close(w)
          } label: {
            Label(closeLabel, systemImage: "xmark")
          }
          .tint(.red)
          .accessibilityIdentifier("swipe-action-\(row)")
        }
        Button {
          list.recolor(row, own: own, look: look)
        } label: {
          Label("Color", systemImage: "paintpalette")
        }
        .tint(look.color.map(argbColor) ?? .indigo)
        .accessibilityIdentifier("swipe-color-\(row)")
        Button {
          list.rename(row, own: own, look: look)
        } label: {
          Label("Rename", systemImage: "pencil")
        }
        .tint(.gray)
        .accessibilityIdentifier("swipe-rename-\(row)")
      }
      .contextMenu {
        if let w, let place = list.place(w) {
          Text(place).accessibilityIdentifier("row-menu-place")
        }
        Button {
          list.rename(row, own: own, look: look)
        } label: {
          Label("Rename", systemImage: "pencil")
        }
        .accessibilityIdentifier("row-menu-rename")
        Button {
          list.recolor(row, own: own, look: look)
        } label: {
          Label("Color", systemImage: "paintpalette")
        }
        .accessibilityIdentifier("row-menu-color")
        if closable, let w {
          Button(role: .destructive) {
            list.close(w)
          } label: {
            Label(closeLabel, systemImage: "xmark")
          }
          .accessibilityIdentifier("row-menu-close")
        }
      }
  }
}

/// A line under the windows heading, by its accessibility identifier.
private struct WindowsHint {
  let id: String
  let text: String
}

/// What a session's row shows: its state at a glance, its name, its terminal, how it stands with the agent's status
/// bar after it ("Working… · Opus 4.5 · 49% · $43.34"), and how full its context is.
private struct SessionRowLabel: View {
  let key: String
  let title: String
  let state: TileState
  let words: String
  let facts: String
  let badge: String?
  let ctx: Int?

  private var line: Text {
    let state = Text(words)
    if facts.isEmpty { return state }
    return state + Text(" · \(facts)").foregroundStyle(.tertiary)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      StateSymbol(state: state)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .lineLimit(1)
          .contentTransition(.opacity)
        HStack(spacing: 6) {
          if let badge { TermBadge(badge) }
          line
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(.opacity)
        }
        if let ctx {
          ContextBar(percent: ctx)
            .padding(.top, 3)
            .accessibilityIdentifier("ctx-\(key)")
        }
      }
    }
    .padding(.vertical, 2)
    .animation(.smooth, value: state)
  }
}

/// What a window's row shows: what runs in it, its terminal (and Screen only, for an agent's), its program and
/// folder.
private struct WindowRowLabel: View {
  let window: TermWindow
  let title: String
  let badge: String
  let detail: String
  let screenOnly: Bool
  @EnvironmentObject private var look: Appearance

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: window.agent != nil ? "sparkles" : "terminal")
        .foregroundStyle(window.focused ? look.theme.tint : Color.secondary)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .lineLimit(1)
          .contentTransition(.opacity)
        HStack(spacing: 6) {
          TermBadge(badge)
          if screenOnly {
            TermBadge("Screen only").accessibilityIdentifier("screen-only-\(window.key)")
          }
          Text(detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .padding(.vertical, 2)
  }
}
