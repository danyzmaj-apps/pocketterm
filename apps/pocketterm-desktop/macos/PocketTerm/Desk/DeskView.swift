import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals
import SwiftUI

/// Desk's window: projects and what waits for you on the left, the project's terminals in the middle, its git
/// state, commands and ports on the right, and ⌘K over it all.
struct DeskView: View {
  @ObservedObject var model: DeskModel

  var body: some View {
    NavigationSplitView(columnVisibility: Binding(
      get: { model.sidebarShown ? .all : .detailOnly }, set: { model.sidebarShown = $0 != .detailOnly })
    ) {
      DeskSidebar(model: model)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
    } detail: {
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          VStack(spacing: 0) {
            DeskHeader(model: model)
            Divider()
            DeskPanes(model: model)
          }
          if model.inspectorShown, model.project != nil {
            Divider()
            DeskInspector(model: model).frame(width: 250)
          }
        }
        Divider()
        DeskStatusBar(model: model)
      }
    }
    .overlay {
      if model.paletteShown { DeskPalette(model: model) }
    }
    .frame(minWidth: 760, minHeight: 440)
  }
}

// ------------------------------------------------------------ state marks

/// A terminal's state as a dot: orange waits for you, accent works, green finished, red failed.
struct DeskDot: View {
  let state: DeskState?

  var body: some View {
    Circle().fill(color).frame(width: 7, height: 7)
      .opacity(state == nil || state == .idle ? 0.5 : 1)
      .help(state?.words ?? "")
  }

  private var color: Color {
    switch state {
    case .needs: .orange
    case .failed: .red
    case .finished: .green
    case .working: .accentColor
    case .running: .blue
    case .idle, nil: .secondary
    }
  }
}

// ------------------------------------------------------------ sidebar

struct DeskSidebar: View {
  @ObservedObject var model: DeskModel

  var body: some View {
    List(selection: Binding(
      get: { model.focusedSession.map { "s:\($0.name)" } ?? model.project.map { "p:\($0)" } },
      set: { id in
        guard let id else { return }
        if id.hasPrefix("s:") || id.hasPrefix("w:") { model.focus(String(id.dropFirst(2))) }
        if id.hasPrefix("p:") { model.show(project: String(id.dropFirst(2))) }
      })
    ) {
      let waiting = model.waiting
      if !waiting.isEmpty {
        Section("Waiting for you") {
          ForEach(waiting) { s in
            HStack(spacing: 8) {
              DeskDot(state: model.state(s))
              VStack(alignment: .leading, spacing: 1) {
                Text(model.state(s).words).lineLimit(1)
                Text("\(DeskModel.name(s.project)) · \(model.title(s))").font(.caption).foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
            .tag("w:\(s.name)")
            .accessibilityIdentifier("desk-waiting-\(s.name)")
          }
        }
      }
      Section("Projects") {
        ForEach(model.projects, id: \.self) { project in
          projectRow(project).tag("p:\(project)")
          ForEach(Array(model.sessions(in: project).enumerated()), id: \.element.id) { i, s in
            sessionRow(s, number: project == model.project ? i + 1 : nil).tag("s:\(s.name)")
          }
        }
        Button {
          model.chooseProject()
        } label: {
          Label("Open Project…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("desk-open-project")
      }
    }
    .listStyle(.sidebar)
  }

  private func projectRow(_ project: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "folder").foregroundStyle(.secondary)
      Text(DeskModel.name(project)).fontWeight(.semibold).lineLimit(1)
      Spacer(minLength: 4)
      if let branch = model.git[project]?.branch, !branch.isEmpty {
        Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      if let state = model.state(of: project), state.wantsYou { DeskDot(state: state) }
    }
    .help(project)
    .contextMenu {
      Button(model.isPinned(project) ? "Unpin" : "Pin") { model.setPinned(project, !model.isPinned(project)) }
      Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project) }
      Divider()
      Button("Close Project…") { model.close(project: project) }
    }
    .accessibilityIdentifier("desk-project-\(DeskModel.name(project))")
  }

  private func sessionRow(_ s: DeskSession, number: Int?) -> some View {
    HStack(spacing: 6) {
      DeskDot(state: model.state(s))
      Image(systemName: model.symbol(s)).foregroundStyle(.secondary).frame(width: 14)
      Text(model.title(s)).lineLimit(1)
      Spacer(minLength: 4)
      if let number, number <= 9 { Text("⌘\(number)").font(.caption).foregroundStyle(.tertiary) }
    }
    .padding(.leading, 14)
    .contextMenu {
      Button("Rename…") { rename(s) }
      Button("End Terminal") { model.end(s) }
    }
    .accessibilityIdentifier("desk-session-\(s.name)")
  }

  private func rename(_ s: DeskSession) {
    let alert = NSAlert()
    alert.messageText = "Rename terminal"
    alert.informativeText = "Leave it empty to name it after what runs in it."
    let field = NSTextField(string: s.label)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    if alert.runModal() == .alertFirstButtonReturn { model.rename(s, to: field.stringValue) }
  }
}

// ------------------------------------------------------------ header

struct DeskHeader: View {
  @ObservedObject var model: DeskModel

