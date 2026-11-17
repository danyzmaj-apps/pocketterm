import AppKit
import PocketTermKit
import PocketTermTerminals
import SwiftUI

/// One thing ⌘K goes to or does.
struct PaletteItem: Identifiable {
  let id: String
  let title: String
  let detail: String
  let symbol: String
  var state: DeskState?
  let run: () -> Void
}

/// ⌘K: go to a project or a terminal, start one, run a project's command, by typing a few letters of it. Empty, it
/// lists the project shown before this one first (⌘K, Return goes back), then what waits for you.
struct DeskPalette: View {
  @ObservedObject var model: DeskModel
  @State private var query = ""
  @State private var selected = 0
  @State private var monitor: Any?
  @FocusState private var typing: Bool

  var body: some View {
    let items = filtered
    ZStack(alignment: .top) {
      Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { close() }
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Go to a project or terminal, or start something…", text: $query)
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($typing)
            .onSubmit { pick(items) }
            .accessibilityIdentifier("desk-palette-field")
        }
        .padding(12)
        Divider()
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                row(item, selected: i == selected)
                  .onTapGesture {
                    selected = i
                    pick(items)
                  }
              }
              if items.isEmpty {
                Text("Nothing matches “\(query)”").foregroundStyle(.secondary).padding(16)
              }
            }
          }
          .frame(maxHeight: 360)
          .onChange(of: selected) { i in if items.indices.contains(i) { scroll.scrollTo(items[i].id) } }
        }
      }
      .frame(width: 560)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
      .shadow(radius: 20, y: 8)
      .padding(.top, 70)
    }
    .onChange(of: query) { _ in selected = 0 }
    .onAppear {
      typing = true
      // ↑ ↓ move through the list and Esc closes, while the field keeps the letters.
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        switch event.keyCode {
        case 125:
          selected = min(selected + 1, max(filtered.count - 1, 0))
          return nil
        case 126:
          selected = max(selected - 1, 0)
          return nil
        case 53:
          close()
          return nil
        default:
          return event
        }
      }
    }
    .onDisappear {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    .accessibilityIdentifier("desk-palette")
  }

  private func row(_ item: PaletteItem, selected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: item.symbol).frame(width: 18).foregroundStyle(selected ? .white : .secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).lineLimit(1)
        if !item.detail.isEmpty {
          Text(item.detail).font(.caption).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
        }
      }
      Spacer()
      if let state = item.state, state != .idle {
        Text(state.words).font(.caption).foregroundStyle(selected ? .white : state.wantsYou ? .orange : .secondary)
      }
    }
    .foregroundStyle(selected ? Color.white : Color.primary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(selected ? Color.accentColor : Color.clear)
    .contentShape(Rectangle())
  }

  private func close() {
    model.paletteShown = false
    model.takeKeyboard()
  }

  private func pick(_ items: [PaletteItem]) {
    guard items.indices.contains(selected) else { return }
    let item = items[selected]
    model.paletteShown = false
    item.run()
  }

  /// Everything it offers, in the empty list's order.
  private var all: [PaletteItem] {
    var out: [PaletteItem] = []
    let home = NSHomeDirectory()
    func path(_ p: String) -> String { p.replacingOccurrences(of: home, with: "~") }
    let projects = model.paletteProjects
    // The project shown before this one, then what waits for you, then the rest.
    if let back = projects.first, back != model.project {
      out.append(projectItem(back, path(back)))
    }
    for s in model.waiting {
      out.append(sessionItem(s))
    }
    if let project = model.project {
      let name = DeskModel.name(project)
      for a in model.agents {
        out.append(PaletteItem(
          id: "new-\(a.name)", title: "New \(a.label) Session", detail: "in \(name)", symbol: "sparkles",
          run: { model.new(agent: a) }))
      }
      out.append(PaletteItem(
        id: "new-shell", title: "New Terminal", detail: "in \(name)", symbol: "terminal", run: { model.new() }))
      for c in model.commands {
        out.append(PaletteItem(
          id: "run-\(c.command)", title: "Run \(c.command)", detail: "in \(name)", symbol: "play",
          run: { model.new(command: c.command) }))
      }
    }
    for p in projects.dropFirst() where !out.contains(where: { $0.id == "p:\(p)" }) {
      out.append(projectItem(p, path(p)))
    }
    for s in model.sessions where !out.contains(where: { $0.id == "s:\(s.name)" }) {
      out.append(sessionItem(s))
    }
    for l in DeskLayout.allCases {
      out.append(PaletteItem(
        id: "layout-\(l.rawValue)", title: "Layout: \(l.label)", detail: "", symbol: l.symbol,
        run: { model.setLayout(l) }))
    }
    out.append(PaletteItem(
      id: "open", title: "Open Project…", detail: "a folder", symbol: "folder.badge.plus", run: { model.chooseProject() }))
    return out
  }

  private func projectItem(_ p: String, _ path: String) -> PaletteItem {
    PaletteItem(
      id: "p:\(p)", title: DeskModel.name(p), detail: path, symbol: "folder", state: model.state(of: p),
      run: { model.open(project: p) })
  }

  private func sessionItem(_ s: DeskSession) -> PaletteItem {
    PaletteItem(
      id: "s:\(s.name)", title: model.title(s), detail: DeskModel.name(s.project), symbol: model.symbol(s),
      state: model.state(s), run: { model.focus(s.name) })
  }

  /// `all` narrowed to what holds the query's letters in order (title, then detail), best first: those whose title
  /// starts with it, then where a word starts with it, then the rest.
  private var filtered: [PaletteItem] {
    let q = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !q.isEmpty else { return all }
    func score(_ item: PaletteItem) -> Int? {
      let title = item.title.lowercased()
      let both = "\(title) \(item.detail.lowercased())"
      if title.hasPrefix(q) { return 0 }
      if title.contains(" \(q)") || title.contains(q) { return 1 }
      if both.contains(q) { return 2 }
      return Self.inOrder(q, both) ? 3 : nil
    }
    return all.compactMap { item in score(item).map { (item, $0) } }
      .enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
  }

  /// Whether `q`'s characters (spaces aside) appear in `s` in order.
  static func inOrder(_ q: String, _ s: String) -> Bool {
    var it = s.makeIterator()
    for c in q where c != " " {
      var found = false
      while let x = it.next() {
        if x == c {
          found = true
          break
        }
      }
      if !found { return false }
    }
    return true
  }
}
