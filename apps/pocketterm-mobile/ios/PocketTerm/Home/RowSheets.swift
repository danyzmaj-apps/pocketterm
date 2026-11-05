import PocketTermKit
import SwiftUI

/// Asks for a row's own name; empty, Reset, or the computer's own name goes back to the one the computer gives it.
/// [onSave] gets the trimmed name ("" for Reset).
struct RenameSheet: View {
  let edit: RowEdit
  let onSave: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @FocusState private var focused: Bool

  init(edit: RowEdit, onSave: @escaping (String) -> Void) {
    self.edit = edit
    self.onSave = onSave
    _name = State(initialValue: edit.look.name ?? edit.own)
  }

  private func save(_ text: String) {
    onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
    dismiss()
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(edit.own, text: $name)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { save(name) }
            .accessibilityIdentifier("tile-rename-field")
        }
        if edit.look.name != nil {
          Section {
            Button("Reset") { save("") }
              .accessibilityIdentifier("tile-rename-reset")
          } footer: {
            Text("Back to \u{201C}\(edit.own)\u{201D}.")
          }
        }
      }
      .navigationTitle("Rename")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save(name) }
            .accessibilityIdentifier("tile-rename-save")
        }
      }
    }
    .presentationDetents([.medium])
    .onAppear { focused = true }
  }
}

/// Asks for a row's colour, or none ([current] is ticked). [onPick] gets nil for No color.
struct ColorSheet: View {
  let current: Int?
  let onPick: (Int?) -> Void

  @Environment(\.dismiss) private var dismiss

  private func pick(_ color: Int?) {
    Haptics.picked()
    onPick(color)
    dismiss()
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 20) {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 16) {
          ForEach(Array(tileColors.enumerated()), id: \.element) { i, c in
            Button {
              pick(c)
            } label: {
              Circle()
                .fill(argbColor(c))
                .frame(width: 44, height: 44)
                .overlay {
                  if current == c {
                    Image(systemName: "checkmark")
                      .font(.headline.weight(.bold))
                      .foregroundStyle(.white)
                  }
                }
                .overlay(Circle().strokeBorder(.primary.opacity(current == c ? 0.6 : 0), lineWidth: 2).padding(-4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tileColorNames[i])
            .accessibilityAddTraits(current == c ? .isSelected : [])
            .accessibilityIdentifier("tile-color-\(String(format: "%08X", UInt32(truncatingIfNeeded: c)))")
          }
        }
        if current != nil {
          Button {
            pick(nil)
          } label: {
            Label("No color", systemImage: "circle.slash")
          }
          .accessibilityIdentifier("tile-color-none")
        }
        Spacer(minLength: 0)
      }
      .padding(20)
      .navigationTitle("Color")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .presentationDetents([.height(current == nil ? 260 : 310)])
  }
}

/// The computer's app windows in its list's order, each headed by its app and number ("kitty window 2") over the
/// projects in it, then its tabs, one row each whatever panes are split in it. A tab running a live session shows
/// that session. [onPick] gets the tab picked: its session's key, if one runs there, and its pane to show otherwise.
struct LayoutSheet: View {
  @ObservedObject var remote: TerminalRemote
  let onPick: (_ session: String?, _ window: String) -> Void

  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var look: Appearance

  var body: some View {
    let layout = macLayout(remote.windows, terminals: remote.terminals)
    NavigationStack {
      List {
        Section {
          Text("\(layoutCount(layout)) on \(remote.desktopName ?? "the computer")")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        ForEach(layout, id: \.id) { w in
          Section {
            ForEach(w.tabs, id: \.id) { t in tab(t) }
          } header: {
            heading(w)
          }
        }
      }
      .listStyle(.insetGrouped)
      .listSectionSpacing(.compact)
      .accessibilityIdentifier("layout-sheet")
      .navigationTitle("Windows and tabs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  /// [w]'s heading: its app and number, the projects in it under.
  private func heading(_ w: MacWindow) -> some View {
    var projects: [String] = []
    for t in w.tabs {
      for p in t.panes where !p.cwd.isEmpty {
        let name = projectName(remote, p.cwd)
        if !projects.contains(name) { projects.append(name) }
      }
    }
    return VStack(alignment: .leading, spacing: 2) {
      Text("\(w.app) window \(w.number)")
        .font(.headline)
        .foregroundStyle(.primary)
      if !projects.isEmpty {
        Text(projects.joined(separator: ", "))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .textCase(nil)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("layout-window-\(w.id)")
  }

  /// One tab's row: its live session when one runs there, else its pane as the window rows show one.
  private func tab(_ t: MacTab) -> some View {
    let lead = tabLead(t)
    let s = tabSession(remote, t)
    let cwd = shortPath(remote, s?.cwd ?? lead.cwd)
    let title: String
    let detail: String
    if let s {
      title = s.title.isEmpty ? s.agent.label : s.title
      detail = sessionState(s)
    } else {
      title = !lead.tab.isEmpty ? lead.tab : !lead.title.isEmpty ? lead.title : lead.program
      detail = lead.program
    }
    let symbol: String
    let color: Color
    if let s {
      let state = Finished.shared.state(s)
      symbol = state.symbol
      color = state.color(look.theme)
    } else {
      symbol = lead.agent != nil ? "sparkles" : "terminal"
      color = lead.focused ? look.theme.tint : .secondary
    }
    return Button {
      onPick(s?.key, lead.key)
    } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: symbol)
          .foregroundStyle(color)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text([detail, cwd].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
      }
    }
    .tint(.primary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("layout-tab-\(t.id)")
  }
}
