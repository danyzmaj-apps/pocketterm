import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// Settings → Phone: Terminal from phone, the phones (Add a phone…, Reset key…) and the project folders.
struct PhoneTab: View {
  @EnvironmentObject private var app: AppController
  @EnvironmentObject private var ui: UIState
  @EnvironmentObject private var status: StatusModel
  @State private var terminalError: String?
  @State private var confirmReset = false
  @State private var keyMessage: String?
  @State private var keyFailed = false

  var body: some View {
    Section {
      Toggle(isOn: Binding(get: { app.terminalOn }, set: { on in setTerminal(on) })) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Terminal from phone")
          Text("Your phone sees and drives this computer’s sessions. Keeps it awake while on.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch)
      .accessibilityIdentifier("settings-terminal-from-phone")
      if app.terminalOn {
        Text(status.terminalsLine).foregroundStyle(.secondary)
      }
      InlineMessage(message: $terminalError, error: true)
    }

    Section("Your phones") {
      if app.phoneSignedIn ?? false {
        Text("A phone is signed in").foregroundStyle(.secondary)
      } else {
        Text("No phone yet").foregroundStyle(app.phoneSignedIn == false ? Color.orange : Color.secondary)
      }
      HStack {
        Button("Add a phone…") { ui.pairingShown = true }
          .accessibilityIdentifier("settings-add-phone")
        Button("Reset key…") { confirmReset = true }
          .accessibilityIdentifier("settings-reset-key")
      }
      InlineMessage(message: $keyMessage, error: keyFailed)
    }
    .alert("Reset this computer’s key?", isPresented: $confirmReset) {
      Button("Cancel", role: .cancel) {}
      Button("Reset key", role: .destructive) { resetKey() }
    } message: {
      Text(
        "Your phones read this computer’s sessions with a key from its code. A new key locks out every phone "
          + "that has the old one, including a lost one. Each phone you keep must scan this computer’s code again "
          + "(Settings → Phone → Add a phone…). To keep a lost phone off your server too, sign it out under "
          + "Settings → Account."
      )
    }
    .sheet(isPresented: $ui.pairingShown) { PairingSheet().appEnvironment(AppModel.shared) }

    Section {
      let roots = app.projectRoots
      if roots.isEmpty {
        Text("None yet · your phone can still open any path you type").foregroundStyle(.secondary)
      }
      ForEach(roots, id: \.self) { root in
        HStack {
          Image(systemName: "folder").foregroundStyle(.secondary)
          Text(tildePath(root, home: app.terminals.home))
            .font(commandFont)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button {
            app.setProjectRoots(app.projectRoots.filter { $0 != root })
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Remove")
          .accessibilityLabel("Remove")
          .accessibilityIdentifier("settings-folder-\(root)")
        }
      }
      Button("Add folder…") { status.addFolders() }
        .accessibilityIdentifier("settings-add-folder")
    } header: {
      Text("Project folders")
    } footer: {
      Text("Your phone lists the git repositories in these (up to three levels deep) and starts new projects there.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func setTerminal(_ on: Bool) {
    Task {
      terminalError = nil
      do {
        try await app.setTerminal(on: on)
      } catch {
        terminalError = "\(error)"
      }
      await status.checkTerminals()
    }
  }

  /// A new channel key (after losing a phone): every phone must scan again.
  private func resetKey() {
    Task {
      do {
        try await app.resetChannelKey()
      } catch {
        keyFailed = true
        keyMessage = "Key not reset: \(error)"
        return
      }
      keyFailed = false
      keyMessage = "New key made. Scan this computer’s code on each phone."
    }
  }
}
