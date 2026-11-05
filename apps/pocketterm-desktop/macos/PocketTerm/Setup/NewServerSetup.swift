import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// Not yet: the VPS's address, the commands that set the server up there, and checks that follow it live (the name
/// resolves, HTTPS answers, the server is healthy); once it is, its setup link.
struct NewServerSetup: View {
  let onBack: () -> Void
  var checks: any ServerChecks = NetworkServerChecks()

  @EnvironmentObject private var app: AppController
  @State private var address: String
  @State private var parsed: ServerAddress

  /// What the checks found for `checked`: nil until known.
  @State private var checked: String?
  @State private var resolves: Bool?
  @State private var https: Bool?
  @State private var healthy: Bool?
  @State private var healthProblem: String?

  /// This computer's clock is too far off the server's (`Backend.clockWarning`).
  @State private var clock: String?
  @State private var looking = false

  /// How often the checks look again.
  private static let poll: UInt64 = 3_000_000_000

  /// `address`: what was typed last time (`AppController.setupAddress`).
  init(address: String, onBack: @escaping () -> Void) {
    self.onBack = onBack
    _address = State(initialValue: address)
    _parsed = State(initialValue: ServerAddress.parse(address))
  }

  private func changed(_ text: String) {
    app.setSetupAddress(text)
    parsed = ServerAddress.parse(text)
    if parsed.domain != checked { Task { await look() } }
  }

  /// One round of checks on the address as it is now, each only once the one before passed. A healthy server isn't
  /// looked at again.
  private func look() async {
    let domain = parsed.domain
    if domain != checked {
      checked = domain
      resolves = nil
      https = nil
      healthy = nil
      healthProblem = nil
      clock = nil
    }
    guard let domain, healthy != true, !looking else { return }
    looking = true
    let resolves = await checks.resolves(domain)
    var https = false
    if resolves { https = await checks.https(domain) }
    var health: ServerHealth?
    if https { health = await checks.health(domain) }
    if checked == domain {
      self.resolves = resolves
      self.https = resolves ? https : nil
      healthy = health.map { $0.error == nil }
      healthProblem = health?.error
      clock = Backend.clockWarning(health?.clockOffset)
    }
    looking = false
    // The address changed while this round ran: look at the new one now.
    if domain != parsed.domain { Task { await look() } }
  }

  var body: some View {
    let domain = parsed.domain
    let typed = !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    VStack(alignment: .leading, spacing: 0) {
      SetupHeader(
        title: "Set up a server on a VPS",
        text:
          "Rent a small Linux VPS from any provider (1 GB of memory is plenty) and open a terminal on it with SSH. "
          + "What’s its address?",
        onBack: onBack)
      Explainer("What do Docker and Caddy do?", id: "why-docker") {
        Text(
          "Docker runs the PocketTerm server in a container, so nothing else on the VPS changes. Caddy runs next "
            + "to it: it answers on ports 80 and 443 and gets a free HTTPS certificate from Let’s Encrypt, renewing "
            + "it on its own. The server keeps your device list, computer names, pairing codes and push tokens, and "
            + "passes your encrypted messages along.")
      }
      .padding(.bottom, 10)
      TextField("203.0.113.7 or pocketterm.example.com", text: $address)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .onChange(of: address) { changed($0) }
        .accessibilityIdentifier("setup-address")
      if typed, let error = parsed.error {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 8)
          .accessibilityIdentifier("setup-address-error")
      }
      if let domain { server(domain) }
      Button("The full guide, with other ways to run it") { openLink(selfHostingGuide) }
        .buttonStyle(.link)
        .padding(.top, 14)
    }
    .task {
      while !Task.isCancelled {
        await look()
        try? await Task.sleep(nanoseconds: Self.poll)
      }
    }
  }

  @ViewBuilder private func server(_ domain: String) -> some View {
    (Text("Your server’s name: ")
      + Text(domain).fontWeight(.semibold).foregroundColor(.primary)
      + Text(
        domain.hasSuffix(".sslip.io")
          ? " (sslip.io turns the IP address into a name, so the server gets an HTTPS certificate)."
          : ". Point its DNS A record at the server first."))
      .font(.callout)
      .foregroundColor(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 8)
      .accessibilityIdentifier("setup-domain")
    Notice(
      text:
        "Ports 80 and 443 must be open to the internet: check your provider’s firewall. The server gets its "
        + "certificate from Let’s Encrypt, which checks port 80.",
      systemImage: "shield"
    )
    .padding(.top, 16)
    Text(
      "Run these on the server, not here. To get there, type this in Terminal (some providers sign you in as ubuntu "
        + "or debian instead of root):"
    )
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.top, 16)
    .padding(.bottom, 6)
    if let ssh = parsed.ssh { CopyCommand(ssh, id: "setup-ssh") }
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(vpsCommands(domain, Updater.version).enumerated()), id: \.offset) { i, c in
        Text("\(i + 1). \(c.title)").fontWeight(.semibold).padding(.top, 6)
        CopyCommand(c.command, id: "setup-command-\(i)")
      }
    }
    .padding(.top, 10)
    Text("Signed in as root? You can leave out sudo.")
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.top, 10)
    Text("Checking \(domain)").fontWeight(.semibold).padding(.top, 16).padding(.bottom, 6)
    checkRows(domain)
    if let clock {
      Notice(text: clock, systemImage: "clock", id: "setup-clock").padding(.top, 10)
    }
    if healthy == true {
      Text("Your server is up. Paste the setup link step 4 printed:")
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.bottom, 10)
      SetupLinkForm(checks: checks, clock: false)
    }
  }

  private func checkRows(_ domain: String) -> some View {
    func state(ok: Bool?, reached: Bool) -> CheckState {
      switch ok {
      case true?: .done
      case false?: .now
      case nil: reached ? .looking : .later
      }
    }
    let sslip = domain.hasSuffix(".sslip.io")
    return VStack(alignment: .leading, spacing: 10) {
      CheckRow(
        state(ok: resolves, reached: true), "\(domain) resolves",
        note: sslip
          ? "sslip.io doesn’t answer. Check this computer’s internet connection."
          : "Not yet. Add an A record for \(domain) with your server’s IP address; it can take a few minutes.",
        id: "check-dns")
      CheckRow(
        state(ok: https, reached: resolves ?? false), "HTTPS answers",
        note:
          "Not yet. Run steps 1 to 3. Getting the certificate takes a minute after the server starts; if it stays "
          + "here, open ports 80 and 443.",
        id: "check-https")
      CheckRow(
        state(ok: healthy, reached: https ?? false), "The PocketTerm server answers",
        note: healthProblem ?? "Not yet.", id: "check-health")
    }
  }
}
