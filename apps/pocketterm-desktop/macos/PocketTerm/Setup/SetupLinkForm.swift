import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// A setup link, checked as it's pasted (a link at all, a computer's, its server answering, this computer's clock
/// against the server's), then redeemed by Connect.
struct SetupLinkForm: View {
  /// What asks the pasted link's server for its health.
  var checks: any ServerChecks = NetworkServerChecks()

  /// Says when this computer's clock is off the server's; false where the screen already says so.
  var clock = true

  @EnvironmentObject private var app: AppController
  @State private var link = ""
  @State private var busy = false
  @State private var error: String?

  /// The pasted link's server: nil while not asked, `""` while asking.
  @State private var health: String?

  /// This computer's clock is too far off the server's (`Backend.clockWarning`).
  @State private var clockWarning: String?
  @State private var asked = 0

  private func changed(_ text: String) {
    asked += 1
    let ask = asked
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let problem = trimmed.isEmpty ? nil : setupLinkProblem(text)
    error = problem
    health = nil
    clockWarning = nil
    guard !trimmed.isEmpty, problem == nil, let backend = Backend.fromLink(trimmed) else { return }
    health = ""
    let checks = checks
    Task {
      let h = await checks.answers(backend)
      guard ask == asked else { return }
      health = h.error == nil ? "\(backend.host) answers" : nil
      error = h.error
      clockWarning = Backend.clockWarning(h.clockOffset)
    }
  }

  private func connect() async {
    if let problem = setupLinkProblem(link) {
      error = problem
      return
    }
    asked += 1
    busy = true
    error = nil
    if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) {
      await app.connectLink(url)
    }
    // A link that didn't sign in leaves nothing behind: the form says why.
    if app.user == nil {
      let why = app.authError ?? "That setup link didn’t sign this computer in."
      if app.backend != nil { await app.disconnect() }
      error = why
    }
    busy = false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField("pocketterm://setup?url=…&setup=…", text: $link)
        .textFieldStyle(.roundedBorder)
        .font(commandFont)
        .autocorrectionDisabled()
        .disabled(busy)
        .onSubmit { Task { await connect() } }
        .onChange(of: link) { changed($0) }
        .accessibilityIdentifier("setup-link")
      if let health, error == nil {
        HStack(spacing: 8) {
          if health.isEmpty {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "checkmark").foregroundStyle(.green)
          }
          Text(health.isEmpty ? "Asking the server…" : health).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup-link-health")
      }
      if clock, let clockWarning {
        Notice(text: clockWarning, systemImage: "clock", id: "setup-link-clock").padding(.top, 10)
      }
      SetupButton(title: "Connect", id: "setup-connect", busy: busy) { Task { await connect() } }
        .padding(.top, 14)
      if let error { SetupError(text: error, id: "setup-error") }
    }
  }
}
