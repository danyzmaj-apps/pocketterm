import AppKit
import Combine
import PocketTermDesktop
import PocketTermKit
import SwiftUI
import SystemConfiguration

/// Settings' tabs, in the toolbar's order.
enum SettingsTab: String, CaseIterable, Identifiable {
  case phone, agents, terminals, account

  var id: String { rawValue }

  var label: String {
    switch self {
    case .phone: "Phone"
    case .agents: "Coding agents"
    case .terminals: "Terminals"
    case .account: "Account"
    }
  }

  /// The toolbar's symbol.
  var symbol: String {
    switch self {
    case .phone: "iphone"
    case .agents: "sparkles"
    case .terminals: "terminal"
    case .account: "person.crop.circle"
    }
  }
}

/// What the windows show beyond the controller's state: Settings' tab, and the sheets the menu-bar panel asks for.
@MainActor
final class UIState: ObservableObject {
  /// The Settings tab showing.
  @Published var settingsTab = SettingsTab.phone
  /// The pairing QR (Add a phone…), over Settings → Phone.
  @Published var pairingShown = false
  /// What a link said while signed in (`AppController.notices`, e.g. one for another server), until closed.
  @Published var notice: String?
}

/// The app's parts, made once at launch (what lib/main.dart did): the controller, the local API, the theme, the
/// windows, the menu-bar item and the updater.
@MainActor
final class AppModel {
  static private(set) var shared: AppModel!

  let prefs: UserDefaultsPreferenceStore
  let app: AppController
  let api: LocalApi
  let host: MacHost
  let ui = UIState()
  let updater = Updater()
  let status: StatusModel
  let windows: WindowRouter
  private(set) var statusItem: StatusItem!
  private var stopIcon: (() -> Void)?
  private var started = false
  private var links: [URL] = []
  #if DEBUG || POCKETTERM_SMOKE
    /// tool/e2e's requests, in a run of it (App/E2E.swift).
    private var e2e: E2EControl?
  #endif

  init() {
    let env = testHooks()
    let profile = env["POCKETTERM_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
    let defaults = Self.defaults(profile: profile)
    // Flutter's shared_preferences kept every key as flutter.<key>: once, they become <key>.
    _ = migrateFlutterPreferences(defaults)
    prefs = UserDefaultsPreferenceStore(defaults)
    appearance.load(prefs)
    let windows = WindowRouter()
    windows.remembersFrames = profile == nil
    self.windows = windows
    host = MacHost(
      showWindow: { windows.show() }, hideWindow: { windows.hideAll() }, mainWindow: { windows.visibleWindow })
    let serverDir = Self.serverDir(env: env, profile: profile)
    #if DEBUG || POCKETTERM_SMOKE
      app =
        E2E.controller(prefs: prefs, device: Self.deviceName(), host: host, serverDir: serverDir)
        ?? AppController(prefs: prefs, device: Self.deviceName(), host: host, serverDir: serverDir)
    #else
      app = AppController(prefs: prefs, device: Self.deviceName(), host: host, serverDir: serverDir)
    #endif
    api = LocalApi(live: app.live)
    status = StatusModel(app: app)
    Self.shared = self
  }

  /// The preferences: the app's own, or, for a test build's throwaway profile (tool/smoke, the UI tests), a
  /// domain of its own so the person's PocketTerm keeps its settings.
  private static func defaults(profile: String?) -> UserDefaults {
    guard let profile, let id = Bundle.main.bundleIdentifier else { return .standard }
    return UserDefaults(suiteName: "\(id).\(profile)") ?? .standard
  }

  /// The built-in server's data: app support, or for a test build's profile a folder of its own under its HOME
  /// (the person's PocketTerm may be running its own server on theirs, and holds its lock).
  private static func serverDir(env: [String: String], profile: String?) -> (() -> URL)? {
    guard let profile else { return nil }
    let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    let bundle = Bundle.main.bundleIdentifier ?? "com.danyzmaj.pocketterm"
    let dir = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support")
      .appendingPathComponent(bundle).appendingPathComponent("pocketterm-server-\(profile)")
    return { dir }
  }

  /// What this Mac calls itself (System Settings → General → Sharing), as `Host.localizedName` gives it, without
  /// its network lookups.
  private static func deviceName() -> String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
  }

  /// After the menu bar exists: the menu-bar item, the Dock icon following the theme, the local API, then the
  /// controller (which opens the window when there's nothing to do but set up or sign in).
  func launch() {
    statusItem = StatusItem(model: self)
    windows.attach(self)
    stopIcon = followAppIcon(appearance) { [host] in await host.setAppIcon($0) }
    let notices = app.notices
    Task { [ui] in
      for await message in notices { ui.notice = message }
    }
    Task {
      do {
        try await api.start()
        app.onQuit = { [api] in await api.stop() }
      } catch {
        debugLog("PocketTerm: terminal API unavailable: \(error)")
      }
      await app.start()
      #if DEBUG || POCKETTERM_SMOKE
        if let dir = E2E.dir {
          e2e = E2EControl(app, dir: dir)
          e2e?.start()
        }
      #endif
      started = true
      for link in links { app.openedLink(link) }
      links = []
    }
  }

  /// A pocketterm:// link the app was opened with (a setup link, a phone's code); kept until the controller
  /// has started.
  func open(_ url: URL) {
    guard url.scheme == "pocketterm" else { return }
    if started { app.openedLink(url) } else { links.append(url) }
  }

  /// The menu-bar panel's and the menus' ways in.
  func openMain() { host.event("openMain") }

  func openSettings(_ tab: SettingsTab? = nil) {
    if let tab { ui.settingsTab = tab }
    host.event("openSettings")
  }

  func addPhone() {
    ui.settingsTab = .phone
    ui.pairingShown = true
    host.event("openSettings")
  }
}

/// The views' shared objects, for any window's root.
extension View {
  func appEnvironment(_ model: AppModel) -> some View {
    modifier(AppEnvironment(model: model))
  }
}

private struct AppEnvironment: ViewModifier {
  let model: AppModel
  @ObservedObject private var looks = appearance

  func body(content: Content) -> some View {
    content
      .environmentObject(model.app)
      .environmentObject(model.ui)
      .environmentObject(model.status)
      .environmentObject(model.updater)
      .environmentObject(appearance)
      // The theme colors the accent; the rest follows macOS, light or dark.
      .tint(themeAccent(looks.choice))
      .accentColor(themeAccent(looks.choice))
  }
}

/// [choice]'s accent: the Mac's own (System Settings → Appearance) for System, else the light palette's in light
/// mode and the dark one's in dark mode, switching with the appearance.
func themeAccent(_ choice: ThemeChoice) -> Color {
  if choice.platformAccent { return Color(nsColor: .controlAccentColor) }
  func ns(_ c: TermColor) -> NSColor {
    NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
  }
  let light = ns(choice.light.accent), dark = ns(choice.dark.accent)
  return Color(
    nsColor: NSColor(name: nil) { look in
      look.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}
