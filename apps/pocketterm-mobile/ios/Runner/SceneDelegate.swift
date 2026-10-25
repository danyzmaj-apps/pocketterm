import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Until Flutter's first frame: the chosen theme's background, which the intro
    // (packages/pocketterm_core/lib/intro.dart) starts on, rather than the launch screen's, which can only
    // follow the system's light or dark.
    let background = ThemeBackground.color(dark: scene.traitCollectionIsDark)
    window?.backgroundColor = background
    if let flutter = window?.rootViewController as? FlutterViewController {
      let splash = UIView()
      splash.backgroundColor = background
      flutter.splashScreenView = splash
    }
  }
}

/// The background of the theme the person chose (packages/pocketterm_core/lib/theme.dart, kept by
/// shared_preferences as `flutter.theme`); Auto's, by the system's light or dark, when none is.
enum ThemeBackground {
  static func color(dark: Bool) -> UIColor {
    let rgb: UInt32 =
      switch UserDefaults.standard.string(forKey: "flutter.theme") {
      case "mocha": 0x1E1E2E
      case "dawn": 0xFAF4ED
      case "tokyoNight": 0x1A1B26
      case "gruvbox": 0x282828
      default: dark ? 0x1E1E2E : 0xFAF4ED
      }
    return UIColor(
      red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255,
      alpha: 1)
  }
}

extension UIScene {
  fileprivate var traitCollectionIsDark: Bool {
    (self as? UIWindowScene)?.traitCollection.userInterfaceStyle == .dark
  }
}
