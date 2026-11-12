import PocketTermKit
import SwiftUI

/// The home page: the selected computer's name as the title, its menu picking another computer (or scanning one's
/// code); Account (Exit demo in the demo); and below, the computer's sessions and windows, or why there are none
/// to show.
struct HomeView: View {
  @ObservedObject var home: HomeModel

  init(home: HomeModel) { self.home = home }

  var body: some View {
    HomeContent(home: home, app: home.app, desktops: home.desktops)
  }
}

/// [HomeView]'s body, watching what it shows: the sign-in and preferences ([app]) and the computers ([desktops]).
private struct HomeContent: View {
  @ObservedObject var home: HomeModel
  @ObservedObject var app: AppModel
  @ObservedObject var desktops: Desktops

  @State private var account = false
  @State private var scanning = false

  var body: some View {
    let selected = desktops.selected
    Group {
      if let remote = home.remote {
        // A new list for each computer: what it scrolled and ranked is that computer's.
        TerminalList(home: home, app: app, tips: app.tips, remote: remote, computer: selected?.name)
          .id(ObjectIdentifier(remote))
      } else if let selected, home.locked(selected) {
        LockedComputer(computer: selected.name) { scanning = true }
      } else {
        waiting(selected)
      }
    }
    .navigationTitle(selected?.name ?? "Terminal")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarTitleMenu { computerMenu }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if home.isDemo {
          Button("Exit demo") { app.exitDemo() }
            .accessibilityIdentifier("exit-demo")
        } else {
          Button {
            // A token the server missed: try now, so the sheet shows how it stands, not how it stood.
            Task { await app.retryPush(force: true) }
            account = true
          } label: {
            AccountAvatar(name: app.userName)
          }
          .accessibilityLabel("Account")
          .accessibilityIdentifier("account")
        }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if home.isDemo { DemoBanner() }
    }
    .sheet(isPresented: $account) {
      AccountSheet(home: home).analyticsScreen("settings")
    }
    .fullScreenCover(isPresented: $scanning) {
      ScanSheet(signedIn: true) { link in
        scanning = false
        if let link { Task { await home.scanned(link) } }
      }
      .toasts()
      .analyticsScreen("scan")
    }
  }

  /// No computer to show yet: reaching the selected one, none reporting, or the list not come (with Retry).
  @ViewBuilder
  private func waiting(_ selected: Desktop?) -> some View {
    let text =
      selected.map { "Reaching \($0.name)…" }
      ?? (desktops.loaded ? HomeModel.noDesktop : home.desktopsError ?? "Looking for your computers…")
    ScrollView {
      VStack(spacing: 16) {
        if selected != nil || (!desktops.loaded && desktops.error == nil) { ProgressView() }
        Text(text)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        // The list didn't come: asked again now, not at the next 30-second refresh.
        if selected == nil && desktops.error != nil && !home.isDemo {
          Button("Retry") { home.retryComputers() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("computers-retry")
        }
      }
      .padding(32)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.center)
  }

  /// The title's menu: the account's computers, the one shown ticked, and scanning another's code.
  @ViewBuilder
  private var computerMenu: some View {
    Section("Computers") {
      if desktops.all.isEmpty {
        Text(desktops.loaded ? HomeModel.noDesktop : home.desktopsError ?? "Looking for your computers…")
      }
      ForEach(desktops.all) { d in
        Toggle(
          isOn: Binding(
            get: { desktops.selected?.id == d.id },
            set: { _ in home.select(d) })
        ) {
          // Two Texts straight in the label: a menu shows the second as the item's subtitle. Inside a Label
          // (for the icon) the menu dropped it, and with it whether the computer is online or locked.
          Text(d.name)
          Text(home.locked(d) ? "Locked: scan its code" : d.online ? "Online" : "Seen \(ago(d.seenAt))")
        }
        .accessibilityIdentifier("desktop-\(d.id)")
      }
    }
    // The menu opened: the list is fetched fresh.
    .onAppear { home.pickingComputer() }
    Section {
      Button {
        scanning = true
      } label: {
        Label("Scan a computer\u{2019}s code", systemImage: "qrcode.viewfinder")
      }
      .accessibilityIdentifier("scan-computer")
    }
  }
}

/// The person's letter in a circle, for the Account button; VoiceOver reads the button as Account instead.
private struct AccountAvatar: View {
  let name: String
  @EnvironmentObject private var look: Appearance

  var body: some View {
    Text(avatarLetter(name))
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .frame(width: 30, height: 30)
      .background(Circle().fill(look.theme.tint))
      .accessibilityHidden(true)
  }
}

/// Says the demo is one, under the computer's title.
private struct DemoBanner: View {
  @EnvironmentObject private var look: Appearance

  var body: some View {
    HStack(spacing: 10) {
      Text("DEMO")
        .font(.caption.weight(.bold))
        .tracking(1)
        .foregroundStyle(look.theme.tint)
      Text("Made-up sessions on a pretend computer. Nothing leaves this phone.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(look.theme.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("demo-banner")
  }
}

/// The selected computer, while this phone has no key for it: nothing from it shows and nothing goes to it until
/// its code is scanned.
private struct LockedComputer: View {
  let computer: String
  let onScan: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Scan this computer\u{2019}s code to connect", systemImage: "lock")
    } description: {
      Text(
        "Its sessions are end-to-end encrypted with a key only its code holds. On \(computer), open Settings → Phone "
          + "→ Add a phone…")
    } actions: {
      Button(action: onScan) {
        Label("Scan", systemImage: "qrcode.viewfinder")
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("scan-locked-computer")
    }
  }
}
