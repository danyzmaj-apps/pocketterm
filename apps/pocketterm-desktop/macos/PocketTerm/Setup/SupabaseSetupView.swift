import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// The three options side by side (the first-run setup's choice).
struct OptionsTable: View {
  private static let rows: [[String]] = [
    ["", "On this computer", "On my own server", "Supabase"],
    ["Who runs the server", "This computer (built in)", "You, on a VPS you rent", "Supabase, in a region you pick"],
    ["Who holds the metadata", "Only you", "You and your VPS host", "Supabase"],
    ["Reached through", "Tailscale", "Your domain (HTTPS)", "supabase.co"],
    ["Cost", "Free", "A VPS", "Free plan (pauses after a week unused)"],
    ["This computer must be awake", "Yes", "Yes (your sessions run on it)", "Yes (your sessions run on it)"],
    ["Contents end-to-end encrypted", "Yes", "Yes", "Yes"],
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 5) {
        ForEach(Array(Self.rows.enumerated()), id: \.offset) { i, row in
          if i > 0 { Divider() }
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { j, cell in
              Text(cell)
                .fontWeight(i == 0 ? .semibold : .regular)
                .foregroundColor(i == 0 || j == 0 ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      .font(.caption)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("compare-table")
      Text(
        "Your sessions, images, files and notification text are end-to-end encrypted in all three: whoever runs "
          + "the server passes them along but can’t read them. Your sessions always run on this computer, so it has "
          + "to be awake with every option.")
    }
  }
}

/// Supabase: paste the setup link of a computer already on a project, or set a project up. Setting up asks for a
/// personal access token after saying what it covers and what Supabase holds, then a project (a new one in the
/// picked organization and region, or the one PocketTerm is already on there), then runs `SupabaseSetup` step by
/// step and signs this computer in with the link it makes. The token lives only in this screen.
struct SupabaseSetupView: View {
  let onBack: () -> Void
  var checks: any ServerChecks = NetworkServerChecks()
  var tools = SupabaseTools()

  private enum Stage { case choose, paste, token, project, progress }

  @EnvironmentObject private var app: AppController
  @State private var stage = Stage.choose
  @State private var token = ""
  @State private var admin: SupabaseAdmin?

  /// Bumped whenever the work under way no longer counts (Back, a new token).
  @State private var run = 0
  @State private var busy = false
  @State private var error: String?

  @State private var orgs: [SupabaseOrg]?
  @State private var org: String?
  @State private var region = "eu-central-1"

  /// The project PocketTerm is on already in `org`, if any.
  @State private var existing: SupabaseProject?

  /// Being set up; kept so Retry picks up where it stopped.
  @State private var ref: String?
  @State private var done = Set<SupabaseStep>()
  @State private var current: SupabaseStep?
  @State private var waiting = false

  /// Forgets the token and the work done with it.
  private func drop() {
    run += 1
    admin?.close()
    admin = nil
    token = ""
    busy = false
    error = nil
    orgs = nil
    org = nil
    existing = nil
    ref = nil
    done.removeAll()
    current = nil
    waiting = false
  }

  private func back() {
    if stage == .choose { return onBack() }
    drop()
    stage = .choose
  }

  private func why(_ e: Error) -> String {
    (e as? AdminException)?.message ?? "Something went wrong: \(e)"
  }

  private func proceed() async {
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.hasPrefix("sbp_") else {
      error = "That isn’t a Supabase access token. It starts with sbp_."
      return
    }
    run += 1
    let run = run
    admin?.close()
    let admin = tools.admin(token)
    self.admin = admin
    busy = true
    error = nil
    do {
      let orgs = try await admin.organizations()
      guard run == self.run else { return }
      if orgs.isEmpty { throw AdminException("This Supabase account has no organization. Create one first.") }
      self.orgs = orgs
      stage = .project
      busy = false
      if orgs.count == 1 { await pickOrg(orgs[0].slug) }
    } catch {
      guard run == self.run else { return }
      busy = false
      self.error = why(error)
    }
  }

  /// Picks `slug` and looks for a project PocketTerm is on there already (best effort: one that can't be asked
  /// counts as not).
  private func pickOrg(_ slug: String) async {
    guard let admin else { return }
    run += 1
    let run = run
    org = slug
    existing = nil
    busy = true
    error = nil
    let found = await tools.existingProject(admin, org: slug)
    guard run == self.run else { return }
    existing = found
    busy = false
  }

  private func create() async {
    guard let admin, let org else { return }
    run += 1
    let run = run
    busy = true
    error = nil
    do {
      let project = try await admin.createProject(
        org: org, name: "PocketTerm", region: region, dbPassword: newDatabasePassword())
      guard run == self.run else { return }
      ref = project.ref
      await setUp()
    } catch {
      guard run == self.run else { return }
      busy = false
      self.error = why(error)
    }
  }

  private func update() async {
    ref = existing?.ref
    await setUp()
  }

  /// Runs the setup on `ref` from where it stopped, then signs in.
  private func setUp() async {
    guard let admin, let ref else { return }
    run += 1
    let run = run
    stage = .progress
    busy = true
    error = nil
    waiting = false
    // The step that failed runs again; it isn't done.
    current = nil
    do {
      let link = try await tools.setup(admin, ref).run(
        onStep: { step in
          Task { @MainActor in
            guard run == self.run else { return }
            if let c = current { done.insert(c) }
            current = step
            waiting = false
          }
        },
        onWait: {
          Task { @MainActor in
            if run == self.run { waiting = true }
          }
        },
        done: done)
      guard run == self.run else { return }
      await app.connectLink(link)
      if app.user != nil {
        // Signed in: the window moves on; the token and the admin go now.
        drop()
        return
      }
      let why = app.authError ?? "The setup link didn’t sign this computer in."
      if app.backend != nil { await app.disconnect() }
      throw AdminException(why)
    } catch {
      guard run == self.run else { return }
      busy = false
      waiting = false
      self.error = why(error)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch stage {
      case .choose: choose
      case .paste: paste
      case .token: tokenScreen
      case .project: projectScreen
      case .progress: progress
      }
    }
    // The token lives only in this screen.
    .onDisappear { drop() }
  }

  @ViewBuilder private var choose: some View {
    SetupHeader(title: "Supabase", text: "Is PocketTerm already on a Supabase project of yours?", onBack: back)
    VStack(spacing: 12) {
      SetupOption(
        id: "supabase-paste", systemImage: "link", title: "Paste a setup link",
        text:
          "Another computer of yours already uses it: open Settings, Account, Add a computer… there and paste its "
          + "link here."
      ) { stage = .paste }
      SetupOption(
        id: "supabase-new", systemImage: "plus.circle", title: "Set up a project",
        text:
          "PocketTerm makes a free project in your Supabase account and sets it up. It takes a few minutes."
      ) { stage = .token }
    }
  }

  @ViewBuilder private var paste: some View {
    SetupHeader(
      title: "Paste a setup link",
      text:
        "On a computer already signed in to your Supabase project, open Settings, Account, Add a computer… and copy "
        + "the link it shows.",
      onBack: back)
    SetupLinkForm(checks: checks)
  }

  private func para(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).fontWeight(.semibold)
      Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var errorText: some View {
    if let error { SetupError(text: error, id: "supabase-error") }
  }

  @ViewBuilder private var tokenScreen: some View {
    SetupHeader(
      title: "Set up a Supabase project",
      text:
        "PocketTerm makes a free project in your Supabase account and puts its server there. First, what that "
        + "means.",
      onBack: back)
    VStack(alignment: .leading, spacing: 14) {
      para(
        "What stays private",
        "Your sessions, images, files and notification text stay end-to-end encrypted, exactly as with the other "
          + "options. The project only passes them along, sealed.")
      para(
        "What Supabase holds",
        "Supabase, in the region you pick, holds what any PocketTerm server holds: your list of devices (names, "
          + "platforms, when they were added and last seen), your computers’ names, your phones’ push tokens, "
          + "pairing codes for 10 minutes, and when messages and pushes go through. Supabase also sees the IP "
          + "addresses your devices connect from.")
      para(
        "Signing out a device",
        "A phone or computer you sign out hears it at once and is refused at its next connection. At most its "
          + "live connection lasts until its 10-minute token runs out, and what it gets stays sealed.")
      para(
        "Free projects pause",
        "Supabase pauses a free project after about a week without use. Restore it at supabase.com/dashboard. "
          + "The free plan allows 2 active projects per account.")
      para(
        "Your access token",
        "PocketTerm needs a personal access token to make and set up the project. It covers your whole Supabase "
          + "organization, every project in it. PocketTerm uses it only during this setup and never stores it. "
          + "Best: give PocketTerm a Supabase organization of its own, and delete the token once this is done.")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("supabase-security")
    HStack(alignment: .firstTextBaseline) {
      Text("Create a token at supabase.com/dashboard/account/tokens, then paste it here.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer()
      Button("Create a token") { openLink(supabaseTokensPage) }
        .buttonStyle(.link)
        .accessibilityIdentifier("supabase-open-tokens")
    }
    .padding(.top, 16)
    SecureField("sbp_…", text: $token)
      .textFieldStyle(.roundedBorder)
      .disabled(busy)
      .onSubmit { Task { await proceed() } }
      .accessibilityIdentifier("supabase-token")
      .padding(.top, 8)
    SetupButton(title: "Continue", id: "supabase-continue", busy: busy) { Task { await proceed() } }
      .padding(.top, 14)
    errorText
  }

  @ViewBuilder private var projectScreen: some View {
    SetupHeader(
      title: "Choose where it goes", text: "PocketTerm makes a new project called PocketTerm. It touches no other.",
      onBack: back)
    Text("Organization").font(.callout).foregroundStyle(.secondary).padding(.bottom, 6)
    Picker(
      "Organization",
      selection: Binding(get: { org }, set: { slug in if let slug { Task { await pickOrg(slug) } } })
    ) {
      if org == nil { Text("Choose…").tag(String?.none) }
      ForEach(orgs ?? [], id: \.slug) { o in
        Text(o.plan.isEmpty ? o.name : "\(o.name) (\(o.plan) plan)").tag(Optional(o.slug))
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .disabled(busy)
    .accessibilityIdentifier("supabase-org")
    if let existing {
      Notice(
        text:
          "PocketTerm is already on \(existing.name) in this organization. Update that project instead of making "
          + "another: every phone and computer on it stays signed in.",
        id: "supabase-existing"
      )
      .padding(.top, 14)
      SetupButton(title: "Update that project", id: "supabase-update", busy: busy) { Task { await update() } }
        .padding(.top, 14)
    } else {
      Text("Region").font(.callout).foregroundStyle(.secondary).padding(.top, 14).padding(.bottom, 6)
      Picker("Region", selection: $region) {
        ForEach(Array(supabaseRegions), id: \.key) { r in Text(r.value).tag(r.key) }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .disabled(busy)
      .accessibilityIdentifier("supabase-region")
      Text("Pick one near you: your device list is kept there.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
      SetupButton(title: "Create the project", id: "supabase-create", busy: busy, enabled: org != nil) {
        Task { await create() }
      }
      .padding(.top, 14)
    }
    errorText
  }

  @ViewBuilder private var progress: some View {
    SetupHeader(title: "Setting up your project", text: "This takes a few minutes. Keep this window open.", onBack: back)
    VStack(alignment: .leading, spacing: 10) {
      ForEach(SupabaseStep.allCases, id: \.self) { step in
        CheckRow(
          done.contains(step) ? .done : step == current ? (error == nil ? .looking : .now) : .later,
          step.label, id: "supabase-step-\(step.rawValue)")
      }
    }
    if waiting {
      Notice(
        text: "Supabase lets a project change its signing key only every few minutes. Waiting…",
        systemImage: "clock", id: "supabase-wait"
      )
      .padding(.top, 12)
    }
    if error != nil {
      errorText
      Button { Task { await setUp() } } label: { Text("Retry").frame(maxWidth: .infinity) }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier("supabase-retry")
        .padding(.top, 14)
    }
  }
}
