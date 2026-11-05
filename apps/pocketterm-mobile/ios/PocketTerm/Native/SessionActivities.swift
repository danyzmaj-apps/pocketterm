import ActivityKit
import Foundation
import PocketTermKit

/// Coding sessions on the Lock Screen and in the Dynamic Island (Shared/SessionActivity.swift, drawn by the
/// PocketTermLive extension). PocketTermKit's LiveActivities starts, updates and ends them while the app runs;
/// otherwise the server updates them by push, at each one's push token, which goes to [onNative] as
/// `activityToken`. One per session key.
final class SessionActivities: ActivityHost {
  static let shared = SessionActivities()

  /// `activityToken` / `activityEnded` with a routed key and token, for the remote's LiveActivities.
  var onNative: ((_ event: String, _ key: String, _ token: String?) -> Void)?

  /// Push tokens by activity id. A token can come before anything listens, so LiveActivities also takes
  /// them with [liveActivities].
  private var tokens: [String: String] = [:]

  /// Activities whose token and state are followed.
  private var watched: Set<String> = []

  /// Pushes stop making sense after this long without one (the computer asleep, or gone); the Live Activity
  /// shows as stale.
  private nonisolated static let staleAfter: TimeInterval = 8 * 3600

  var pushPlatform: String { "ios" }

  /// After a launch: the activities still running from before.
  func install() {
    for a in Activity<SessionActivity>.activities { watch(a) }
  }

  func liveActivities() async -> [(key: String, token: String?)] {
    Activity<SessionActivity>.activities.filter { $0.activityState == .active }.map { a in
      (key: a.attributes.key, token: tokens[a.id])
    }
  }

  // Nonisolated: an Activity isn't Sendable, so updating and ending one happens where it was looked up.
  private nonisolated static func active(_ key: String) -> [Activity<SessionActivity>] {
    Activity<SessionActivity>.activities.filter { $0.attributes.key == key && $0.activityState == .active }
  }

  private nonisolated static func content(state: String, kind: String?, since: Date)
    -> ActivityContent<SessionActivity.ContentState>?
  {
    guard let state = SessionActivity.ContentState.State(rawValue: state) else { return nil }
    return ActivityContent(
      state: .init(state: state, since: since.timeIntervalSince1970, kind: kind.flatMap(SessionActivity.ContentState.Kind.init)),
      staleDate: Date().addingTimeInterval(staleAfter))
  }

  /// Starts one for the session, or updates the one it has. True: running; false: Live Activities are off for
  /// PocketTerm (Settings) or iOS refused.
  func startActivity(key: String, title: String, project: String, state: String, kind: String?, since: Date)
    async throws -> Bool
  {
    guard let content = Self.content(state: state, kind: kind, since: since) else { return false }
    if !Self.active(key).isEmpty {
      await updateActivity(key: key, state: state, kind: kind, since: since)
      return true
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
    let attributes = SessionActivity(key: key, title: title.isEmpty ? "Session" : title, project: project)
    do {
      watch(try Activity.request(attributes: attributes, content: content, pushType: .token))
      return true
    } catch ActivityAuthorizationError.targetMaximumExceeded, ActivityAuthorizationError.globalMaximumExceeded {
      // iOS shows only so many at once, for this app and in all.
      throw TooManyActivities()
    } catch {
      debugLog("PocketTerm: Live Activity: \(error)")
      return false
    }
  }

  nonisolated func updateActivity(key: String, state: String, kind: String?, since: Date) async {
    guard let content = Self.content(state: state, kind: kind, since: since) else { return }
    for a in Self.active(key) { await a.update(content) }
  }

  /// Shows Ended, gone at once ([immediate]: the person ended it) or after 10 minutes (the session ended on
  /// the computer).
  nonisolated func endActivity(_ key: String, immediate: Bool) async {
    let content = ActivityContent(
      state: SessionActivity.ContentState(state: .ended, since: Date().timeIntervalSince1970), staleDate: nil)
    let policy: ActivityUIDismissalPolicy = immediate ? .immediate : .after(Date().addingTimeInterval(600))
    for a in Self.active(key) { await a.end(content, dismissalPolicy: policy) }
  }

  func channelKeys() async -> [String: String] {
    PocketTermShared.channelKeys().mapValues { $0.base64EncodedString() }
  }

  /// Every followed session ends at once (sign-out, push off, an app from before).
  func endAll() async {
    for a in await liveActivities() { await endActivity(a.key, immediate: true) }
  }

  private func watch(_ activity: Activity<SessionActivity>) {
    guard watched.insert(activity.id).inserted else { return }
    let key = activity.attributes.key
    let id = activity.id
    Task { @MainActor in
      for await data in activity.pushTokenUpdates {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.tokens[id] = token
        self.onNative?("activityToken", key, token)
      }
    }
    Task { @MainActor in
      for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
        // Ended here, by a push, or swiped away: its token is no use now.
        let token = self.tokens.removeValue(forKey: id)
        self.watched.remove(id)
        self.onNative?("activityEnded", key, token)
        break
      }
    }
  }
}
