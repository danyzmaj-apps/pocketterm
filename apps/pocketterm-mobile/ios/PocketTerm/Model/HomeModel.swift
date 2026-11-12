import Combine
import Foundation
import PocketTermKit
import SwiftUI

/// A page over the home list.
enum AppRoute: Hashable {
  /// Coding session [key]'s conversation. [starting]: just launched from the phone, its agent may not have
  /// reported yet. [after]: what to do once a switch from a screen-only window brought it here.
  case session(key: String, starting: Bool = false, after: AfterSwitch = .nothing)

  /// Terminal window [window]'s screen; [starting]: just launched, may not be in the computer's list yet.
  case terminal(window: String, starting: Bool = false)
}

/// What the conversation page does once a switch from a screen-only window brought it there: nothing, offer
/// Continue (the agent was working when it restarted), or send it at once (Restart and continue).
enum AfterSwitch: Hashable, Sendable { case nothing, offer, send }

/// The signed-in phone's home (or the demo's): the account's computers ([desktops]), the one shown and its
/// remote ([remote]: its coding sessions and terminal windows, live while the app is in front), the pages open
/// over the list ([path]), and the tapped push or followed session on its way to showing.
final class HomeModel: ObservableObject {
  /// [remoteFor] and [desktops] handed in: the demo's, never refreshed from a server, attached by its owner.
  init(app: AppModel, desktops: Desktops? = nil, remoteFor: ((String, ChannelKey) -> TerminalRemote)? = nil) {
    self.app = app
    self.fixed = desktops != nil
    self.desktops = desktops ?? app.desktops()
    self.remoteFor = remoteFor
    supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    watch()
  }

  let app: AppModel
  let desktops: Desktops
  private let fixed: Bool
  private let remoteFor: ((String, ChannelKey) -> TerminalRemote)?
  private let supportDir: URL

  /// The demo's made-up computer is showing.
  var isDemo: Bool { app.demo != nil && app.user == nil }

  /// The selected computer's coding sessions and terminal windows, through PocketTerm there. Nil with no
  /// computer, and with a locked one (no key).
  @Published private(set) var remote: TerminalRemote?
  private var attached = false
  private var stopRemote: (() -> Void)?

  /// The pages open over the list.
  @Published var path: [AppRoute] = []

  /// Whether the app is in front ([scenePhase] active).
  private var active = true

  private var bag: Set<AnyCancellable> = []
  private var refresher: Task<Void, Never>?
  private var notices: Task<Void, Never>?

  /// While the list is in front, the list of computers is fetched this often (and on coming to the front).
  static let refreshEvery: TimeInterval = 30

  /// How long a tapped session (a push, a followed session's link) may take to come before the phone gives up.
  static let routedWait: TimeInterval = 20

