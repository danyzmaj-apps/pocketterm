import PocketTermKit
import SwiftUI
import UIKit

/// The app's usage statistics ([Analytics] in PocketTermKit): counted under the Umami website id the build baked
/// into Info.plist (`UmamiWebsiteID`, from the UMAMI_WEBSITE_ID build setting); without one, and in a test run,
/// nothing is ever recorded and the account sheet has no switch for it. Off until the person turns it on.
enum AppAnalytics {
  static let shared: Analytics = {
    let id = Bundle.main.object(forInfoDictionaryKey: "UmamiWebsiteID") as? String
    let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    return Analytics(target: testing ? nil : .of(id), device: { .current }, prefs: Preferences())
  }()
}

extension AnalyticsDevice {
  /// What Umami reads this phone as: a browser-like User-Agent with the iOS version (Umami drops bot-like ones),
  /// the screen in points, the language and the app's version. Never the phone's name.
  static var current: AnalyticsDevice {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let os = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
    let bounds = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
    return AnalyticsDevice(
      platform: "ios",
      hostname: "ios.pocketterm.app.danyzmaj.com",
      userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) PocketTerm/\(version)",
      screen: bounds.map { "\(Int($0.width))x\(Int($0.height))" } ?? "",
      language: Locale.preferredLanguages.first ?? "en",
      appVersion: version)
  }
}

extension View {
  /// A screen view each time this screen appears; [name] one of [AnalyticsEvents.screens].
  func analyticsScreen(_ name: String) -> some View {
    onAppear { AppAnalytics.shared.screen(name) }
  }
}
