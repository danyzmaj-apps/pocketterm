import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// On this computer: a checklist that follows Tailscale as it's set up, looking again every 3 seconds: installed,
/// running, signed in, HTTPS certificates on, port 443 free for PocketTerm. Each step shows only its own action;
/// then Start runs the built-in server and signs this computer in to it.
struct ThisComputerSetup: View {
  let onBack: () -> Void

  /// A tailnet whose HTTPS only its admin turns on (a work one): the VPS way instead.
  var onOwnServer: (() -> Void)?

  @EnvironmentObject private var app: AppController
  @State private var status: TailscaleStatus?

  /// What already serves on port 443 of this computer's Tailscale name; nil while nothing else does (or not asked
  /// yet).
  @State private var taken: String?

  /// `tailscale serve status` didn't say what serves on port 443.
  @State private var unreadable = false
  @State private var busy = false
  @State private var askingHttps = false
  @State private var error: String?

  /// How often the list looks at Tailscale again.
  private static let poll: UInt64 = 3_000_000_000

  private func look() async {
    let ts = app.tailscale
    let status = await ts.status()
    let ready = status.state == .running && status.https && status.dnsName != nil
    var serving: Serving?
    if ready { serving = await ts.port443(app.ownServerPorts) }
    self.status = status
    if case .elsewhere(let what) = serving { taken = what } else { taken = nil }
    unreadable = serving == .unknown
  }

  private func turnOnHttps() async {
    askingHttps = true
    openLink(await app.tailscale.enableHttpsLink())
    askingHttps = false
  }

  private func start() async {
    busy = true
    error = nil
    do {
      try await app.startHosting()
    } catch {
      self.error = "The server didn’t start: \(error)"
    }
    busy = false
    if app.user == nil { error = error ?? app.authError }
  }

  /// Each step's done-ness, in order; nil before the first look.
  private var done: [Bool]? {
    guard let s = status else { return nil }
    let https = s.state == .running && s.https && s.dnsName != nil
    return [
      s.state != .missing,
      s.state == .loggedOut || s.state == .running,
      s.state == .running,
      https,
      https && taken == nil && !unreadable,
    ]
  }

  var body: some View {
    let done = done
    let current = done?.firstIndex(of: false)
    let allDone = done != nil && current == nil
    func state(_ i: Int) -> CheckState {
      guard let done else { return i == 0 ? .looking : .later }
      if done[i] && (current == nil || i < current!) { return .done }
      return i == current ? .now : .later
    }
    let ts = app.tailscale
    let commands = app.commands
    return VStack(alignment: .leading, spacing: 0) {
      SetupHeader(
        title: "On this computer",
        text:
          "PocketTerm runs your server here. Tailscale gives it a private HTTPS address that only your own devices "
          + "reach, at home or away. This list checks itself as you go.",
        onBack: onBack)
      Explainer("What is Tailscale, and why?", id: "why-tailscale") {
        Text(
          "Tailscale makes a private network between your own devices, wherever they are. Your phone reaches this "
            + "computer through it, and nothing on the internet can. Tailscale sees which of your devices connect "
            + "and when; PocketTerm’s messages are encrypted, so not what they say.")
      }
      .padding(.bottom, 10)
      VStack(alignment: .leading, spacing: 10) {
        CheckRow(
          state(0), state(0) == .done ? "Tailscale is installed" : "Install Tailscale",
          note:
            "Tailscale’s Personal plan is free (up to 3 users, 100 devices). Sign in with a personal Google, Apple, "
            + "GitHub or Microsoft account; a work email domain may start a paid business trial instead.",
          id: "check-installed"
        ) {
          if commands.brew != nil {
            ConfirmedCommand(
              commands: commands,
              label: "Install Tailscale",
              argv: PocketTermDesktop.Commands.tailscaleInstall,
              what: "Homebrew downloads Tailscale’s app from Tailscale and installs it. Then open it from here.",
              password: PocketTermDesktop.Commands.tailscalePassword,
              onDone: { Task { await look() } })
            Button("Download instead") { openLink(Tailscale.download) }
          } else {
            Button("Install Tailscale") { openLink(Tailscale.download) }
          }
        }
        CheckRow(
          state(1), state(1) == .done ? "Tailscale is running" : "Start Tailscale",
          note: "Open Tailscale and switch it on.", id: "check-running"
        ) {
          Button("Open Tailscale") { Task { await ts.open() } }
        }
        CheckRow(
          state(2), state(2) == .done ? "Signed in to Tailscale" : "Sign in to Tailscale",
          note: "Any account works: Google, GitHub, Microsoft or Apple. Use the same one on your phone.",
          id: "check-signed-in"
        ) {
          Button("Open Tailscale to sign in") { Task { await ts.open() } }
        }
        CheckRow(
          state(3), state(3) == .done ? "HTTPS certificates are on" : "Turn on HTTPS certificates",
          note:
            "On the Tailscale page that opens, turn on HTTPS (and MagicDNS, if it asks). Your phone then gets a "
            + "secure address for this computer. On a work tailnet only its admin can: ask them, or run your server "
            + "on a VPS instead.",
          id: "check-https"
        ) {
          Button(askingHttps ? "Opening…" : "Turn on HTTPS…") { Task { await turnOnHttps() } }
            .disabled(askingHttps)
            .accessibilityIdentifier("setup-turn-on-https")
          if let onOwnServer {
            Button("Use my own server instead", action: onOwnServer)
              .accessibilityIdentifier("setup-https-own-server")
          }
        }
        CheckRow(
          state(4),
          {
            switch state(4) {
            case .done: "Tailscale’s HTTPS port is free for PocketTerm"
            case .now: "Free Tailscale’s HTTPS port (443)"
            default: "Tailscale’s HTTPS port (443) for PocketTerm"
            }
          }(),
          note: taken.map {
            "Tailscale already serves \($0) there. PocketTerm needs that port and won’t replace it: remove it with "
              + "tailscale serve --https=443 off, or move it to another port (tailscale serve --https=8443 …). "
              + "This list checks again by itself."
          }
            ?? (unreadable
              ? "PocketTerm couldn’t read Tailscale’s Serve settings, so it doesn’t know yet whether that port is "
                + "free. This list checks again by itself." : nil),
          id: "check-serve-free")
      }
      Notice(text: phoneTailscaleNote, systemImage: "iphone", id: "setup-phone-tailscale")
        .padding(.top, 14)
      SetupButton(title: "Start", id: "setup-start-server", busy: busy, enabled: allDone) {
        Task { await start() }
      }
      .padding(.top, 18)
      if let error { SetupError(text: error, id: "setup-error") }
    }
    .task {
      while !Task.isCancelled {
        await look()
        try? await Task.sleep(nanoseconds: Self.poll)
      }
    }
  }
}
