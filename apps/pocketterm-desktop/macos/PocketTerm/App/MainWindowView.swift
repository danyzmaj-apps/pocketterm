import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// The setup window: the first-run setup, then sign-in, then the setup checklist until it's done (Settings, its
/// own window, after). A setup link to another server waits for a yes here.
struct MainWindowView: View {
  @EnvironmentObject private var app: AppController

  var body: some View {
    Group {
      if app.backend == nil {
        SetupView()
      } else if app.user == nil {
        SignInView()
      } else {
        GetReadyView()
      }
    }
    .frame(minWidth: 520, minHeight: 420)
    .linkNotice(when: app.user != nil)
    .alert(
      "Connect to \(app.linkToConfirm.flatMap { Backend.fromLink($0)?.host } ?? "?")?",
      isPresented: Binding(
        get: { app.user == nil && app.linkToConfirm != nil },
        set: { if !$0, app.linkToConfirm != nil { Task { await app.answerLink(connect: false) } } })
    ) {
      Button("Cancel", role: .cancel) { Task { await app.answerLink(connect: false) } }
      Button("Connect") { Task { await app.answerLink(connect: true) } }
        .keyboardShortcut(.defaultAction)
    } message: {
      Text(
        "A link asks to connect PocketTerm to this server. Only connect if you opened it yourself, from your own "
          + "computer or server: your sessions and the images you send go through it.")
    }
  }
}

/// Signing this computer in with its server's setup link (pocketterm_core's SignInPage): what to do, what went
/// wrong, Try again, and the way to another server.
struct SignInView: View {
  @EnvironmentObject private var app: AppController

  var body: some View {
    VStack(spacing: 14) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
      Text("PocketTerm").font(.title2.weight(.semibold))
      Text("Sign in to connect this computer to your phone.").foregroundStyle(.secondary)
      Text(
        app.authError
          ?? "Open your server’s setup link on this computer. To see it again, run `pocketterm-server setup-link` on the server."
      )
      .font(.callout)
      .foregroundStyle(app.authError == nil ? Color.secondary : Color.red)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("sign-in-message")
      if app.retryLink != nil {
        Button("Try again") { Task { await app.retry() } }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("sign-in-retry")
      }
      Button("Connected to \(app.backend?.host ?? "?") · Use a different server") {
        Task { await app.disconnect() }
      }
      .buttonStyle(.link)
      .font(.caption)
      .padding(.top, 6)
      .accessibilityIdentifier("sign-in-other-server")
    }
    .frame(width: 360)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension View {
  /// What a link said while signed in, as an alert over this window while `when` (the window showing).
  func linkNotice(when shown: Bool) -> some View { modifier(LinkNotice(shown: shown)) }
}

private struct LinkNotice: ViewModifier {
  let shown: Bool
  @EnvironmentObject private var ui: UIState

  func body(content: Content) -> some View {
    content.alert(
      ui.notice ?? "",
      isPresented: Binding(get: { shown && ui.notice != nil }, set: { if !$0 { ui.notice = nil } })
    ) {
      Button("OK") { ui.notice = nil }.accessibilityIdentifier("link-notice")
    }
  }
}
