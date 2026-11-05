import Foundation
import PocketTermKit

// What the screens say about computers, sessions and windows: shared by the list, the conversation page, the
// terminal screen and the orchestrator.

/// `/Users/me/Dev/x` as `~/Dev/x` (`C:\Users\me\x` as `~\x`).
func shortPath(_ r: TerminalRemote, _ path: String) -> String {
  !r.home.isEmpty && path.hasPrefix(r.home) ? "~" + path.dropFirst(r.home.count) : path
}

/// A folder's last part: the project. A Windows computer's paths take `\`.
func baseName(_ path: String) -> String {
  path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
}

private func hasDrive(_ s: String) -> Bool {
  let c = Array(s)
  return c.count >= 3 && c[0].isASCII && c[0].isLetter && c[1] == ":" && (c[2] == "\\" || c[2] == "/")
}

/// A folder typed in as the computer's path: `~/x` (from [home]), `/x`, or `C:\x` on a Windows computer; nil
/// for anything else (a search).
func typedPath(_ typed: String, home: String) -> String? {
  let q = typed.trimmingCharacters(in: .whitespacesAndNewlines)
  if q.hasPrefix("~") {
    let rest = String(q.dropFirst())
    return home + (hasDrive(home) ? rest.replacingOccurrences(of: "/", with: "\\") : rest)
  }
  return q.hasPrefix("/") || hasDrive(q) ? q : nil
}

/// How long ago [t] was: "just now", "5 min ago", "3 h ago", "2 d ago".
func ago(_ t: Date, now: Date = Date()) -> String {
  let s = Int(now.timeIntervalSince(t))
  if s < 60 { return "just now" }
  if s < 3600 { return "\(s / 60) min ago" }
  if s < 86400 { return "\(s / 3600) h ago" }
  return "\(s / 86400) d ago"
}

/// How people name a window's terminal app ([TermWindow.app]).
func termLabel(_ app: String) -> String {
  switch app {
  case "kitty": "kitty"
  case "tmux": "tmux"
  case "wezterm": "WezTerm"
  case "iterm": "iTerm2"
  case "ghostty": "Ghostty"
  default: app
  }
}

/// Which terminal [w] is in: "WezTerm", or "tmux · Ghostty" for a tmux pane shown in Ghostty.
func termBadge(_ w: TermWindow) -> String {
  w.app == "tmux" && !w.via.isEmpty ? "tmux · \(w.via)" : termLabel(w.app)
}

/// Why the phone gets no answer from [server], and what to do: a server on a tailnet runs on one of the
/// person's computers, which has to be awake, and its address changes when that computer is renamed (the phone
/// then needs that computer's new code); a tailnet with device approval on holds a new phone back until its
/// admin approves it.
func serverUnreachable(_ server: Backend) -> String {
  server.onTailnet
    ? "\(server.unreachable) The computer running it has to be awake. If it was renamed in Tailscale, leave this "
      + "server (Account) and scan its new code. If Tailscale says Awaiting Approval, approve this phone in the "
      + "Tailscale admin console under Machines."
    : server.unreachable
}

/// What's wrong with the link to the computer, if anything, as one line for the top of a screen: with how old
/// the shown state is when it isn't live, and whether a Retry ([TerminalRemote.reconnect]) helps.
struct LinkNote: Equatable {
  let text: String
  /// Connecting or asking: a spinner rather than Retry.
  let busy: Bool
  let retry: Bool

  init?(_ r: TerminalRemote, now: Date = Date()) {
    let who = r.desktopName ?? "the computer"
    let text: String?
    var busy = false
    switch r.link {
    case .connecting:
      text = "connecting…"
      busy = true
    case .unreachable: text = serverUnreachable(r.backend)
    case .waiting:
      text = "asking \(who)…"
      busy = true
    case .offline:
      if let off = r.clockOff {
        // Its messages come, but a clock this far off makes them look replayed: they're dropped.
        text =
          "This phone's clock and \(who)'s differ by \(clockGap(off)), so nothing from it can be trusted. Turn on "
          + "Set Automatically (date and time) on both."
      } else if let seen = r.desktopSeenAt, now.timeIntervalSince(seen) >= Desktop.onlineWithin {
        // Not reporting to the server either: not there, rather than not answering.
        text = "\(who) was last seen \(ago(seen, now: now)). It may be asleep or off, or PocketTerm isn't running there."
      } else {
        text = "\(who) isn't answering. It has to be awake, with PocketTerm running and Settings → Terminal from phone on."
      }
    case .online: text = r.error
    }
    guard let text else { return nil }
    if r.link == .online {
      self.text = text
    } else if let at = r.stateAt {
      self.text = "Updated \(ago(at, now: now)) · \(text)"
    } else {
      self.text = text.prefix(1).uppercased() + text.dropFirst()
    }
    self.busy = busy
    retry = !busy && r.link != .online && r.clockOff == nil
  }
}

/// [off] seconds in words: minutes, or hours once that's more.
func clockGap(_ off: TimeInterval) -> String {
  let minutes = Int(abs(off) / 60)
  if minutes < 120 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
  return "\(Int(abs(off) / 3600)) hours"
}

/// How the phone names the project in [cwd]: its folder's name, General for the home folder (a session started
/// without picking a project), Somewhere when unknown.
func projectName(_ r: TerminalRemote, _ cwd: String) -> String {
  cwd.isEmpty ? "Somewhere" : cwd == r.home ? "General" : baseName(cwd)
}

