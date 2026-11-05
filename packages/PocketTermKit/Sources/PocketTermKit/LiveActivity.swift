import Foundation

// Coding sessions followed on the phone: iPhone Live Activities (Lock Screen, Dynamic Island;
// apps/pocketterm-mobile/ios/Shared/SessionActivity.swift) and Android ongoing notifications
// (SessionActivities.kt). The app starts one when a prompt goes out from the phone or on "Follow", and
// updates it itself while it's in front; otherwise the computer tells the server (POST /v1/push/activity)
// and the server pushes to the token: the activity's own on iOS, the phone's FCM token (one per followed
// session) on Android. A push carries only what's below, never text: a Live Activity push can't be
// decrypted on the iPhone, so the relay would read it.

public enum ActivityState: String, Sendable, Hashable, CaseIterable {
  case working, needs, done, ended
}

/// What the agent waits for, when it needs you.
public enum ActivityKind: String, Sendable, Hashable, CaseIterable {
  case question, approval, plan
}

/// What a followed session's activity shows.
public struct ActivityStatus: Sendable, Hashable {
  public init(state: ActivityState, kind: ActivityKind? = nil) {
    self.state = state
    self.kind = kind
  }
  public let state: ActivityState
  public let kind: ActivityKind?
}

/// What a session's activity shows: its agent asks something, works, or has stopped (done). A picker the
/// person opened from the phone isn't the agent asking.
public func activityStatus(busy: Bool, ask: LiveAsk?) -> ActivityStatus {
  switch ask?.kind {
  case .questions: ActivityStatus(state: .needs, kind: .question)
  case .approval: ActivityStatus(state: .needs, kind: .approval)
  case .plan: ActivityStatus(state: .needs, kind: .plan)
  case .menu, nil: ActivityStatus(state: busy ? .working : .done)
  }
}

/// The same for a session in the computer's state; nil: it's gone (ended).
public func summaryStatus(_ s: LiveSummary?) -> ActivityStatus {
  guard let s else { return ActivityStatus(state: .ended) }
  return activityStatus(busy: s.busy, ask: s.ask)
}

/// The `state` and `kind` of a push or a channel call.
public func activityJson(_ s: ActivityStatus) -> JSONObject {
  var j: JSONObject = ["state": .string(s.state.rawValue)]
  if let kind = s.kind { j["kind"] = .string(kind.rawValue) }
  return j
}

/// iOS shows only so many Live Activities at once, per app and in all: one more is refused until another
/// ends.
public struct TooManyActivities: Error, Sendable, CustomStringConvertible {
  public init() {}
  public var description: String { "Too many Live Activities" }
}

/// The phone's own side of followed sessions: ActivityKit on iOS, ongoing notifications on Android. Keys
/// are routed keys ([routedKey]); [since]: when it got into [state].
@MainActor
public protocol ActivityHost: AnyObject {
  /// What the server (POST /v1/push/register) calls this phone's push service: `ios` or `android`.
  var pushPlatform: String { get }

  /// The running ones: their session keys and push tokens (if iOS has handed one over yet; on Android,
  /// the phone's FCM token).
  func liveActivities() async -> [(key: String, token: String?)]

  /// Starts one for session [key], or updates the one it has; false when Live Activities (iOS) or
  /// notifications (Android) are off for PocketTerm. Throws [TooManyActivities] when iOS already shows as
  /// many as it allows.
  func startActivity(key: String, title: String, project: String, state: String, kind: String?, since: Date)
    async throws -> Bool

  func updateActivity(key: String, state: String, kind: String?, since: Date) async

  /// [immediate]: gone at once (the person ended it), else Ended shows for a few minutes.
  func endActivity(_ key: String, immediate: Bool) async

  /// The computers' channel keys (standard base64) by computer id, as the phone keeps them.
  func channelKeys() async -> [String: String]
}

/// Phone: the sessions followed on [TerminalRemote]'s computer, kept current from it while the app is in
/// front, and their push tokens handed to the server. The native side and the server know a session by its
/// routedKey (Live.swift), this by its own key.
@MainActor
public final class LiveActivities: ObservableObject {
  public init(_ server: Server, _ remote: TerminalRemote, host: ActivityHost) {
    self.server = server
    self.remote = remote
    self.host = host
    stopListening = remote.addListener { [weak self] in self?.sync() }
    Task { await load() }
  }

  private let server: Server
  private let remote: TerminalRemote
  private let host: ActivityHost
  private var stopListening: (@MainActor () -> Void)?

  private struct Shown: Equatable {
    let status: ActivityStatus
    let since: Date
  }

  /// Followed sessions: what each activity shows and since when. Nil: one still running from before this
  /// launch, which only pushes have updated.
  @Published private var shown: [String: Shown?] = [:]

  /// When a prompt last went to a session: its agent may not have reported busy yet, so for a while "done"
  /// is taken to be from before it.
  private var prompted: [String: Date] = [:]
  static let promptWait: TimeInterval = 30

  /// Sessions whose push token the server has, as `routed key\ntoken`: on Android one token serves every
  /// followed session.
  private var registered: Set<String> = []

  public func following(_ key: String) -> Bool { shown.keys.contains(key) }

  private func routed(_ key: String) -> String { routedKey(remote.desktopId, key) }

