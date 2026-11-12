import Combine
import Foundation

// Anonymous usage statistics to the publisher's self-hosted Umami (umami.danyzmaj.com, in the EU): which screens
// open and a fixed list of things that happened, each with a few fixed values. Off until the person turns it on
// in Settings, and off for good in a build without a website id (debug, CI, forks). The iPhone app uses it; the
// Mac app doesn't. Android's twin is core/Analytics.kt, with the same names and values.

/// Where events go: Umami's collect API at [url], counted under [websiteId].
public struct AnalyticsTarget: Equatable, Sendable {
  public let websiteId: String
  public let url: URL

  public init(websiteId: String, url: URL = URL(string: "https://umami.danyzmaj.com")!) {
    self.websiteId = websiteId
    self.url = url
  }

  /// The build's target; nil (nothing is ever sent) without a website id.
  public static func of(_ websiteId: String?) -> AnalyticsTarget? {
    let id = (websiteId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty ? nil : AnalyticsTarget(websiteId: id)
  }
}

/// What every call says about the phone; Umami reads the OS and model from [userAgent] and drops bot-like ones.
public struct AnalyticsDevice: Equatable, Sendable {
  public var platform: String
  public var hostname: String
  public var userAgent: String
  public var screen: String
  public var language: String
  public var appVersion: String

  public init(platform: String, hostname: String, userAgent: String, screen: String, language: String, appVersion: String) {
    self.platform = platform
    self.hostname = hostname
    self.userAgent = userAgent
    self.screen = screen
    self.language = language
    self.appVersion = appVersion
  }
}

/// A property's value: one of a fixed set of words, or true/false.
public enum AnalyticsValue: Equatable, Sendable {
  case string(String)
  case bool(Bool)
}

/// Why a sign-in or an added computer's code didn't work (`pairing_failed`'s `code`).
public enum PairingFailure: String, CaseIterable, Sendable {
  /// The link carries no pairing code.
  case noCode = "no_code"
  /// The server isn't reachable or isn't a PocketTerm server.
  case serverCheck = "server_check"
  /// The code was used or is too old.
  case codeUsed = "code_used"
  /// The server refused it for another reason.
  case serverError = "server_error"
  /// The device couldn't keep the sign-in.
  case storage
  /// The request didn't get through.
  case connection
  /// Signed in to another server.
  case otherServer = "other_server"
  /// A key that would replace the one held came with a code that doesn't work.
  case keyRejected = "key_rejected"
  /// A computer's key came from a link opened outside the app's scanner.
  case notScanned = "not_scanned"
}

/// Everything that may be recorded: the screens, and per event its properties with the values each may take
/// (nil: true or false). Anything else (another name, key or value) is dropped before it's queued, so no host
/// name, address, path, command, text or key ever goes.
public enum AnalyticsEvents {
  public static let screens: Set<String> = [
    "setup", "scan", "push_consent", "home", "session", "terminal", "queue", "orchestrator", "settings",
  ]

  public static let events: [String: [String: Set<String>?]] = [
    "pairing_completed": ["method": ["scan", "link"], "computer": ["first", "another"]],
    "pairing_failed": ["method": ["scan", "link"], "code": Set(PairingFailure.allCases.map(\.rawValue))],
    "demo_opened": [:],
    "session_opened": ["view": ["conversation", "screen"], "from": ["list", "notification", "new", "switch"]],
    "session_started": ["kind": ["agent", "shell"], "project": ["existing", "new"]],
    "prompt_sent": ["mode": ["prompt", "steer", "queue", "command", "orchestrator"], "attachments": Set<String>?.none],
    "terminal_connected": ["transport": ["tailnet", "local", "other"]],
    "terminal_disconnected": ["reason": ["unreachable", "computer_offline"]],
    "notifications_set": ["on": Set<String>?.none],
  ]

  /// At most this many properties per event, `platform` and `app_version` included.
  public static let maxProperties = 10

  /// [props] as they may leave the phone for event [name]: only its own keys, each with an allowed value; nil
  /// for an unknown event. Sorted by key, so what goes is the same whatever the dictionary's order.
  public static func sanitize(_ name: String, _ props: [String: AnalyticsValue]) -> [String: AnalyticsValue]? {
    guard let allowed = events[name] else { return nil }
    var out: [String: AnalyticsValue] = [:]
    for (key, value) in props.sorted(by: { $0.key < $1.key }) {
      guard out.count < maxProperties - 2, let values = allowed[key] else { continue }
      switch (values, value) {
      case (nil, .bool): out[key] = value
      case (let values?, .string(let s)) where values.contains(s): out[key] = value
      default: continue
      }
    }
    return out
  }

  /// `terminal_connected`'s `transport`, from the server's host: never the host itself.
  public static func transport(_ host: String) -> String {
    var h = host.lowercased()
    while h.hasSuffix(".") { h.removeLast() }
    if h.hasSuffix(".ts.net") { return "tailnet" }
    if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(h) { return "local" }
    return "other"
  }
}

/// Anonymous usage statistics, off by default ([enabled]). On, each call queues one Umami event (in memory, at
/// most [maxQueue], the oldest dropped) that goes out at once, one request at a time; a failure waits
/// [retryAfter] (or the next [flush]). Events carry a random install id ([installIdKey], made the first time one
/// is recorded), never a device id; turning it off drops the id and the queue, and turning it on again makes a
/// new id. Without a [target] nothing is ever recorded. Never throws.
@MainActor
public final class Analytics: ObservableObject {
  public static let enabledKey = "pocketterm_analytics_on"
  public static let installIdKey = "pocketterm_analytics_id"
  public static let maxQueue = 100
  public static let retryAfter: TimeInterval = 60