/// How the Terminal list orders its projects.
enum ProjectSort: String, CaseIterable, Sendable {
  /// A–Z by folder name; somewhere unknown last.
  case name
  /// Most recent activity first, as last ranked.
  case activity

  var label: String {
    switch self {
    case .name: "Name"
    case .activity: "Recent activity"
    }
  }
}

/// "Needs you", "Working…", a stop it needs to hear about, or how long it has been idle.
func sessionState(_ s: LiveSummary, now: Date = Date()) -> String {
  if s.ask != nil { return "Needs you" }
  if s.busy { return "Working…" }
  if s.failed { return "Stopped on an error" }
  if s.paused && !s.queue.isEmpty { return "Queue paused" }
  return s.at.map { ago($0, now: now) } ?? "Idle"
}

/// What the agent's status bar shows of [s], each part only when known, after its omp profile when that isn't
/// the default: "personal · Opus 4.5 · 49% · $43.34".
func sessionFacts(_ s: LiveSummary) -> String {
  var parts: [String] = []
  if !s.profile.isEmpty { parts.append(s.profile) }
  if !s.model.isEmpty { parts.append(shortModel(s.model)) }
  if let ctx = s.ctx { parts.append("\(ctx)%") }
  if let cost = s.cost { parts.append(money(cost)) }
  return parts.joined(separator: " · ")
}

/// [model] short enough for a row: no "Claude " before it, no release date after it, at most 22 characters.
func shortModel(_ model: String) -> String {
  var m = model
  if let r = m.range(of: "^claude[ -]", options: [.regularExpression, .caseInsensitive]) { m.removeSubrange(r) }
  if let r = m.range(of: "[-@][0-9]{8}$", options: .regularExpression) { m.removeSubrange(r) }
  return m.count > 22 ? String(m.prefix(21)) + "…" : m
}

/// [usd] as omp's status line writes it: "$43.34"; under a cent "<$0.01".
func money(_ usd: Double) -> String { usd < 0.01 ? "<$0.01" : String(format: "$%.2f", usd) }

/// Says where on the computer a window the phone started went ("Opened in a new tab in the kitty window with
/// wrkly"), when the computer says (`Opened.where`).
func openedText(_ where: String) -> String? { `where`.isEmpty ? nil : "Opened in \(`where`)" }

/// What an error from the computer says, for a toast.
func errorText(_ e: Error) -> String {
  if let t = e as? TerminalException { return t.message }
  return "\(e)"
}

/// Where a session stands, as its row shows it at a glance.
enum TileState: Sendable {
  /// Nothing to tell.
  case idle
  /// The agent is working.
  case working
  /// It asks something, or waits on a plan or an approval.
  case needsYou
  /// Its last run broke off on an error.
  case failed
  /// Stopped with prompts still queued: nothing goes until Resume.
  case paused
  /// It finished a run the person hasn't opened since.
  case done
}

/// Sessions seen working in this run of the app, and those of them that have finished since the person last
/// opened them: what a row's Done state shows. Kept for the app's life, so it survives the list being rebuilt
/// or left.
final class Finished {
  static let shared = Finished()
  private var wasBusy: Set<String> = []
  private var finished: Set<String> = []

  /// Notes which of [sessions] finished a run since last looked at. A run that ends while its conversation is
  /// open ([watched]) was seen as it ended, so its row doesn't ask for attention afterwards.
  func note(_ sessions: [LiveSummary], watched: String?) {
    for s in sessions {
      if s.key == watched {
        wasBusy.remove(s.key)
        finished.remove(s.key)
        if s.busy { wasBusy.insert(s.key) }
      } else if s.busy {
        wasBusy.insert(s.key)
        finished.remove(s.key)
      } else if wasBusy.remove(s.key) != nil && s.ask == nil && !s.failed {
        finished.insert(s.key)
      }
    }
  }

  /// Opening the session clears its Done.
  func seen(_ key: String) { finished.remove(key) }

  /// [s] as its row shows it.
  func state(_ s: LiveSummary) -> TileState {
    if s.ask != nil { return .needsYou }
    if s.busy { return .working }
    if s.failed { return .failed }
    if s.paused && !s.queue.isEmpty { return .paused }
    if finished.contains(s.key) { return .done }
    return .idle
  }
}

/// The name and colour the person gave a row in the Terminal list.
struct TileLook: Hashable, Sendable {
  var name: String?
  /// 0xAARRGGBB, one of [tileColors].
  var color: Int?

  init(name: String? = nil, color: Int? = nil) {
    self.name = name
    self.color = color
  }

  init(json j: JSONObject) {
    name = j["name"]?.string
    color = j["color"]?.int
  }

  func withName(_ name: String?) -> TileLook {
    let t = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    return TileLook(name: t?.isEmpty ?? true ? nil : t, color: color)
  }

  func withColor(_ color: Int?) -> TileLook { TileLook(name: name, color: color) }

  func toJson() -> JSONObject {
    var j: JSONObject = [:]
    if let name { j["name"] = .string(name) }
    if let color { j["color"] = .int(color) }
    return j
  }
}

/// The colours a row can be tinted with: bright enough to read on Rosé Pine Dawn's paper and the dark themes.
let tileColors: [Int] = [0xFFE5_484D, 0xFFF7_6B15, 0xFFFF_C53D, 0xFF46_A758, 0xFF12_A594, 0xFF00_90FF, 0xFF8E_4EC6, 0xFFD6_409F]

/// What [tileColors] are called, in the same order: what VoiceOver reads for each swatch.
let tileColorNames = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"]
