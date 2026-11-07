import PocketTermKit
import SwiftUI

/// What a phone without a session shows: the only way in is the code PocketTerm on the computer shows, scanned
/// with this phone's camera, which connects to the server, signs in and brings that computer's key. A phone
/// never signs in with GitHub and never sets up a server. "Try the demo" shows the app on a made-up computer
/// instead. After a sign-out, a deleted account or a session the server ended, it says why on top.
struct SetupView: View {
  init(app: AppModel) { self.app = app }

  @ObservedObject var app: AppModel
  @ObservedObject private var look = appearance
  @Environment(\.openURL) private var openURL
  @State private var scanning = false
  @State private var busy = false

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        Image(look.choice.launchIcon)
          .resizable()
          .scaledToFit()
          .frame(width: 80, height: 80)
          .padding(.bottom, 16)
          .accessibilityHidden(true)
        Text("Welcome to PocketTerm")
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
        if let reason = app.signedOutReason {
          Text(reason)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
            .accessibilityIdentifier("signed-out-reason")
        }
        if let note = app.movedNote {
          Text(note)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
            .accessibilityIdentifier("server-moved")
        }
        Text(
          "Your computer\u{2019}s coding sessions on your phone, end-to-end encrypted. This phone connects by "
            + "scanning the code PocketTerm on your computer shows."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 10)
        .padding(.bottom, 24)
        if let link = app.linkToConfirm {
          ConfirmLinkCard(app: app, link: link)
        } else {
          scanSteps
        }
        if let error = app.authError {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding(.top, 12)
            .accessibilityIdentifier("auth-error")
        }
        Button {
          app.enterDemo()
        } label: {
          Text("Try the demo").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(busy)
        .padding(.top, 24)
        .accessibilityIdentifier("try-demo")
        Text("No computer yet? See PocketTerm with made-up sessions. Nothing connects.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.top, 6)
      }
      .padding(24)
      .frame(maxWidth: 460)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.center)
    .background(Color(.systemGroupedBackground))
    .animation(.default, value: app.linkToConfirm)
    .animation(.default, value: app.authError)
    .fullScreenCover(isPresented: $scanning) {
      ScanSheet(signedIn: false) { link in
        scanning = false
        if let link { connect(link) }
      }
      .toasts()
    }
  }

  private var scanSteps: some View {
    VStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 10) {
        Step(1, "Install PocketTerm on your computer and open it. Its setup connects it to your server.")
        Step(2, "On the computer, open Settings \u{2192} Add\u{00A0}a\u{00A0}phone\u{2026} to show a code.")
        Step(3, "Tap the button below and point this phone at it.")
        Step(4, "That\u{2019}s it: the phone connects and signs in by itself.")
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      // Step 1 needs PocketTerm on the computer: where to get it.
      Button {
        openURL(Links.desktopDownloads)
      } label: {
        Label("Get PocketTerm for Mac or Windows", systemImage: "arrow.up.right.square")
          .font(.subheadline)
      }
      .buttonStyle(.borderless)
      .padding(.vertical, 6)
      .accessibilityIdentifier("get-desktop")
      Button {
        scanning = true
      } label: {
        Group {
          if busy {
            ProgressView()
          } else {
            Label("Scan the code from your computer", systemImage: "qrcode.viewfinder")
          }
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(busy)
      .accessibilityIdentifier("scan-code")
    }
  }

  /// Connects and signs in with the code the camera read; on failure the page stays, with the reason
  /// ([authError]) under the button.
  private func connect(_ link: URL) {
    busy = true
    Task {
      await app.connectLink(link, scanned: true)
      busy = false
      if app.authError != nil { Haptics.failed() }
    }
  }

  private struct Step: View {
    init(_ number: Int, _ text: String) {
      self.number = number
      self.text = text
    }

    let number: Int
    let text: String

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("\(number).")
          .monospacedDigit()
          .foregroundStyle(.secondary)
        Text(text)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// A setup link from outside the app to another server ([Session.linkToConfirm]): nothing happens until the
/// person says yes. Anyone can send such a link, and this device's sessions would then go through that server.
private struct ConfirmLinkCard: View {
  let app: AppModel
  let link: URL

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Connect to \(Backend.fromLink(link)?.host ?? "?")?", systemImage: "link")
        .font(.headline)
      Text(
        "A link asks to connect PocketTerm to this server. Only connect if you opened it yourself, from your own "
          + "computer or server: your sessions and the images you send go through it."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Spacer()
        Button("Cancel") { Task { await app.answerLink(connect: false) } }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("link-cancel")
        Button("Connect") { Task { await app.answerLink(connect: true) } }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("link-connect")
      }
      .padding(.top, 6)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.orange, lineWidth: 1))
  }
}
