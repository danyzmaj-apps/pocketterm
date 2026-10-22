import ActivityKit
import Foundation

/// A coding session (omp or Claude Code) followed on the Lock Screen and in the Dynamic Island
/// (the app starts it: ios/Runner/AppDelegate.swift; the PocketTermLive
/// extension draws it: ios/PocketTermLive/PocketTermLive.swift).
///
/// What it's called and which session it is are fixed here, on the phone,
/// when it starts; they never travel. Pushes carry only the ContentState, at
/// the activity's own push token. They can't carry text: the notification
/// extension that decrypts alerts never sees a Live Activity push, so
/// anything in one would be readable by the relay.
struct SessionActivity: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    enum State: String, Codable, Hashable {
      case working, needs, done, ended
    }

    /// What the session waits for, when it needs you.
    enum Kind: String, Codable, Hashable {
      case question, approval, plan
    }

    var state: State

    /// When it got into this state, in seconds since 1970. A plain number
    /// rather than a Date: ActivityKit decodes a pushed Date as seconds since
    /// 2001, which no server sends.
    var since: Double
    var kind: Kind?

    var sinceDate: Date { Date(timeIntervalSince1970: since) }
  }

  /// The session's routed key, `<computer id>/<session key>` (like `abcd1234/kitty-<pid>/<window id>`): which
  /// computer and session a tap opens.
  var key: String
  var title: String
  var project: String

  /// Opens the session in the app (lib/mobile.dart).
  var link: URL {
    var c = URLComponents()
    c.scheme = "pocketterm"
    c.host = "session"
    c.queryItems = [URLQueryItem(name: "key", value: key)]
    return c.url!
  }
}
