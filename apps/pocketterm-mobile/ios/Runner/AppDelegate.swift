import ActivityKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let notifications = Notifications()
  private let activities = SessionActivities()

  /// Waiting for APNs to hand over this iPhone's device token (registerPush).
  private var pushWaiter: FlutterResult?
  /// Which registerPush [pushWaiter] belongs to, for its time limit.
  private var pushAsk = 0

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before Flutter starts and reads them: a reinstall doesn't pick up the last install's keys.
    PocketTermShared.wipeKeychainAfterInstall()
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // Before launch ends: the tap that launched the app comes next.
    notifications.install()
    // The per-phone push key from before end-to-end encryption: no server has a use for it now.
    PocketTermShared.defaults.removeObject(forKey: "pushKey")
    return launched
  }

  override func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushWaiter?(["token": token])
    pushWaiter = nil
  }

  override func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    pushWaiter?(nil)
    pushWaiter = nil
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The iPhone half of packages/pocketterm_core/lib/native.dart: device name, the App Group
    // the push extension reads (ios/Shared/PocketTermShared.swift), pushes, Live Activities.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PocketTermNative")!
    let channel = FlutterMethodChannel(name: "pocketterm/native", binaryMessenger: registrar.messenger())
    notifications.channel = channel
    activities.channel = channel
    activities.install()
    channel.setMethodCallHandler { [notifications, activities, weak self] call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "setAppIcon":
        AppIcons.set(args["icon"] as? String ?? "default", result: result)
      case "setKeepAwake":
        UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
        result(nil)
      case "deviceName":
        result(UIDevice.current.name)
      case "getBackend":
        result(
          PocketTermShared.backendUrl.map { url in
            ["url": url, "kind": PocketTermShared.backendKind, "key": PocketTermShared.legacyBackendKey]
              .compactMapValues { $0 }
          }
        )
      case "setBackend":
        PocketTermShared.setBackend(url: args["url"] as? String, kind: args["kind"] as? String)
        result(nil)
      case "deviceToken":
        result(PocketTermShared.deviceToken())
      case "setDeviceToken":
        if PocketTermShared.setDeviceToken(args["value"] as? String) {
          result(nil)
        } else {
          result(FlutterError(code: "keychain", message: "Couldn't save the sign-in in the Keychain", details: nil))
        }
      case "takeTappedSession":
        result(notifications.takeTappedSession())
      case "setChannelKey":
        guard let desktop = args["desktop"] as? String, let b64 = args["key"] as? String,
          let key = Data(base64Encoded: b64), key.count == 32
        else {
          return result(FlutterError(code: "bad-args", message: "desktop and a 32-byte base64 key", details: nil))
        }
        if PocketTermShared.setChannelKey(key, for: desktop) {
          result(nil)
        } else {
          result(FlutterError(code: "keychain", message: "Couldn't save the key in the Keychain", details: nil))
        }
      case "removeAllChannelKeys":
        PocketTermShared.removeAllChannelKeys()
        result(nil)
      case "channelKeys":
        result(PocketTermShared.channelKeys().mapValues { $0.base64EncodedString() })
      case "registerPush":
        // Permission first (a no-op after the first answer), then APNs. nil:
        // not allowed or no token (the phone gets no pushes then).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
          DispatchQueue.main.async {
            guard granted, let self else { return result(nil) }
            self.pushWaiter?(nil)
            self.pushWaiter = result
            self.pushAsk += 1
            let ask = self.pushAsk
            UIApplication.shared.registerForRemoteNotifications()
            // APNs may never answer (no network): no token then, rather than a call that never ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
              guard let self, self.pushAsk == ask else { return }
              self.pushWaiter?(nil)
              self.pushWaiter = nil
            }
          }
        }
      case "notificationsAllowed":
        // Provisional (quiet) delivery counts: they still arrive.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
          DispatchQueue.main.async { result(allowed) }
        }
      case "openSettings":
        let url = args["notifications"] as? Bool == true
          ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
        if let url = URL(string: url) { UIApplication.shared.open(url) }
        result(nil)
      case "startActivity":
        activities.start(args, result: result)
      case "updateActivity":
        activities.update(args, result: result)
      case "endActivity":
        activities.end(args, result: result)
      case "liveActivities":
        result(activities.running())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// The home screen icon per theme (packages/pocketterm_core/lib/app_icon.dart): the asset catalog's
/// alternate icons, AppIcon-<Theme> (Runner's ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES, drawn by
/// apps/pocketterm-desktop/tool/make_icon.swift), or the app's own for "default". iOS confirms every change
/// with an alert of its own, so the icon showing already isn't set again, and it only takes the change from
/// an active app: one asked for before that waits for it.
enum AppIcons {
  static func set(_ icon: String, result: @escaping FlutterResult) {
    let app = UIApplication.shared
    let name: String? = icon == "default" ? nil : "AppIcon-" + icon.prefix(1).uppercased() + icon.dropFirst()
    guard app.supportsAlternateIcons, app.alternateIconName != name else { return result(nil) }
    guard app.applicationState == .active else {
      var waiter: NSObjectProtocol?
      waiter = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { _ in
        if let waiter { NotificationCenter.default.removeObserver(waiter) }
        AppIcons.set(icon, result: result)
      }
      return
    }
    app.setAlternateIconName(name) { error in
      DispatchQueue.main.async {
        guard let error else { return result(nil) }
        result(FlutterError(code: "app-icon", message: error.localizedDescription, details: nil))
      }
    }
  }
}