  private func watch() {
    desktops.objectWillChange.sink { [weak self] in
      Task { @MainActor in self?.syncRemote() }
    }.store(in: &bag)
    // A computer's key scanned; a followed session's link opened.
    app.objectWillChange.sink { [weak self] in
      Task { @MainActor in
        self?.syncRemote()
        self?.openLinkedSession()
      }
    }.store(in: &bag)
    // The pages: a routed session's page closed by the person stops waiting for it.
    $path.dropFirst().sink { [weak self] path in
      guard let self, let r = self.routed, r.opened else { return }
      if !path.contains(where: { if case .session(let k, _, _) = $0 { k == r.key } else { false } }) {
        Task { @MainActor in self.dropRouted() }
      }
    }.store(in: &bag)
    Push.shared.onTapped = { [weak self] in self?.openTappedSession() }
    SessionActivities.shared.onNative = { [weak self] event, key, token in
      self?.remote?.activities?.onNative(event, key: key, token: token)
    }
    let stream = app.notices
    notices = Task { @MainActor [weak self] in
      for await message in stream {
        self?.told = true
        Toaster.shared.show(message)
      }
    }
    refresher = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.refreshEvery))
        self?.refreshIfInFront()
      }
    }
    syncRemote()
    // A followed session's link or a tapped push that launched the app (before this page was there).
    Task { @MainActor in
      self.openLinkedSession()
      self.openTappedSession()
      timing("home")
      self.refreshIfInFront()
    }
  }

  /// One remote, for the selected computer while this phone has its key: another computer selected, or a new
  /// key scanned, the old one goes (with any page on it) and a new one comes.
  func syncRemote() {
    // A code just scanned: that computer, not the one seen last.
    if let id = app.takeScannedComputer() {
      desktops.show(id)
      if !desktops.all.contains(where: { $0.id == id }) { Task { await desktops.refresh() } }
    }
    let d = desktops.selected
    let key = d.flatMap { app.computerKey($0.id) }
    if let old = remote, old.desktopId == d?.id, old.key == key {
      old.desktopName = d?.name
      old.desktopSeenAt = d?.seenAt
      syncFollow(old)
      return advanceRouted()
    }
    var next: TerminalRemote?
    if let d, let key {
      next = remoteFor?(d.id, key) ?? TerminalRemote(app.server!, supportDir: supportDir, desktopId: d.id, key: key)
      next!.desktopName = d.name
      next!.desktopSeenAt = d.seenAt
      syncFollow(next!)
    }
    if let old = remote {
      path = []
      dropRemote(old)
    }
    remote = next
    if let next {
      stopRemote = next.addListener { [weak self] in self?.remoteChanged() }
      if active { attach(true) }
    }
    advanceRouted()
  }

  /// Following sessions (Live Activities) needs push: with it off there's no Follow, and nothing registers.
  private func syncFollow(_ t: TerminalRemote) {
    let server = app.server
    let on = (app.pushEnabled ?? false) && server != nil && !isDemo
    if on && t.activities == nil {
      t.activities = LiveActivities(server!, t, host: SessionActivities.shared)
    } else if !on, let a = t.activities {
      a.dispose()
      t.activities = nil
    }
  }

  private func dropRemote(_ t: TerminalRemote) {
    attached = false
    linkOnline = nil
    stopRemote?()
    stopRemote = nil
    t.activities?.dispose()
    t.activities = nil
    if remoteFor != nil { return }
    t.dispose()
  }

  private func remoteChanged() {
    guard let t = remote else { return }
    Finished.shared.note(t.sessions, watched: t.watchedSession)
    countLink(t)
    // The computer's connection is back: a push token the server missed goes again.
    if t.online && app.pushUnsent && !isDemo { Task { await app.retryPush() } }
    advanceRouted()
  }

  /// Whether the computer answered when last looked, since the app came to the front; nil: not known yet.
  private var linkOnline: Bool?

  /// `terminal_connected` when the computer starts answering, `terminal_disconnected` when it stops (the server
  /// unreachable, or the computer not answering); not for the app leaving the front, nor in the demo.
  private func countLink(_ t: TerminalRemote) {
    guard attached, !isDemo else { return }
    let link = t.link
    let online = link == .online
    let down = link == .unreachable || link == .offline
    if online && linkOnline != true {
      app.analytics.event("terminal_connected", ["transport": .string(AnalyticsEvents.transport(t.backend.host))])
    } else if down && linkOnline == true {
      app.analytics.event(
        "terminal_disconnected", ["reason": .string(link == .unreachable ? "unreachable" : "computer_offline")])
    }
    if online || down { linkOnline = online }
  }

  private func attach(_ on: Bool) {
    guard let t = remote, on != attached, remoteFor == nil else { return }
    attached = on
    linkOnline = nil
    if on { t.attach() } else { t.detach() }
  }

  /// The app came to the front or left it.
  func scenePhase(_ phase: ScenePhase) {
    switch phase {
    case .active:
      active = true
      app.analytics.flush()
      timing("resumed")
      // Before anything asks the server: connections from before may have died while away.
      app.server?.freshConnections()
      attach(true)
      refreshIfInFront()
      openTappedSession()
      // Notifications may have been turned off or on in Settings meanwhile.
      if !isDemo {
        Task {
          await app.checkNotifications()
          // A push token the server missed while it was unreachable.
          await app.retryPush(force: true)
        }
      }
    case .background:
      active = false
      timing("paused")
      attach(false)
    default:
      break
    }
  }

  /// The list of computers, unless a page is over it or the app is away.
  func refreshIfInFront() {
    if fixed || !active || !path.isEmpty { return }
    Task { await desktops.refresh() }
  }

  /// Asked again now (Retry), not at the next 30-second refresh.
  func retryComputers() {
    app.server?.freshConnections()
    Task { await desktops.refresh() }
  }

  /// Why the list of computers didn't come, if it didn't: a server the phone can't reach says what to do.
  var desktopsError: String? {
    guard let e = desktops.error else { return nil }
    if let b = app.backend, e == b.unreachable { return serverUnreachable(b) }
    return e
  }

  /// Why the server lists no computer.
  static let noDesktop =
    "Your computer isn't reporting to this server. Open PocketTerm on it and turn on Terminal from phone in its "
    + "Settings."

  /// Whether [desktop] is locked: this phone has no key for it.
  func locked(_ desktop: Desktop) -> Bool { app.computerKey(desktop.id) == nil }

  func select(_ desktop: Desktop) { desktops.select(desktop.id) }

  /// The computer list's sheet opened: fetch it fresh.
  func pickingComputer() {
    if !fixed { Task { await desktops.refresh() } }
  }

  // MARK: Scanning while signed in

  /// Whether a notice spoke since [scanned] asked.
  private var told = false

  /// A computer's code, scanned while signed in: this phone gets that computer's key ([Session.connectLink]); a
  /// problem with the code shows as a notice.
  func scanned(_ link: URL) async {
    told = false
    await app.connectLink(link, scanned: true)
    if told { return }
    if let selected = desktops.selected, locked(selected) {
      Toaster.shared.show("That code is for another computer. Scan the one \(selected.name) shows.")
    }
  }

  // MARK: Opening sessions

  /// Opens coding session [key]; [starting]: it was just launched.
  func openSession(_ key: String, starting: Bool = false) {
    Finished.shared.seen(key)
    countOpened("conversation", from: starting ? "new" : "list")
    path.append(.session(key: key, starting: starting))
  }

  /// Opens window [window]'s screen; [starting]: it was just launched.
  func openWindow(_ window: String, starting: Bool = false) {
    countOpened("screen", from: starting ? "new" : "list")
    path.append(.terminal(window: window, starting: starting))
  }

  /// `session_opened`: [view] `conversation` or `screen`, [from] `list`, `notification`, `new` or `switch`.
  private func countOpened(_ view: String, from: String) {
    app.analytics.event("session_opened", ["view": .string(view), "from": .string(from)])
  }

  /// A window just opened from the phone (the new session sheet): its conversation if an agent started in it,
  /// else its screen, saying where on the computer it went.
  func opened(_ opened: Opened, agent: Bool) {
    if agent {
      // An agent the phone started: its session's key is its window's.
      openSession(opened.window, starting: true)
    } else {
      openWindow(opened.window, starting: true)
    }
    if let text = openedText(opened.where) { Toaster.shared.show(text) }
  }

  /// A screen-only window switched to a conversation: its page replaces the screen's.
  func switched(window: String, key: String, after: AfterSwitch) {
    app.tips.switched(window)
    countOpened("conversation", from: "switch")
    if let i = path.lastIndex(of: .terminal(window: window)) ?? path.lastIndex(where: {
      if case .terminal(let w, _) = $0 { w == window } else { false }
    }) {
      path[i] = .session(key: key, after: after)
    } else {
      path.append(.session(key: key, after: after))
    }
  }

  // MARK: Routed sessions (a tapped push, a followed session's link)

  /// A tapped session on its way to showing: computer [desktop]'s session [key], given up when [timer] fires;
  /// [opened] once its page is open.
  private final class Routed {
    init(desktop: String, key: String) {
      self.desktop = desktop
      self.key = key
    }
    let desktop: String
    let key: String
    var timer: Task<Void, Never>?
    var opened = false
  }
  private var routed: Routed?

  /// Opens the session whose terminal push was tapped, if one was.
  func openTappedSession() {
    if let key = Push.shared.takeTappedSession() { openRouted(key) }
  }

  /// Opens the session a followed session's link named, if one did.
  func openLinkedSession() {
    if app.openedSession != nil, let key = app.takeOpenedSession() { openRouted(key) }
  }

  /// A session of one of the computers (a tapped push or followed session, also one that launched the app),
  /// over that computer's list: the computer is selected as soon as it's listed, the session's page opens at
  /// once (with what this phone has of it, and the link's note: connecting…) and fills in as the computer
  /// answers. If the session isn't there after [routedWait], or the computer says it's gone, the page goes,
  /// the list stays and a message says why.
  func openRouted(_ key: String) {
    guard let r = splitRoutedKey(key) else { return }
    timing("deep link")
    dropRouted()
    let routed = Routed(desktop: r.desktop, key: r.key)
    routed.timer = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.routedWait))
      if !Task.isCancelled { self?.routedTimedOut() }
    }
    self.routed = routed
    if !desktops.all.contains(where: { $0.id == r.desktop }) { Task { await desktops.refresh() } }
    advanceRouted()
  }

  /// The routed session one step on, as far as what's known allows: its computer selected, its page open, done
  /// once the computer lists it.
  private func advanceRouted() {
    guard let r = routed, let desktop = desktops.all.first(where: { $0.id == r.desktop }) else { return }
    if !r.opened {
      if locked(desktop) {
        desktops.select(desktop.id)
        return giveUpRouted("Scan \(desktop.name)\u{2019}s code to open its sessions.")
      }
      if desktops.selected?.id != desktop.id { return desktops.select(desktop.id) }  // Comes back here.
      guard let t = remote, t.desktopId == desktop.id else { return }  // Until its remote is made.
      timing("session page")
      r.opened = true
      countOpened("conversation", from: "notification")
      path = [.session(key: r.key)]
    }
    guard let t = remote else { return }
    // What the computer says now, not what this phone kept.
    if !t.online || t.fromCache { return }
    if t.session(r.key) != nil {
      timing("session shown")
      return dropRouted()
    }
    giveUpRouted("That session isn\u{2019}t on \(desktop.name) anymore.")
  }

  private func routedTimedOut() {
    guard let r = routed else { return }
    let name = desktops.all.first { $0.id == r.desktop }?.name
    let link = r.opened ? remote?.link : nil
    if name == nil {
      giveUpRouted("That session\u{2019}s computer isn\u{2019}t on this server.")
    } else if link == .unreachable {
      giveUpRouted("Can't reach \(app.userName), so that session didn't open.")
    } else {
      giveUpRouted(
        "\(name!) didn't answer in time, so that session didn't open. It opens from the list once \(name!) answers.")
    }
  }

  /// Stops waiting for the routed session: its page goes (the list stays) and [why] shows.
  private func giveUpRouted(_ why: String) {
    let r = routed
    dropRouted()
    timing("deep link gave up")
    if let r, r.opened {
      path.removeAll { if case .session(let k, _, _) = $0 { k == r.key } else { false } }
    }
    Toaster.shared.show(why)
  }

  private func dropRouted() {
    routed?.timer?.cancel()
    routed = nil
  }

  /// The home page is going (signed out, the demo left): its remote and timers go with it.
  func dispose() {
    refresher?.cancel()
    notices?.cancel()
    dropRouted()
    bag.removeAll()
    if Push.shared.onTapped != nil { Push.shared.onTapped = nil }
    SessionActivities.shared.onNative = nil
    if let t = remote {
      remote = nil
      dropRemote(t)
    }
    if !fixed { desktops.dispose() }
  }
}
