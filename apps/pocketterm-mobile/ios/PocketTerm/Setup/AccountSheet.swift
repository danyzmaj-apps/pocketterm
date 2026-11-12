import PocketTermKit
import SwiftUI

/// The account sheet: who this phone is signed in as, notifications, the theme, the voice prompt's language,
/// leaving the server, the tips again and where the source is. Present it with `.sheet`; it shows its own
/// toasts.
struct AccountSheet: View {
  init(home: HomeModel) {
    self.home = home
    _app = ObservedObject(wrappedValue: home.app)
    _analytics = ObservedObject(wrappedValue: home.app.analytics)
  }

  let home: HomeModel
  @ObservedObject private var app: AppModel
  @ObservedObject private var analytics: Analytics
  @ObservedObject private var look = appearance
  @ObservedObject private var voice = VoiceLanguage.shared
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @State private var leaving = false
  /// The switch's new position while turning push on or off still waits (the phone, the server).
  @State private var switching: Bool?
  @State private var switchCount = 0

  var body: some View {
    NavigationStack {
      Form {
        Section { header }
        Section { notifications }
        // Only builds that can send them (a website id baked in) have the switch.
        if analytics.configured {
          Section { statistics }
        }
        Section {
          NavigationLink {
            ThemePicker(look: look)
          } label: {
            HStack(spacing: 12) {
              ThemeSwatch(choice: look.choice)
              VStack(alignment: .leading, spacing: 2) {
                Text("Theme")
                Text(look.choice.label).font(.subheadline).foregroundStyle(.secondary)
              }
            }
          }
          .accessibilityIdentifier("theme")
          NavigationLink {
            VoiceLanguagePicker()
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Voice prompt language")
                Text(voice.choice?.label ?? "Auto").font(.subheadline).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "character.bubble")
            }
          }
          .accessibilityIdentifier("voice-language-setting")
        }
        Section {
          Button("Leave this server", role: .destructive) { leaving = true }
            .accessibilityIdentifier("leave-server")
            .confirmationDialog("Leave this server?", isPresented: $leaving, titleVisibility: .visible) {
              Button("Leave", role: .destructive) {
                dismiss()
                Task { await app.signOut() }
              }
              .accessibilityIdentifier("leave-confirm")
            } message: {
              Text(
                "This phone signs out of \(app.userName) and forgets its computers\u{2019} keys. To come back, "
                  + "scan a computer\u{2019}s code again.")
            }
        }
        Section {
          Button {
            dismiss()
            app.tips.reset()
          } label: {
            Label("Show tips again", systemImage: "lightbulb")
          }
          .accessibilityIdentifier("show-tips")
          Button {
            openURL(Links.repo)
          } label: {
            Label("PocketTerm is open source: GitHub", systemImage: "arrow.up.right.square")
          }
          .accessibilityIdentifier("source-code")
        }
      }
      .navigationTitle("Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("account-done")
        }
      }
    }
    .toasts()
    // A token the server missed: try now, so the sheet shows how it stands, not how it stood.
    .task { await app.retryPush(force: true) }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Text(avatarLetter(app.userName))
        .font(.title2.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .background(Circle().fill(.tint))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.userName)
          .font(.headline)
          .lineLimit(2)
        Text("Signed in with your computer\u{2019}s code")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }

  /// Anonymous usage statistics on or off for this phone (off until turned on): which screens open and a few fixed
  /// facts about what happened, never what a session or terminal holds. Off forgets this phone's random id.
  private var statistics: some View {
    Toggle(isOn: Binding(get: { analytics.enabled }, set: { analytics.setEnabled($0) })) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Share anonymous usage statistics")
        Text(
          "Which screens you open and what works, never what your sessions or terminals hold. Sent to the "
            + "publisher\u{2019}s Umami in the EU."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("statistics-toggle")
  }

  @ViewBuilder private var notifications: some View {
    let on = app.pushEnabled ?? false
    // On here, off in the phone's Settings (changed there after saying yes): nothing shows.
    let blocked = on && app.notificationsAllowed == false
    let registering = on && !blocked && app.pushRegistering
    let unsent = on && !blocked && !registering && app.pushUnsent
    Toggle(isOn: Binding(get: { switching ?? on }, set: { setPush($0) })) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Notifications")
        if registering {
          HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Registering this phone with your server\u{2026}")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("push-registering")
        } else {
          Text(
            blocked
              ? pushBlocked
              : unsent
                ? pushNotSent
                : on
                  ? "Encrypted, through the push relay at push.danyzmaj.com."
                  : "Off: no notifications and no Lock Screen sessions."
          )
          .font(.subheadline)
          .foregroundStyle(blocked || unsent ? Color.orange : Color.secondary)
          .accessibilityIdentifier("push-status")
        }
      }
    }
    .accessibilityIdentifier("push-toggle")
    if blocked {
      Button("Open Settings") { Push.openSettings(notifications: true) }
        .accessibilityIdentifier("push-settings")
    }
  }

  /// Turns push on or off; the switch shows the new position until it's done. A later flip wins.
  private func setPush(_ on: Bool) {
    switchCount += 1
    let mine = switchCount
    switching = on
    Task {
      let allowed = await app.setPushEnabled(on)
      if mine == switchCount { switching = nil }
      if on && !allowed {
        Haptics.failed()
        toastPushNotAllowed(allowed: app.notificationsAllowed)
      }
    }
  }
}

/// The themes, each with its swatch: a tap shows one at once and keeps it for this phone (and switches the app
/// icon to match), and the page stays to try another.
private struct ThemePicker: View {
  @ObservedObject var look: Appearance

  var body: some View {
    Form {
      Section {
        ForEach(ThemeChoice.allCases, id: \.self) { choice in
          Button {
            look.choose(choice)
          } label: {
            HStack(spacing: 12) {
              ThemeSwatch(choice: choice)
              Text(choice.label).foregroundStyle(.primary)
              Spacer()
              if look.choice == choice {
                Image(systemName: "checkmark")
                  .fontWeight(.semibold)
                  .foregroundStyle(.tint)
              }
            }
            .contentShape(Rectangle())
          }
          .accessibilityAddTraits(look.choice == choice ? .isSelected : [])
          .accessibilityIdentifier("theme-\(choice.rawValue)")
        }
      } footer: {
        Text("Colours terminal screens, code and the accent, light or dark as the phone is. The app icon changes to match.")
      }
    }
    .sensoryFeedback(.selection, trigger: look.choice)
    .navigationTitle("Theme")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// A theme in small: its light half beside its dark half, each its background with its accent (iOS's own for
/// System) and its ok, attention and error colours.
struct ThemeSwatch: View {
  let choice: ThemeChoice

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    HStack(spacing: 0) {
      half(choice.light)
      half(choice.dark)
    }
    .frame(width: 64, height: 30)
    .clipShape(shape)
    .overlay(shape.strokeBorder(Color(.separator), lineWidth: 1))
    .accessibilityHidden(true)
  }

  private func half(_ t: PtTheme) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle().fill(t.tint).frame(height: 5)
      Spacer(minLength: 0)
      HStack(spacing: 2) {
        ForEach(Array([t.ok, t.warn, t.error].enumerated()), id: \.offset) { _, c in
          Circle().fill(c.color).frame(width: 4, height: 4)
        }
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(t.win.color)
  }
}
