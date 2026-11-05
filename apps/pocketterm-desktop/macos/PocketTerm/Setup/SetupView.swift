import PocketTermDesktop
import PocketTermKit
import SwiftUI

let selfHostingGuide = URL(
  string: "https://github.com/danyzmaj-apps/pocketterm/blob/main/docs/SELF_HOSTING.md#on-my-own-server")!

let serverNeeds = URL(
  string: "https://github.com/danyzmaj-apps/pocketterm/blob/main/apps/pocketterm-server/README.md#what-it-needs")!

/// The first-run setup's screens. Where it was left is kept (`AppController.setupStep`, by these raw values, the
/// Flutter app's names) and it opens there again.
enum SetupStep: String {
  /// On this computer, on my own server, or Supabase.
  case choose
  /// The Tailscale checklist, then Start.
  case thisComputer
  /// Do you already have a PocketTerm server?
  case ownServer
  /// Yes: its setup link.
  case haveServer
  /// Not yet: its address, the commands for it, live checks, its setup link.
  case newServer
  /// A Supabase project: set one up with an access token, or paste the setup link of a computer already on one.
  case supabase
}

/// First run: where this computer's PocketTerm server runs. **On this computer**: the server built into the app,
/// reached through Tailscale, after a checklist that follows Tailscale as the person sets it up. **On my own
/// server**: a VPS, by its setup link, or, without one yet, the commands that set one up, checked live.
/// **Supabase**: a free Supabase project the setup makes with the person's access token. Either way, the setup
/// checklist follows sign-in (Get ready).
struct SetupView: View {
  @EnvironmentObject private var app: AppController

  /// nil until the person moves: then it's where the setup was left.
  @State private var moved: SetupStep?

  private var step: SetupStep { moved ?? app.setupStep.flatMap(SetupStep.init(rawValue:)) ?? .choose }

  private func go(_ step: SetupStep) {
    moved = step
    app.setSetupStep(step == .choose ? nil : step.rawValue)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        switch step {
        case .choose: choose
        case .thisComputer:
          ThisComputerSetup(onBack: { go(.choose) }, onOwnServer: { go(.ownServer) })
        case .ownServer: ownServer
        case .haveServer:
          SetupHeader(
            title: "Paste your server’s setup link",
            text:
              "On the server, in ~/pocketterm, run: sudo docker compose exec server pocketterm-server setup-link. "
              + "A computer of yours that runs PocketTerm’s server has one too, in Settings → Account → Add a "
              + "computer…",
            onBack: { go(.ownServer) })
          SetupLinkForm()
        case .newServer:
          NewServerSetup(address: app.setupAddress, onBack: { go(.ownServer) })
        case .supabase:
          SupabaseSetupView(onBack: { go(.choose) })
        }
      }
      .frame(width: 460, alignment: .leading)
      .padding(EdgeInsets(top: 32, leading: 24, bottom: 24, trailing: 24))
      .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder private var choose: some View {
    VStack(spacing: 8) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
      Text("Set up PocketTerm").font(.title2.weight(.semibold))
      Text("Your phone reaches this computer through a PocketTerm server. Where should it run?")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 20)
    VStack(spacing: 12) {
      SetupOption(
        id: "setup-this-computer", systemImage: "laptopcomputer", title: "On this computer",
        text:
          "Free, set up in a few clicks. Uses Tailscale, on this computer and your phone. This computer must stay "
          + "awake."
      ) { go(.thisComputer) }
      SetupOption(
        id: "setup-own-server", systemImage: "server.rack", title: "On my own server",
        text:
          "A VPS you rent. No Tailscale, and several computers share one server. Your sessions still run here, "
          + "so this computer stays awake for them too."
      ) { go(.ownServer) }
      SetupOption(
        id: "setup-supabase", systemImage: "cloud", title: "Supabase",
        text:
          "A free Supabase project PocketTerm sets up for you. No Tailscale, no server to run. Supabase holds your "
          + "device list."
      ) { go(.supabase) }
    }
    VStack(alignment: .leading, spacing: 6) {
      Explainer("What is a PocketTerm server?", id: "why-server") {
        Text(
          "It introduces your phone to your computers and passes their messages along. It keeps your list of "
            + "devices, your computers’ names, pairing codes for 10 minutes and your phones’ push tokens. Your "
            + "sessions pass through it only encrypted, so it can’t read them.")
      }
      Explainer("How the three options compare", id: "why-compare") { OptionsTable() }
      Explainer("How your data is protected", id: "why-data") { DataProtectionView() }
    }
    .padding(.top, 18)
  }

  @ViewBuilder private var ownServer: some View {
    SetupHeader(title: "On my own server", text: "Do you already have a PocketTerm server?", onBack: { go(.choose) })
    VStack(spacing: 12) {
      SetupOption(
        id: "setup-have-server", systemImage: "link", title: "Yes",
        text: "Paste its setup link. A link from another computer of yours that runs PocketTerm’s server works too."
      ) { go(.haveServer) }
      SetupOption(
        id: "setup-new-server", systemImage: "plus.circle", title: "Not yet",
        text: "Set one up on a VPS: you get the commands to copy, and each step is checked as you go."
      ) { go(.newServer) }
    }
    HStack(alignment: .firstTextBaseline) {
      Text("Already run your own servers? See what the PocketTerm server needs.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Open link") { openLink(serverNeeds) }
        .buttonStyle(.link)
        .accessibilityIdentifier("setup-server-needs")
    }
    .padding(.top, 14)
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

/// One way to go on, as a large row: its symbol, what it is, what it means; the row highlights under the pointer.
struct SetupOption: View {
  let id: String
  let systemImage: String
  let title: String
  let text: String
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 24))
          .foregroundStyle(.tint)
          .frame(width: 32)
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.headline)
          Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 4)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(hover ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(hover ? Color.accentColor : Color(nsColor: .separatorColor)))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .accessibilityLabel(title)
    .accessibilityHint(text)
    .accessibilityIdentifier(id)
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
