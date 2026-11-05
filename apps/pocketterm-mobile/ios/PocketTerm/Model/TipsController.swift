import Combine
import Foundation

/// The first-use tips, in the order they show: the switch tour first, then the list's, then the conversation
/// page's.
enum AppTip: String, CaseIterable, Sendable {
  case switchOpen = "switch-open"
  case switchButton = "switch-button"
  case switchDone = "switch-done"
  case projectHeading = "project-heading"
  case swipeRow = "swipe-row"
  case newSession = "new-session"
  case slash
  case queue
  case follow
  case openScreen = "open-screen"

  var id: String { rawValue }

  /// A step of the switch tour: while it waits on its page and isn't in view, no later tip shows there.
  var tour: Bool { self == .switchOpen || self == .switchDone }

  var caption: String {
    switch self {
    case .switchOpen: "This session shows only its screen. Tap it to open."
    case .switchButton:
      "Turns this into a conversation, with chat, approvals and pushes. "
        + "omp restarts on the same conversation; Claude Code just reloads."
    case .switchDone: "Now it\u{2019}s a conversation. Tap to open it."
    case .projectHeading: "Tap to fold this project. Its ⋯ has its menu."
    case .swipeRow: "Swipe left to end the session or close the window."
    case .newSession: "Start your agent or a shell in any project."
    case .slash: "Type / for slash commands."
    case .queue: "Off: your prompt steers the agent now. On: it waits until the run ends."
    case .follow: "Follow this session on your Lock Screen."
    case .openScreen: "See the raw terminal screen."
    }
  }
}

/// Which tips this install has seen, kept in the preferences (per phone, not per account) as
/// `pocketterm_tips_seen`. None shows until [answered]: a fresh install first asks whether to have them (the
/// tour question). With [startSeen] (E2E builds) a fresh install starts answered with every tip seen, so the
/// end-to-end flows aren't held up by them, until Show tips again.
final class TipsController: ObservableObject {
  init(prefs: Preferences, startSeen: Bool = E2E.enabled) {
    self.prefs = prefs
    let kept = prefs.stringList(Self.seenKey)
    answered = startSeen || kept != nil
    seenIds = Set(kept ?? (startSeen ? AppTip.allCases.map(\.id) : []))
  }

  /// The seen ids; kept from the first answer on (empty for Show me), so a missing list is a question not
  /// answered.
  static let seenKey = "pocketterm_tips_seen"

  private let prefs: Preferences
  @Published private(set) var seenIds: Set<String>

  /// Whether the person said whether they want the tips (or brought them back): until then none shows.
  @Published private(set) var answered: Bool

  func seen(_ tip: AppTip) -> Bool { seenIds.contains(tip.id) }

  /// The answer to the tour question: with [tour] the tips show from the first, without it they're all seen.
  func answer(tour: Bool) {
    if tour { return reset() }
    answered = true
    seenIds.formUnion(AppTip.allCases.map(\.id))
    save()
  }

  /// The window a switch to the conversation view just turned into a session: its row gets `switchDone`.
  @Published private(set) var switchedWindow: String?

  func switched(_ window: String) { switchedWindow = window }

  func markSeen(_ tip: AppTip) {
    guard seenIds.insert(tip.id).inserted else { return }
    save()
  }

  /// Every tip shows again, without asking first.
  func reset() {
    answered = true
    seenIds.removeAll()
    // Kept empty rather than removed: no list is a fresh install, which asks first ([answered]).
    save()
  }

  private func save() { prefs.setStringList(Self.seenKey, seenIds.sorted()) }
}
