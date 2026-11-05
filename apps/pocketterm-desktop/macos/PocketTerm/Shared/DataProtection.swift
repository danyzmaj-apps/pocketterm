import SwiftUI

/// How your data is protected, in plain words: the first-run setup shows it, Settings → Account opens it again.
/// Kept true to the code: PocketTermKit's e2e sealing, SECURITY.md, apps/pocketterm-relay/SECURITY.md.
struct DataProtectionView: View {
  static let sections: [(symbol: String, title: String, text: String)] = [
    (
      "lock",
      "Encrypted from end to end",
      "Each computer makes its own key and keeps it in its Keychain (on Windows, a file in %APPDATA% encrypted for "
        + "your Windows account). A phone gets it only by scanning that computer’s QR code. Your sessions, prompts, "
        + "screens, images, files and notification text travel sealed with it (AES-256-GCM), so nothing in between "
        + "can read them."
    ),
    (
      "server.rack",
      "Your PocketTerm server",
      "Keeps your list of devices, your computers’ names, pairing codes for 10 minutes and your phones’ push tokens. "
        + "Images and files you send wait there sealed until the computer fetches them, at most an hour. It passes "
        + "everything else on without being able to read it."
    ),
    (
      "point.3.connected.trianglepath.dotted",
      "Tailscale (On this computer)",
      "Connects your own devices privately. Tailscale sees which of your devices connect and when, not what they "
        + "send."
    ),
    (
      "bell",
      "Notifications, if you turn them on",
      "They go from your server through PocketTerm’s push relay (push.danyzmaj.com, run by Danijel Lovric on his "
        + "server in Germany) to Apple or Google, then your phone. The relay, Apple and Google see an encrypted message, "
        + "your phone’s push token and when it was sent, never which computer or session it is about. The relay stores "
        + "nothing."
    ),
    (
      "info.circle",
      "Lock Screen updates (iPhone)",
      "When you follow a session, iOS shows its state on the Lock Screen: working, needs you, or finished. Apple "
        + "doesn’t let apps decrypt these updates, so this state travels unencrypted. It never includes any text from "
        + "your sessions, and it carries no names, folders or ids."
    ),
    (
      "qrcode",
      "The QR code is a key",
      "Whoever scans it can read this computer’s sessions: show it only to your own phone. Settings → Phone → Reset "
        + "key makes a new key; every phone then scans the code again."
    ),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(Self.sections, id: \.title) { section in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Image(systemName: section.symbol)
            .foregroundStyle(.tint)
            .frame(width: 20)
          VStack(alignment: .leading, spacing: 3) {
            Text(section.title).font(.headline)
            Text(section.text)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }
}

/// [DataProtectionView] in a sheet (Settings → Account).
struct DataProtectionSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SheetLayout(title: "How your data is protected", width: 500) {
      ScrollView { DataProtectionView().padding(.trailing, 4) }
        .frame(maxHeight: 460)
    } buttons: {
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("data-protection-done")
    }
    // A container of its own: an identifier on a plain stack goes to every element in it, Done's included.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("data-protection")
  }
}
