import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Until Flutter's first frame: the intro's first frame (packages/pocketterm_core/lib/intro.dart) in the chosen
    // theme, its icon on its background, rather than the launch screen's, which is always Catppuccin Mocha's.
    let theme = LaunchTheme.chosen
    window?.backgroundColor = theme.background
    if let flutter = window?.rootViewController as? FlutterViewController {
      flutter.splashScreenView = LaunchTheme.splash(theme)
    }
  }
}

/// The theme the person chose (packages/pocketterm_core/lib/theme.dart, kept by shared_preferences as
/// `flutter.theme`); Catppuccin Mocha when none is (or 0.1.2's `auto`). Its background and launch icon
/// (LaunchIcon<Theme>, drawn by test/screenshots/launch_image_test.dart).
enum LaunchTheme {
  case mocha, dawn, tokyoNight, gruvbox

  static var chosen: LaunchTheme {
    switch UserDefaults.standard.string(forKey: "flutter.theme") {
    case "dawn": .dawn
    case "tokyoNight": .tokyoNight
    case "gruvbox": .gruvbox
    default: .mocha
    }
  }

  var background: UIColor {
    let rgb: UInt32 =
      switch self {
      case .mocha: 0x1E1E2E
      case .dawn: 0xFAF4ED
      case .tokyoNight: 0x1A1B26
      case .gruvbox: 0x282828
      }
    return UIColor(
      red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255,
      alpha: 1)
  }

  var icon: UIImage? {
    let name =
      switch self {
      case .mocha: "LaunchIconMocha"
      case .dawn: "LaunchIconDawn"
      case .tokyoNight: "LaunchIconTokyoNight"
      case .gruvbox: "LaunchIconGruvbox"
      }
    return UIImage(named: name)
  }

  /// [theme]'s background with its icon where the intro starts it: centred, 42% of the screen's short side across,
  /// at most 360 pt (as LaunchScreen.storyboard lays it out).
  static func splash(_ theme: LaunchTheme) -> UIView {
    let splash = UIView()
    splash.backgroundColor = theme.background
    let icon = UIImageView(image: theme.icon)
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    icon.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    splash.addSubview(icon)
    let asWide = icon.widthAnchor.constraint(equalTo: splash.widthAnchor, multiplier: 0.42)
    asWide.priority = .defaultHigh
    NSLayoutConstraint.activate([
      icon.centerXAnchor.constraint(equalTo: splash.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: splash.centerYAnchor),
      icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
      icon.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
      icon.widthAnchor.constraint(lessThanOrEqualTo: splash.heightAnchor, multiplier: 0.42),
      asWide,
    ])
    return splash
  }
}