  /// [routed]'s session key if it's on this computer.
  private func mine(_ routed: String) -> String? {
    guard let r = splitRoutedKey(routed), r.desktop == remote.desktopId else { return nil }
    return r.key
  }

  /// The activities running from before (and tokens iOS handed over before this listened); the server
  /// learns every token, whichever computer its session is on.
  private func load() async {
    for a in await host.liveActivities() {
      if splitRoutedKey(a.key) == nil { continue }
      if let key = mine(a.key), shown[key] == nil { shown[key] = .some(nil) }
      if let token = a.token { Task { await register(a.key, token) } }
    }
    sync()
  }

  /// Starts following [key], shown as [title]; [status] if known better than the computer's state (a prompt
  /// just sent). False: Live Activities are off for PocketTerm, or the session isn't there. Throws
  /// [TooManyActivities] when iOS shows as many as it allows.
  @discardableResult
  public func follow(_ key: String, title: String, status: ActivityStatus? = nil) async throws -> Bool {
    guard let s = remote.session(key) else { return false }
    let shown = Shown(status: status ?? summaryStatus(s), since: Date())
    let project = s.cwd.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? s.cwd
    let started = try await host.startActivity(
      key: routed(key), title: title, project: project, state: shown.status.state.rawValue,
      kind: shown.status.kind?.rawValue, since: shown.since)
    if started { self.shown[key] = shown }
    return started
  }

  /// A prompt went to [key]: it's working now, followed from here on, if the phone can show one more.
  public func prompted(_ key: String, title: String) async throws {
    prompted[key] = Date()
    let working = ActivityStatus(state: .working)
    if !following(key) {
      do {
        try await follow(key, title: title, status: working)
      } catch is TooManyActivities {
        return  // The prompt went all the same.
      }
    } else if shown[key]??.status.state != .working {
      await show(key, working).value
    }
  }

  /// The person stops following [key]: the activity goes at once.
  public func stop(_ key: String) async {
    shown[key] = nil
    await host.endActivity(routed(key), immediate: true)
  }

  /// From the native side: `activityToken` ({key, token}: a followed session's push token, new or changed),
  /// `activityEnded` ({key, token?}: it ended or was swiped away), for a [routedKey].
  public func onNative(_ event: String, key routed: String?, token: String?) {
    guard let routed, splitRoutedKey(routed) != nil else { return }
    switch event {
    case "activityToken":
      if let token { Task { await register(routed, token) } }
    case "activityEnded":
      if let token {
        registered.remove("\(routed)\n\(token)")
        Task { await push("activity_end", ["token": .string(token), "session": .string(routed)]) }
      }
      if let key = mine(routed) {
        shown[key] = nil
        prompted[key] = nil
      }
    default:
      break
    }
  }

  private func register(_ routed: String, _ token: String) async {
    guard registered.insert("\(routed)\n\(token)").inserted else { return }
    // An Android phone's plain end names the session only by its tag (sessionTag), which the server can't
    // make.
    let ref = host.pushPlatform == "android" ? await self.ref(routed) : nil
    var body: JSONObject = ["token": .string(token), "session": .string(routed), "platform": .string(host.pushPlatform)]
    if let ref { body["ref"] = .string(ref) }
    if !(await push("activity_register", body)) { registered.remove("\(routed)\n\(token)") }
  }

  /// [routed]'s [sessionTag] under its computer's key; nil without the key (nothing from it would open
  /// anyway).
  private func ref(_ routed: String) async -> String? {
    guard let desktop = splitRoutedKey(routed)?.desktop else { return nil }
    let key = desktop == remote.desktopId ? remote.key : ChannelKey.tryParse(await host.channelKeys()[desktop])
    return key.map { sessionTag($0, routed) }
  }

  @discardableResult
  private func push(_ action: String, _ body: JSONObject) async -> Bool {
    do {
      _ = try await server.push(action, body)
      return true
    } catch {
      debugLog("PocketTerm: Live Activity \(action): \(error)")
      return false
    }
  }

  /// Shows [status] for [key] now; the returned task is the native side catching up.
  @discardableResult
  private func show(_ key: String, _ status: ActivityStatus) -> Task<Void, Never> {
    let since = Date()
    shown[key] = Shown(status: status, since: since)
    let host = host
    let routedKey = routed(key)
    return Task {
      await host.updateActivity(key: routedKey, state: status.state.rawValue, kind: status.kind?.rawValue, since: since)
    }
  }

  /// The computer's state changed: each followed session's activity follows it.
  private func sync() {
    let macState = remote.online && !remote.fromCache
    for key in Array(shown.keys) {
      guard let s = remote.session(key) else {
        if !macState { continue }
        shown[key] = nil
        prompted[key] = nil
        let host = host
        let routedKey = routed(key)
        Task { await host.endActivity(routedKey, immediate: false) }
        continue
      }
      let status = summaryStatus(s)
      let was = shown[key] ?? nil
      if status.state == .done, let p = prompted[key], Date().timeIntervalSince(p) < Self.promptWait { continue }
      if status.state != .done { prompted[key] = nil }
      if was == nil {
        // Pushes have kept it current; its timer stays.
        shown[key] = Shown(status: status, since: Date())
      } else if was!.status != status {
        show(key, status)
      }
    }
  }

  public func dispose() {
    stopListening?()
    stopListening = nil
  }
}
