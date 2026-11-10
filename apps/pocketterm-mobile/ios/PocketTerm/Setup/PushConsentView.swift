import PocketTermKit
import SwiftUI

/// Turned on, but the phone said no: the system setting is off.
let pushNotAllowed =
  "Notifications are off for PocketTerm in this phone\u{2019}s Settings. Allow them there, then try again."

/// Turned on and allowed, but Apple gave this phone no push address (no internet, or its service didn't answer).
let pushNoToken =
  "This phone couldn\u{2019}t get a notification address from Apple or Google. Check its internet connection, "
  + "then try again."

/// On here, but turned off since in the phone's Settings: nothing shows.
let pushBlocked =
  "On, but notifications are off for PocketTerm in this phone\u{2019}s Settings, so none show. Allow them there."

/// On here, but the server couldn't be reached to take this phone's token.
let pushNotSent =
  "On, but your server could not be reached to register this phone. PocketTerm tries again as soon as it can."

/// Why turning push on didn't take: the phone's setting is off ([allowed] false: with the way to Settings) or
/// Apple gave no push address.
func toastPushNotAllowed(allowed: Bool?) {
  if allowed == false {
    Toaster.shared.show(pushNotAllowed, action: "Settings") { Push.openSettings(notifications: true) }
  } else {
    Toaster.shared.show(pushNoToken)
  }
}

/// After the first sign-in on a server, before anything registers for push: what notifications go through and
/// who runs it, then the person's choice ([AppModel.setPushEnabled]). The account sheet's Notifications switch
/// changes it later.
struct PushConsentView: View {
  init(app: AppModel) { self.app = app }

  @ObservedObject var app: AppModel
  @State private var busy = false

  var body: some View {
    // The choice stays in reach; what it's about scrolls above it.
    ScrollView {
      VStack(spacing: 0) {
        Image(systemName: "bell.badge")
          .font(.system(size: 48))
          .foregroundStyle(.tint)
          .symbolRenderingMode(.hierarchical)
          .padding(.bottom, 16)
          .accessibilityHidden(true)
        Text("Know when a session needs you")
          .font(.title2.weight(.semibold))
          .multilineTextAlignment(.center)
          .padding(.bottom, 10)
        Text(
          "Your computer tells this phone when a coding session finishes or asks something, even while PocketTerm "
            + "is closed."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.bottom, 24)
        PushExplainer()
      }
      .padding(24)
      .frame(maxWidth: 460)
      .frame(maxWidth: .infinity)
    }
    .background(Color(.systemGroupedBackground))
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 6) {
        Button {
          choose(true)
        } label: {
          Group {
            if busy {
              ProgressView()
            } else {
              Text("Turn on notifications")
            }
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(busy)
        .accessibilityIdentifier("push-accept")
        // Never waits on anything: the way out while Turn on still waits on the phone.
        Button("Not now") { choose(false) }
          .controlSize(.large)
          .accessibilityIdentifier("push-not-now")
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 12)
      .frame(maxWidth: 460)
      .frame(maxWidth: .infinity)
      .background(.bar)
    }
  }

  private func choose(_ on: Bool) {
    if on { busy = true }
    Task {
      let allowed = await app.setPushEnabled(on)
      if on && !allowed {
        Haptics.failed()
        toastPushNotAllowed(allowed: app.notificationsAllowed)
      }
      if on { busy = false }
    }
  }
}

/// Where notifications go and what each one on the way can see.
struct PushExplainer: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Point(
        symbol: "server.rack",
        text: "Notifications pass through PocketTerm\u{2019}s push relay, a small service the developer (Danijel "
          + "Lovric) runs on his own server in Croatia, in the EU. It can\u{2019}t read them: your computer encrypts "
          + "each notification so that only your phone can open it. The relay just hands it to Apple or Google to "
          + "deliver. It never learns which computer or session a notification is about, and it keeps nothing.")
      Point(
        symbol: "lock",
        text: "The relay and Apple see an encrypted message, this phone\u{2019}s push token and when it was sent, "
          + "never which computer or session it is about. Your computer encrypts each notification with the key "
          + "from its code, and only your phones open it.")
      Point(
        symbol: "lock.iphone",
        text: "When you follow a session, iOS shows its state on the Lock Screen: working, needs you, or finished. "
          + "Apple doesn\u{2019}t let apps decrypt these updates, so this state travels unencrypted. It never "
          + "includes any text from your sessions, and it carries no names, folders or ids.")
      Point(symbol: "switch.2", text: "Change your mind any time: Account \u{2192} Notifications.")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private struct Point: View {
    let symbol: String
    let text: String

    var body: some View {
      Label {
        Text(text).font(.subheadline)
      } icon: {
        Image(systemName: symbol).foregroundStyle(.secondary)
      }
      .labelStyle(.titleAndIcon)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