  var body: some View {
    HStack(spacing: 10) {
      if let project = model.project {
        VStack(alignment: .leading, spacing: 1) {
          Text(DeskModel.name(project)).font(.headline)
          Text(project.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption.monospaced())
            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        Spacer()
        Picker("Layout", selection: Binding(get: { model.layout(project) }, set: { model.setLayout($0) })) {
          ForEach(DeskLayout.allCases) { l in
            Image(systemName: l.symbol).help(l.label).tag(l)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("desk-layout")
        newMenu
        Button {
          model.inspectorShown.toggle()
        } label: {
          Image(systemName: "sidebar.right")
        }
        .buttonStyle(.borderless)
        .help("Show or hide the project’s details (⌥⌘I)")
      } else {
        Text("Desk").font(.headline)
        Spacer()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var newMenu: some View {
    Menu {
      Button("New Terminal") { model.new() }
      ForEach(model.agents, id: \.self) { a in
        Button("New \(a.label) Session") { model.new(agent: a) }
      }
      if !model.commands.isEmpty {
        Divider()
        ForEach(model.commands) { c in
          Button("Run \(c.command)") { model.new(command: c.command) }
        }
      }
    } label: {
      Label("New", systemImage: "plus")
    } primaryAction: {
      model.new(agent: model.defaultAgent)
    }
    .fixedSize()
    .help("New \(model.defaultAgent.label) session (⌘⇧T); the arrow for a terminal or a command")
    .accessibilityIdentifier("desk-new")
  }
}

// ------------------------------------------------------------ panes

struct DeskPanes: View {
  @ObservedObject var model: DeskModel

  var body: some View {
    Group {
      if model.noTmux {
        empty(
          "tmux isn’t installed",
          "Desk runs your terminals in tmux, so they keep running when this window or PocketTerm closes. Install it with Homebrew: brew install tmux"
        ) {
          Button("Open Settings") { AppModel.shared.openSettings(.terminals) }
        }
      } else if let project = model.project {
        let shown = model.shown
        if shown.isEmpty {
          empty("Nothing runs in \(DeskModel.name(project)) yet", "Start a coding agent or a terminal here.") {
            Button("New \(model.defaultAgent.label) Session  ⌘⇧T") { model.new(agent: model.defaultAgent) }
              .keyboardShortcut(.defaultAction)
            Button("New Terminal  ⌘T") { model.new() }
          }
        } else {
          arrange(shown, layout: model.zoomed ? .single : model.layout(project))
            .padding(6)
        }
      } else {
        empty("Open a project", "Desk keeps each project’s terminals together, running, in one window.") {
          Button("Go to…  ⌘K") { model.paletteShown = true }.keyboardShortcut(.defaultAction)
          Button("Open Project…") { model.chooseProject() }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func arrange(_ shown: [DeskSession], layout: DeskLayout) -> some View {
    switch layout {
    case .single:
      pane(shown[0])
    case .focus:
      if shown.count == 1 {
        pane(shown[0])
      } else {
        // The focused one takes about three fifths of the width, the others share the rest.
        GeometryReader { g in
          HStack(spacing: 6) {
            pane(shown[0]).frame(width: max(0, (g.size.width - 6) * 0.62))
            VStack(spacing: 6) {
              ForEach(shown.dropFirst()) { s in pane(s) }
            }
          }
        }
      }
    case .grid:
      let columns = Int(Double(shown.count).squareRoot().rounded(.up))
      let rows = stride(from: 0, to: shown.count, by: max(columns, 1)).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
      VStack(spacing: 6) {
        ForEach(rows.indices, id: \.self) { r in
          HStack(spacing: 6) {
            ForEach(rows[r]) { s in pane(s) }
            // The last row's empty places, so its terminals keep the others' width.
            ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear }
          }
        }
      }
    }
  }

  private func pane(_ s: DeskSession) -> some View {
    DeskPane(model: model, session: s, focused: model.focusedSession?.name == s.name,
      number: (model.project.map { model.sessions(in: $0) }?.firstIndex(of: s) ?? 0) + 1)
  }

  private func empty(_ title: String, _ text: String, @ViewBuilder actions: () -> some View) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "rectangle.split.3x1").font(.system(size: 34)).foregroundStyle(.tertiary)
      Text(title).font(.title3)
      Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
      HStack { actions() }.padding(.top, 4)
    }
    .padding(30)
  }
}

struct DeskPane: View {
  @ObservedObject var model: DeskModel
  let session: DeskSession
  let focused: Bool
  let number: Int
  @State private var hover = false

  var body: some View {
    let state = model.state(session)
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        DeskDot(state: state)
        Image(systemName: model.symbol(session)).foregroundStyle(.secondary)
        Text(model.title(session)).fontWeight(focused ? .semibold : .regular).lineLimit(1)
        if state != .idle {
          Text(state.words).font(.caption).foregroundStyle(state.wantsYou ? Color.orange : .secondary).lineLimit(1)
        }
        if let ports = model.ports[session.name] {
          ForEach(ports, id: \.self) { port in
            Link(":\(port)", destination: URL(string: "http://localhost:\(port)")!).font(.caption.monospaced())
          }
        }
        Spacer(minLength: 4)
        if number <= 9 { Text("⌘\(number)").font(.caption).foregroundStyle(.tertiary) }
        Button {
          model.end(session)
        } label: {
          Image(systemName: "xmark").font(.caption)
        }
        .buttonStyle(.borderless)
        .opacity(hover || focused ? 1 : 0)
        .help("End this terminal (⌘⇧W)")
      }
      .font(.callout)
      .padding(.horizontal, 8)
      .frame(height: 26)
      .background(focused ? Color.accentColor.opacity(0.12) : Color.clear)
      .contentShape(Rectangle())
      .onTapGesture { model.focus(session.name) }
      Divider()
      DeskTerminal(
        session: session.name, desk: model.desk, focused: focused, focusTick: model.focusTick,
        onFocus: { [weak model] in
          guard let model, model.focusedSession?.name != session.name else { return }
          model.focus(session.name)
        })
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 7))
    .overlay(
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1)
    )
    .onHover { hover = $0 }
    .accessibilityIdentifier("desk-pane-\(session.name)")
  }
}

// ------------------------------------------------------------ inspector

struct DeskInspector: View {
  @ObservedObject var model: DeskModel
  @State private var adding = ""

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let project = model.project {
          section("Git") {
            if let g = model.git[project] {
              row("Branch", g.branch.isEmpty ? "detached" : g.branch, mono: true)
              if g.ahead > 0 || g.behind > 0 { row("Upstream", "↑\(g.ahead) ↓\(g.behind)") }
              row("Changes", g.changes == 0 ? "None" : "\(g.changes) file\(g.changes == 1 ? "" : "s")")
              if g.worktrees > 1 { row("Worktrees", "\(g.worktrees)") }
            } else {
              Text("Not a git repository").foregroundStyle(.secondary)
            }
          }
          section("Run") {
            ForEach(model.commands) { c in
              HStack(spacing: 6) {
                Button {
                  model.new(command: c.command)
                } label: {
                  Label(c.command, systemImage: "play.fill").labelStyle(.titleAndIcon).lineLimit(1)
                }
                .buttonStyle(.borderless)
                .font(.callout.monospaced())
                .help("Run it in a new terminal")
                Spacer(minLength: 0)
                if c.saved {
                  Button {
                    model.forget(command: c.command)
                  } label: {
                    Image(systemName: "minus.circle")
                  }
                  .buttonStyle(.borderless)
                  .foregroundStyle(.secondary)
                  .help("Remove")
                }
              }
            }
            TextField("Add a command…", text: $adding)
              .textFieldStyle(.roundedBorder)
              .font(.callout.monospaced())
              .onSubmit {
                model.save(command: adding)
                adding = ""
              }
          }
          let listening = model.sessions(in: project).compactMap { s in model.ports[s.name].map { (s, $0) } }
          if !listening.isEmpty {
            section("Ports") {
              ForEach(listening, id: \.0.name) { s, ports in
                ForEach(ports, id: \.self) { port in
                  HStack {
                    Link("localhost:\(port)", destination: URL(string: "http://localhost:\(port)")!)
                      .font(.callout.monospaced())
                    Spacer()
                    Text(model.title(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
              }
            }
          }
        }
      }
      .padding(12)
    }
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
      content()
    }
  }

  private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value).font(mono ? .callout.monospaced() : .callout).lineLimit(1).truncationMode(.middle)
    }
    .font(.callout)
  }
}

// ------------------------------------------------------------ status bar

struct DeskStatusBar: View {
  @ObservedObject var model: DeskModel

  var body: some View {
    HStack(spacing: 14) {
      let states = model.sessions.map(model.state)
      let working = states.filter { $0 == .working }.count
      let waiting = states.filter(\.wantsYou).count
      Text("\(model.sessions.count) terminal\(model.sessions.count == 1 ? "" : "s")")
      if working > 0 { Text("\(working) working") }
      if waiting > 0 { Text("\(waiting) waiting for you").foregroundStyle(.orange) }
      if let error = model.error {
        Text(error).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
          .onTapGesture { model.error = nil }
      }
      Spacer()
      Text("⌘K Go to  ·  ⌘J Next waiting  ·  ⌘T New terminal").foregroundStyle(.tertiary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 24)
  }
}
