import PocketTermKit
import UIKit
import UserNotifications

/// This iPhone's APNs token and notification permission, and what a tapped push opens.
final class Push: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Push()

  /// Waiting for APNs to hand over this iPhone's device token ([register]).
  private var waiter: CheckedContinuation<String?, Never>?
  /// Which [register] [waiter] belongs to, for its time limit.
  private var ask = 0

  /// How long APNs may take to hand over a token: it may never answer (no network).
  static let tokenWait: TimeInterval = 15

  /// Before launch ends: the tap that launched the app comes next.
  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  /// Permission first (a no-op after the first answer), then APNs. Nil: not allowed or no token (the phone
  /// gets no pushes then).
  func register() async -> String? {
    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    guard granted else { return nil }
    return await withCheckedContinuation { c in
      finish(nil)
      waiter = c
      ask += 1
      let mine = ask
      UIApplication.shared.registerForRemoteNotifications()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(Self.tokenWait))
        guard let self, self.ask == mine else { return }
        self.finish(nil)
      }
    }
  }

  func gotToken(_ deviceToken: Data) {
    finish(deviceToken.map { String(format: "%02x", $0) }.joined())
  }

  func failedToRegister() { finish(nil) }

  private func finish(_ token: String?) {
    let c = waiter
    waiter = nil
    c?.resume(returning: token)
  }

  /// Whether notifications show; provisional (quiet) delivery counts: they still arrive.
  func allowed() async -> Bool {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
  }

  /// PocketTerm's page in Settings, or its notification settings.
  static func openSettings(notifications: Bool = false) {
    let url = notifications ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
    if let url = URL(string: url) { UIApplication.shared.open(url) }
  }

  // MARK: Taps

  /// The coding session (routed key) a tapped terminal push is about, until the home page takes it.
  private var tappedSession: String?

  /// Called when a push is tapped; the home page then takes it with [takeTappedSession].
  var onTapped: (() -> Void)?

  func takeTappedSession() -> String? {
    defer { tappedSession = nil }
    return tappedSession
  }

  /// A push arriving while PocketTerm is open still shows.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    // A push carries its kind and session in userInfo (PocketTermPush).
    let info = response.notification.request.content.userInfo
    guard info["kind"] as? String == "terminal" else { return }
    let session = info["session"] as? String
    await MainActor.run {
      self.tappedSession = session
      self.onTapped?()
    }
  }
}
