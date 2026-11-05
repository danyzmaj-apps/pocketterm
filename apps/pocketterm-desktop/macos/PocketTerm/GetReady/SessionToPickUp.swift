import AppKit
import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals
import SwiftUI

/// An agent session opened before PocketTerm was in its agent: where it runs, and what to type there to pick
/// PocketTerm up (`Agent.pickUp`) with a button that copies it. The setup checklist and Settings list these.
struct SessionToPickUp: View {
  @EnvironmentObject var app: AppController
  let window: TermWindow
  let id: String
  /// The command was copied: the button says so (the window has no toast).
  @State private var copied = false

  init(window: TermWindow, id: String) {
    self.window = window
    self.id = id
  }

  var body: some View {
    let w = window
    let agent = w.agent ?? .omp
    let terminals = app.terminals
    let place = terminals.hosts.first { $0.id == w.app }?.label ?? w.app
    let where_ = ((w.cwd.isEmpty ? [] : ["in \(tildePath(w.cwd, home: terminals.home))"]) + [place])
      .joined(separator: " · ")
    // As typed: the no-break characters keep it whole on screen, not in a terminal.
    let pickUp = agent.pickUpIn(w.profile)
    let typed = pickUp.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2060}", with: "")
    HStack(spacing: 10) {
      Image(systemName: "arrow.clockwise").foregroundStyle(.orange)
      Text("\(Integrations.name(agent)) \(where_)")
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 4) {
        Text(pickUp).font(commandFont).textSelection(.enabled)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(typed, forType: .string)
          copied = true
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(copied ? "Copied" : "Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy")
      }
      .padding(.leading, 8)
      .padding(.trailing, 4)
      .padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id)
  }
}

/// `path` with `home` as `~`.
func tildePath(_ path: String, home: String) -> String {
  if path == home { return "~" }
  return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}
