import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// The first-run setup's screens. Where it was left is kept (`AppController.setupStep`, by these raw values) and
/// it opens there again; a step an older app kept (choose, ownServer, haveServer, newServer, supabase) opens the
/// first one.
enum SetupStep: String {
  /// The Tailscale checklist, then Start: the server built into this app.
  case thisComputer
  /// Join another computer's PocketTerm: the setup link its Settings → Add a computer… shows.
  case join
}

/// First run: PocketTerm runs its server on this computer, reached through Tailscale, after a checklist that
/// follows Tailscale as the person sets it up; then Start. A computer whose other computer already runs it joins
/// that one instead, with the link from its Settings → Add a computer…. Either way, the setup checklist follows
/// sign-in (Get ready).
struct SetupView: View {
  @EnvironmentObject private var app: AppController

  /// nil until the person moves: then it's where the setup was left.
  @State private var moved: SetupStep?

  private var step: SetupStep { moved ?? app.setupStep.flatMap(SetupStep.init(rawValue:)) ?? .thisComputer }

  private func go(_ step: SetupStep) {
    moved = step
    app.setSetupStep(step == .thisComputer ? nil : step.rawValue)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        switch step {
        case .thisComputer: thisComputer
        case .join:
          SetupHeader(
            title: "Join another computer’s PocketTerm",
            text:
              "On the computer that runs your PocketTerm, open Settings → Account → Add a computer… and paste the "
              + "link it shows. This computer needs Tailscale too, signed in to the same account.",
            onBack: { go(.thisComputer) })
          SetupLinkForm()
        }
      }
      .frame(width: 460, alignment: .leading)
      .padding(EdgeInsets(top: 32, leading: 24, bottom: 24, trailing: 24))
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder private var thisComputer: some View {
    VStack(spacing: 8) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
      Text("Set up PocketTerm").font(.title2.weight(.semibold))
      Text(
        "PocketTerm runs your server on this computer. Tailscale gives it a private HTTPS address that only your "
          + "own devices reach, at home or away. This list checks itself as you go."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 20)
    if let note = app.movedNote {
      Notice(text: note, systemImage: "arrow.triangle.2.circlepath", id: "setup-moved")
        .padding(.bottom, 14)
    }
    ThisComputerSetup()
    // The secondary way: another computer already runs PocketTerm's server.
    Button { go(.join) } label: {
      Text("Join another computer’s PocketTerm…").frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .accessibilityIdentifier("setup-join")
    .padding(.top, 10)
    Text("Another computer of yours already runs PocketTerm? Paste the link its Settings → Add a computer… shows.")
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .multilineTextAlignment(.center)
      .padding(.top, 8)
    VStack(alignment: .leading, spacing: 6) {
      Explainer("What is a PocketTerm server?", id: "why-server") {
        Text(
          "It introduces your phone to your computers and passes their messages along. It keeps your list of "
            + "devices, your computers’ names, pairing codes for 10 minutes and your phones’ push tokens. Your "
            + "sessions pass through it only encrypted, so it can’t read them.")
      }
      Explainer("How your data is protected", id: "why-data") { DataProtectionView() }
    }
    .padding(.top, 18)
  }
}

/// A screen's heading and its way back.
struct SetupHeader: View {
  let title: String
  let text: String
  let onBack: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("setup-back")
        .padding(.bottom, 4)
      Text(title).font(.title2.weight(.semibold))
      Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 18)
  }
}

/// The screen's one main button, full width: a spinner over it while its work runs (it keeps its label for
/// VoiceOver).
struct SetupButton: View {
  let title: String
  let id: String
  var busy = false
  var enabled = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .opacity(busy ? 0 : 1)
        .overlay { if busy { ProgressView().controlSize(.small) } }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(!enabled || busy)
    .accessibilityIdentifier(id)
  }
}

/// What went wrong, under the button that tried.
struct SetupError: View {
  let text: String
  let id: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.red)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity)
      .padding(.top, 12)
      .accessibilityIdentifier(id)
  }
}
