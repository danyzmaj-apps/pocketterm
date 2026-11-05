import Foundation
import PocketTermKit

/// Unsent prompt text, per session, kept across leaving the page and app restarts until it's sent or deleted.
/// Text only: attachments are too large to keep. Stored as `pocketterm_draft_<desktopId>/<sessionKey>` (the
/// routed key, so sessions of two computers don't share one) holding `{"t": text, "at": ms since epoch}`.
struct Drafts {
  let prefs: Preferences

  static let prefix = "pocketterm_draft_"

  /// Drafts untouched this long are dropped.
  static let keep: TimeInterval = 30 * 24 * 3600

  static func key(_ routedKey: String) -> String { prefix + routedKey }

  /// [routedKey]'s draft, or "" when there's none. Drops stale drafts on the way.
  func load(_ routedKey: String, now: Date = Date()) -> String {
    let old = millisecondsSinceEpoch(now.addingTimeInterval(-Self.keep))
    var text = ""
    for k in prefs.keys(withPrefix: Self.prefix) {
      let d = Self.decode(prefs.string(k))
      if d == nil || d!.at < old {
        prefs.remove(k)
      } else if k == Self.key(routedKey) {
        text = d!.t
      }
    }
    return text
  }

  /// Keeps [text] as [routedKey]'s draft; blank removes it.
  func save(_ routedKey: String, _ text: String, now: Date = Date()) {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      prefs.remove(Self.key(routedKey))
    } else {
      let json: JSON = .object(["t": .string(text), "at": .int(millisecondsSinceEpoch(now))])
      prefs.setString(Self.key(routedKey), json.encoded())
    }
  }

  private static func decode(_ s: String?) -> (t: String, at: Int)? {
    guard let s, let m = JSON.tryParse(s)?.object, let t = m["t"]?.string, let at = m["at"]?.int else { return nil }
    return (t, at)
  }
}