  /// Sends one JSON body; answers the HTTP status, nil when it didn't get through. Tests pass their own.
  public typealias Post = @MainActor (_ url: URL, _ userAgent: String, _ body: Data) async -> Int?

  private let target: AnalyticsTarget?
  private let device: @MainActor () -> AnalyticsDevice
  private let prefs: PreferenceStore
  private let now: () -> Date
  private let post: Post

  private var queue: [Data] = []
  private var sending: Task<Void, Never>?
  private var retryAt: Date?
  private var lastScreen: String?

  /// [device] is asked when an event is recorded (the screen size is known only once a window is up).
  public init(
    target: AnalyticsTarget?, device: @escaping @MainActor () -> AnalyticsDevice, prefs: PreferenceStore,
    now: @escaping () -> Date = { Date() }, post: Post? = nil
  ) {
    self.target = target
    self.device = device
    self.prefs = prefs
    self.now = now
    self.post = post ?? Analytics.urlSessionPost
  }

  /// Whether this build can send at all.
  public var configured: Bool { target != nil }

  /// The person's choice, off until they turn it on.
  public var enabled: Bool { prefs.bool(Self.enabledKey) ?? false }

  private var active: Bool { target != nil && enabled }

  /// How many events wait (tests).
  public var queued: Int { queue.count }

  public func setEnabled(_ on: Bool) {
    guard on != enabled else { return }
    objectWillChange.send()
    prefs.setBool(Self.enabledKey, on)
    if !on {
      sending?.cancel()
      sending = nil
      queue.removeAll()
      retryAt = nil
      prefs.remove(Self.installIdKey)
    }
  }

  /// A screen view; [name] one of [AnalyticsEvents.screens].
  public func screen(_ name: String) {
    guard active, AnalyticsEvents.screens.contains(name) else { return }
    enqueue(name: nil, screen: name, props: [:])
  }

  /// An event of [AnalyticsEvents.events]; what isn't allowed in [props] is left out.
  public func event(_ name: String, _ props: [String: AnalyticsValue] = [:]) {
    guard active, let clean = AnalyticsEvents.sanitize(name, props) else { return }
    enqueue(name: name, screen: nil, props: clean)
  }

  /// Tries what waits now (the app came back to the front), even within a failure's wait.
  public func flush() {
    retryAt = nil
    drain()
  }

  /// Waits for the send under way (tests).
  public func idle() async { await sending?.value }

  private func enqueue(name: String?, screen: String?, props: [String: AnalyticsValue]) {
    guard let target else { return }
    let id: String
    if let kept = prefs.string(Self.installIdKey) {
      id = kept
    } else {
      id = UUID().uuidString.lowercased()
      prefs.setString(Self.installIdKey, id)
    }
    if let screen { lastScreen = screen }
    let page = screen ?? lastScreen
    let d = device()
    var data: [String: Any] = ["platform": d.platform, "app_version": d.appVersion]
    for (k, v) in props {
      switch v {
      case .string(let s): data[k] = s
      case .bool(let b): data[k] = b
      }
    }
    var payload: [String: Any] = [
      "website": target.websiteId, "hostname": d.hostname, "language": d.language, "screen": d.screen,
      "url": "/" + (page ?? ""), "id": id, "timestamp": Int(now().timeIntervalSince1970), "data": data,
    ]
    if let page { payload["title"] = page }
    if let name { payload["name"] = name }
    guard let body = try? JSONSerialization.data(withJSONObject: ["type": "event", "payload": payload], options: [.sortedKeys])
    else { return }
    queue.append(body)
    if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
    drain()
  }

  private func drain() {
    guard let target, sending == nil, !queue.isEmpty else { return }
    if let retryAt, now() < retryAt { return }
    let url = target.url.appending(path: "api/send")
    sending = Task { [weak self] in
      while let self, self.active, !Task.isCancelled, let body = self.queue.first {
        let status = await self.post(url, self.device().userAgent, body)
        // Turned off while it was on its way: the queue went with it.
        if Task.isCancelled { return }
        switch status {
        case let s? where (200..<300).contains(s): self.queue.removeFirst()
        // Umami will never take it (malformed, unknown website): not sent again.
        case let s? where (400..<500).contains(s) && s != 408 && s != 429: self.queue.removeFirst()
        default:
          self.retryAt = self.now().addingTimeInterval(Self.retryAfter)
          self.sending = nil
          return
        }
      }
      self?.sending = nil
    }
  }

  /// No cookies, no cache, no credentials: a session of its own.
  private static let urlSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieAcceptPolicy = .never
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.timeoutIntervalForRequest = 20
    return URLSession(configuration: c)
  }()

  private static let urlSessionPost: Post = { url, userAgent, body in
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = body
    guard let (_, response) = try? await urlSession.data(for: request) else { return nil }
    return (response as? HTTPURLResponse)?.statusCode
  }
}
