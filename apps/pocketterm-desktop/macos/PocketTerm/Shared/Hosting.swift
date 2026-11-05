import AppKit
import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// The phone needs Tailscale too, on the same account; this setup and the phone's QR (GetReadyView) both say so.
let phoneTailscaleNote =
  "Your phone needs the Tailscale app too, signed in to the same Tailscale account. Get it from the App Store or "
  + "Google Play. If Tailscale says Awaiting Approval, approve this phone in the Tailscale admin console under "
  + "Machines."

/// Where the built-in server stands, in a line, with what to do about it: install or open Tailscale, turn HTTPS on,
/// look again.
struct HostingStatusView: View {
  @EnvironmentObject var app: AppController
  @ObservedObject var server: BuiltInServer

  init(server: BuiltInServer) {
    self.server = server
  }

  private enum Action { case install, open, https, again }

  private var line: (text: String, kind: StatusKind, actions: [Action]) {
    switch server.state {
    case .checking: ("Looking for Tailscale…", .working, [])
    case .noTailscale: ("Tailscale isn’t installed. Your phone reaches this computer through it.", .warn, [.install])
    case .tailscaleOff: ("Tailscale isn’t running. Open it and switch it on.", .warn, [.open, .again])
    case .loggedOut: ("Tailscale is signed out. Open it and sign in.", .warn, [.open, .again])
    case .httpsOff:
      (
        "HTTPS is off for your tailnet. Turn it on, so your phone gets a secure address for this computer.", .warn,
        [.https, .again]
      )
    case .failed: ("Tailscale didn’t publish the server: \(server.error ?? "null")", .warn, [.again])
    case .taken: (server.error ?? "", .warn, [.again])
    case .ready:
      ("Tailscale serves it to your own devices at \(server.publicUrl?.absoluteString ?? "null")", .ok, [])
    }
  }

  var body: some View {
    let line = line
    VStack(alignment: .leading, spacing: 8) {
      if line.kind == .working {
        Label {
          Text(line.text).foregroundStyle(.secondary)
        } icon: {
          ProgressView().controlSize(.small)
        }
      } else {
        StatusText(line.kind, line.text)
      }
      if !line.actions.isEmpty {
        HStack(spacing: 8) {
          ForEach(line.actions, id: \.self) { button($0) }
        }
      }
      if server.state == .ready, let old = server.renamedFrom {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "This computer’s Tailscale address changed from \(old.host ?? ""). Phones and computers set up with the "
              + "old one can’t reach it: scan this computer’s code again on each phone (Add a phone…), and paste a "
              + "new link on each other computer (Add a computer…)."
          )
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          Button("Got it") { server.renameSeen() }
            .accessibilityIdentifier("hosting-renamed-seen")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hosting-renamed")
      }
    }
  }

  @ViewBuilder private func button(_ action: Action) -> some View {
    switch action {
    case .install: Button("Install Tailscale") { openLink(Tailscale.download) }
    case .open: Button("Open Tailscale") { Task { await server.tailscale.open() } }
    case .https:
      Button("Turn on HTTPS…") { openLink(server.enableHttps ?? Tailscale.adminDns) }
        .accessibilityIdentifier("hosting-enable-https")
    case .again: Button("Check again") { Task { await server.refresh() } }
    }
  }
}

/// Settings → Account → "Add a computer…": the setup link another computer pastes (Your own server) to join this
/// computer's server through Tailscale. `how` says what the other computer does with it.
struct AddComputerSheet: View {
  @EnvironmentObject var app: AppController
  @Environment(\.dismiss) private var dismiss
  let link: URL
  var how: String = AddComputerSheet.tailscaleHow
  @State private var copied: String?

  /// What the other computer does with a link to this computer's built-in server.
  static let tailscaleHow =
    "On the other computer, sign in to Tailscale with the same account, install PocketTerm, choose Your own "
    + "server and paste this link."

  /// The same for a Supabase project's link (a new one; the one before stops working).
  static let supabaseHow =
    "On the other computer, open PocketTerm, choose Supabase, then Paste a setup link, and paste this link. "
    + "A link you made before this one stops working."

  var body: some View {
    SheetLayout(title: "Add a computer", width: 420) {
      Text(how).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text(link.absoluteString)
        .font(commandFont)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityIdentifier("add-computer-link")
      Text("Anyone who has this link can sign a computer in to your server. Send it only to yourself.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      InlineMessage(message: $copied)
    } buttons: {
      Button("Copy link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        copied = "Link copied"
      }
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }
  }
}
