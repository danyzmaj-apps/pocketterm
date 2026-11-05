import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// The menu-bar item's panel: how this computer stands, Terminal from phone, what needs attention, and the ways
/// into the window.
struct MenuBarView: View {
  let close: () -> Void
  @EnvironmentObject private var app: AppController
  @EnvironmentObject private var status: StatusModel
  @EnvironmentObject private var updater: Updater
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text("PocketTerm").font(.headline)
          Text(headline).font(.callout).foregroundStyle(.secondary)
            .accessibilityIdentifier("menu-status")
        }
        Spacer()
      }
      if app.user != nil { signedIn }
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        if app.backend == nil {
          row("Set up PocketTerm…", id: "menu-open") { AppModel.shared.openMain() }
        } else if app.user == nil {
          row("Open PocketTerm", id: "menu-open") { AppModel.shared.openMain() }
        } else {
          row("Add a phone…", id: "menu-add-phone") { AppModel.shared.addPhone() }
          if app.getReadyDone {
            row("Settings…", id: "menu-settings") { AppModel.shared.openSettings() }
          } else {
            row("Open setup checklist", id: "menu-open") { AppModel.shared.openMain() }
          }
        }
        row("Check for Updates…", id: "menu-check-updates") { updater.checkForUpdates() }
          .disabled(!updater.canCheck)
        row("Quit PocketTerm", id: "menu-quit") { NSApp.terminate(nil) }
      }
    }
    .padding(14)
    .frame(width: 300)
  }

  private var headline: String {
    if app.backend == nil { return "Not set up yet" }
    if app.user == nil { return "Signed out" }
    if status.checking { return "Checking this computer…" }
    let n = status.items.count
    return n == 0 ? "All set" : "\(n) thing\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention"
  }

  @ViewBuilder private var signedIn: some View {
    Toggle(isOn: Binding(get: { app.terminalOn }, set: { on in
      Task {
        do {
          error = nil
          try await app.setTerminal(on: on)
        } catch {
          self.error = "\(error)"
        }
      }
    })) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Terminal from phone")
        Text(status.terminalsLine).font(.caption).foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.switch)
    .accessibilityIdentifier("menu-terminal-from-phone")
    if let error { Text(error).font(.caption).foregroundStyle(.red) }
    if !status.items.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(status.items) { item in
          Button {
            close()
            AppModel.shared.openSettings(item.tab)
          } label: {
            Label {
              Text(item.short).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("menu-attention-\(item.id)")
        }
      }
      .font(.callout)
    }
  }

  private func row(_ title: String, id: String, _ action: @escaping () -> Void) -> some View {
    Button {
      close()
      action()
    } label: {
      Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    .buttonStyle(MenuRowStyle())
    .accessibilityIdentifier(id)
  }
}

/// A menu's row: highlighted under the pointer, as a menu item is.
private struct MenuRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Row(configuration: configuration)
  }

  private struct Row: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      configuration.label
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(hover && enabled ? Color.white : enabled ? Color.primary : Color.secondary)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Color.accentColor : .clear))
        .onHover { hover = $0 }
    }
  }
}