/// Coding sessions on the Lock Screen and in the Dynamic Island
/// (ios/Shared/SessionActivity.swift, drawn by the PocketTermLive extension). Dart
/// starts, updates and ends them while the app runs (packages/pocketterm_core/lib/live_activity.dart);
/// otherwise the server updates them by push, at each one's push token,
/// which goes to Dart as `activityToken {key, token}`. One per session key.
final class SessionActivities {
  /// The app's channel, once its Flutter engine is up.
  var channel: FlutterMethodChannel?

  /// Push tokens by activity id. A token can come before Dart listens, so
  /// Dart also takes them with [running].
  private var tokens: [String: String] = [:]

  /// Activities whose token and state are followed.
  private var watched: Set<String> = []

  /// Pushes stop making sense after this long without one (the computer asleep,
  /// or gone); the Live Activity shows as stale.
  private static let staleAfter: TimeInterval = 8 * 3600

  /// After a launch: the activities still running from before.
  func install() {
    for a in Activity<SessionActivity>.activities { watch(a) }
  }

  /// {key, token?} for each running activity.
  func running() -> [[String: Any]] {
    Activity<SessionActivity>.activities.filter { $0.activityState == .active }.map { a in
      var m: [String: Any] = ["key": a.attributes.key]
      if let token = tokens[a.id] { m["token"] = token }
      return m
    }
  }

  private func active(_ key: String) -> [Activity<SessionActivity>] {
    Activity<SessionActivity>.activities.filter { $0.attributes.key == key && $0.activityState == .active }
  }

  /// {state, kind?, since: ms since 1970}; nil for anything else.
  private func content(_ args: [String: Any]) -> ActivityContent<SessionActivity.ContentState>? {
    guard let raw = args["state"] as? String, let state = SessionActivity.ContentState.State(rawValue: raw) else {
      return nil
    }
    let since = (args["since"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
    let kind = (args["kind"] as? String).flatMap(SessionActivity.ContentState.Kind.init(rawValue:))
    return ActivityContent(
      state: .init(state: state, since: since / 1000, kind: kind),
      staleDate: Date().addingTimeInterval(Self.staleAfter))
  }

  /// {key, title, project, state, kind?, since}: starts one for the session,
  /// or updates the one it has. true: running; false: Live Activities are
  /// off for PocketTerm (Settings) or iOS refused.
  func start(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let key = args["key"] as? String, let content = content(args) else { return result(false) }
    if !active(key).isEmpty { return update(args, result: result) }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return result(false) }
    let attributes = SessionActivity(
      key: key, title: args["title"] as? String ?? "Session", project: args["project"] as? String ?? "")
    do {
      watch(try Activity.request(attributes: attributes, content: content, pushType: .token))
      result(true)
    } catch ActivityAuthorizationError.targetMaximumExceeded, ActivityAuthorizationError.globalMaximumExceeded {
      // iOS shows only so many at once, for this app and in all.
      result(FlutterError(code: "too-many", message: "Too many Live Activities", details: nil))
    } catch {
      NSLog("PocketTerm: Live Activity: \(error)")
      result(false)
    }
  }

  /// {key, state, kind?, since}
  func update(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let key = args["key"] as? String, let content = content(args) else { return result(false) }
    let list = active(key)
    Task { @MainActor in
      for a in list { await a.update(content) }
      result(!list.isEmpty)
    }
  }

  /// {key, immediate?}: shows Ended, gone at once (the person ended it) or
  /// after 10 minutes (the session ended on the computer).
  func end(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let key = args["key"] as? String else { return result(nil) }
    let list = active(key)
    let content = ActivityContent(
      state: SessionActivity.ContentState(state: .ended, since: Date().timeIntervalSince1970), staleDate: nil)
    let policy: ActivityUIDismissalPolicy =
      args["immediate"] as? Bool == true ? .immediate : .after(Date().addingTimeInterval(600))
    Task { @MainActor in
      for a in list { await a.end(content, dismissalPolicy: policy) }
      result(nil)
    }
  }

  private func watch(_ activity: Activity<SessionActivity>) {
    guard watched.insert(activity.id).inserted else { return }
    let key = activity.attributes.key
    let id = activity.id
    Task { @MainActor in
      for await data in activity.pushTokenUpdates {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.tokens[id] = token
        self.channel?.invokeMethod("activityToken", arguments: ["key": key, "token": token])
      }
    }
    Task { @MainActor in
      for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
        // Ended here, by a push, or swiped away: its token is no use now.
        let token = self.tokens.removeValue(forKey: id)
        self.watched.remove(id)
        var args: [String: Any] = ["key": key]
        if let token { args["token"] = token }
        self.channel?.invokeMethod("activityEnded", arguments: args)
        break
      }
    }
  }
}

/// Notification taps and banners. A terminal push's tap opens the app on its
/// coding session; the tap that launched the app arrives before Dart
/// listens, so the session waits until Dart takes it.
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
  /// The app's channel, once its Flutter engine is up.
  var channel: FlutterMethodChannel?

  /// The coding session a tapped terminal push is about, until Dart takes it.
  private var tappedSession: String?

  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  func takeTappedSession() -> String? {
    defer { tappedSession = nil }
    return tappedSession
  }

  /// A push arriving while PocketTerm is open still shows.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    // A push carries its kind and session in userInfo (PocketTermPush).
    let info = response.notification.request.content.userInfo
    guard info["kind"] as? String == "terminal" else { return completionHandler() }
    let session = info["session"] as? String
    DispatchQueue.main.async {
      self.tappedSession = session
      self.channel?.invokeMethod("openTerminal", arguments: session.map { ["session": $0] })
      completionHandler()
    }
  }
}
