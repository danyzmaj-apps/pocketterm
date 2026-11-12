import PocketTermKit
import SwiftUI
import UIKit

@main
struct PocketTermApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      RootView(app: delegate.app)
        .onOpenURL { delegate.app.openedLink($0) }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  /// The phone's session, made at launch from what it kept.
  private(set) lazy var app: AppModel = {
    timing("launch")
    let prefs = Preferences()
    // Before anything reads them: 0.1's Flutter preferences become the app's own.
    FlutterPreferences.migrate(prefs.defaults)
    appearance.load(prefs)
    // The first frame in the right half of the theme; the root follows changes (Style.swift's themed).
    appearance.follow(dark: UITraitCollection.current.userInterfaceStyle == .dark)
    VoiceLanguage.shared.load(prefs)
    let app = AppModel(prefs: prefs, device: UIDevice.current.name, analytics: AppAnalytics.shared)
    // The home screen icon follows the theme (kept: dropping it stops that).
    iconFollower = followAppIcon(appearance) { try await AppIcons.set($0) }
    // Started first: the first frame shows it's still reading what it kept, not setup.
    Task { await app.launch() }
    return app
  }()

  private var iconFollower: (@MainActor () -> Void)?

  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // First: a crash in what follows is reported too (store builds with a DSN only).
    ErrorReports.start()
    E2E.clearPreferencesIfAsked()
    // Before anything reads them: a reinstall doesn't pick up the last install's keys.
    PocketTermShared.wipeKeychainAfterInstall()
    // Before launch ends: the tap that launched the app comes next.
    Push.shared.install()
    SessionActivities.shared.install()
    // The per-phone push key from before end-to-end encryption: no server has a use for it now.
    PocketTermShared.defaults.removeObject(forKey: "pushKey")
    _ = app
    return true
  }

  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Push.shared.gotToken(deviceToken)
  }

  func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    Push.shared.failedToRegister()
  }
}
