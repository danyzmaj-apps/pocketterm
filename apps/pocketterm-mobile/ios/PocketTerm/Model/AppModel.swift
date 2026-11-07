import Foundation
import PocketTermKit
import UIKit

/// The phone side of [Session]: keeps the computers' channel keys (from their QR codes) where the push
/// extension reads them too (Shared/PocketTermShared.swift: it opens a computer's pushes with its key),
/// registers this phone for the computer's terminal pushes, ends the sessions it follows when it leaves the
/// server, and runs the demo. Also the phone's preferences the home page reads and writes.
final class AppModel: Session {
  init(
    prefs: Preferences, device: String, deviceTokens: DeviceTokens = KeychainDeviceTokens(),
    backendStore: BackendStore = AppGroupBackendStore(), native: PhoneNative = .ios
  ) {
    self.prefs = prefs
    self.native = native
    tips = TipsController(prefs: prefs)
    super.init(device: device, deviceTokens: deviceTokens, backendStore: backendStore)
  }

  let prefs: Preferences

  /// What the phone itself does: the Keychain's channel keys, push, Live Activities. Tests hand in their own.
  let native: PhoneNative

  /// The first-use tips this phone has shown; kept across sign-outs, they're the phone's.
  let tips: TipsController

  /// A phone signs in only with a code from the computer.
  override var role: DeviceRole { .phone }

  /// The phone opens on what it had (its computers, their sessions, from cache) while the server is asked
  /// whether the sign-in still holds.
  override var signInAtOnce: Bool { true }

  private var computerKeys: [String: ChannelKey] = [:]

  /// Computer [desktopId]'s channel key; nil while this phone hasn't scanned that computer's code: the computer
  /// is locked, nothing from it shows and nothing goes to it.
  override func computerKey(_ desktopId: String) -> ChannelKey? {
    if let demo, user == nil, desktopId == DemoComputer.desktopId { return demo.remote.key }
    return computerKeys[desktopId]
  }

  /// Until [launch] has read what this phone kept (its server, sign-in and computer keys): nothing shows yet,
  /// rather than setup for a moment.
  @Published private(set) var launching = false

  func launch() async {
    launching = true
    defer { launching = false }
    await forgetOldApp()
    await leaveSupabase()
    loadComputerKeys()
    await start()
  }

  // MARK: Links

  /// A followed session's link (`pocketterm://session?key=<routed key>`, a Live Activity's), kept until the
  /// home page takes it ([takeOpenedSession]): the one that launched the app comes before there's a home page.
  override func onOtherLink(_ uri: URL) {
    guard uri.scheme == "pocketterm", uri.host == "session",
      let key = URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?
        .value, !key.isEmpty
    else { return }
    openedSession = key
  }

  /// The routed key of the session a link opened, until taken.
  @Published private(set) var openedSession: String?

  func takeOpenedSession() -> String? {
    defer { if openedSession != nil { openedSession = nil } }
    return openedSession
  }

  // MARK: Migration from 0.1

  /// PocketTerm 0.1 connected through a Supabase project (its URL kept with that project's key): no server this
  /// app talks to. What it left goes, so the phone starts at setup: the project, a sign-in and computer keys if
  /// any, the Supabase session and the computers list it cached, and the sessions it followed. The tips seen
  /// and the list's order stay.
  func forgetOldApp() async {
    guard backendStore.loadBackend()?.legacy == true else { return }
    backendStore.saveBackend(url: nil, kind: nil)
    do {
      try await deviceTokens.write(nil)
    } catch {
      debugLog("PocketTerm: the old app’s sign-in not removed: \(error)")
    }
    native.removeAllChannelKeys()
    for k in prefs.defaults.dictionaryRepresentation().keys
    where k.hasPrefix("sb-") || k.hasPrefix("supabase")
      // Written by older versions, never read.
      || k == "pocketterm_push_token" || k == Self.desktopKey || k == Self.desktopsKey
    {
      prefs.remove(k)
    }
    await native.endAllActivities()
  }

  static let movedKey = "server_moved"

  /// What the setup says after [leaveSupabase] signed this phone out, until it signs in again; nil otherwise.
  var movedNote: String? {
    prefs.bool(Self.movedKey) ?? false ? "Your computer's PocketTerm now runs its own server. Scan its new code." : nil
  }

  /// PocketTerm no longer runs on Supabase: a computer now runs its own server, over Tailscale. A phone signed in
  /// to a Supabase project is signed out here (Supabase isn't asked): its sign-in, saved server, computer keys
  /// and followed sessions go, and the setup says [movedNote] until the computer's new code is scanned. Any other
  /// server stays.
  func leaveSupabase() async {
    guard let saved = backendStore.loadBackend(), !saved.legacy, saved.kind == supabaseKind else { return }
    backendStore.saveBackend(url: nil, kind: nil)
    do {
      try await deviceTokens.write(nil)
    } catch {
      debugLog("PocketTerm: the Supabase sign-in not removed: \(error)")
    }
    native.removeAllChannelKeys()
    prefs.setBool(Self.movedKey, true)
    await native.endAllActivities()
  }

  /// The keys the Keychain keeps.
  func loadComputerKeys() {
    computerKeys = native.channelKeys()
    objectWillChange.send()
  }

  /// The computer whose code was last scanned, until the home page shows it ([takeScannedComputer]).
  private var scanned: String?

  /// The computer just scanned, once: the home page shows it rather than whichever was seen last.
  func takeScannedComputer() -> String? {
    defer { scanned = nil }
    return scanned
  }

  override func addComputerKey(_ computer: ComputerKey) async {
    scanned = computer.desktop
    if computerKeys[computer.desktop] != computer.key {
      do {
        try native.setChannelKey(computer.key, computer.desktop)
        computerKeys[computer.desktop] = computer.key
      } catch {
        debugLog("PocketTerm: computer key not kept: \(error)")
      }
    }
    objectWillChange.send()
  }

  // MARK: Demo

  /// "Try the demo": a made-up computer answered on this phone (Demo/), shown while signed out; nil otherwise.
  @Published private(set) var demo: DemoComputer?

  func enterDemo() {
    if user != nil || demo != nil { return }
    demo = DemoComputer(cacheDir: FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm_demo-\(UUID().uuidString)"))
  }

  /// Back to the setup screen (or on, once signed in).
  func exitDemo() {
    guard let d = demo else { return }
    demo = nil
    // After the frame that stops showing it.
    Task { @MainActor in d.dispose() }
  }

  // MARK: Preferences the home page keeps

  static let foldedKey = "pocketterm_terminal_folded"

  /// The Terminal list's projects (folders) showing only their heading.
  var collapsedProjects: Set<String> { Set(prefs.stringList(Self.foldedKey) ?? []) }

  func setCollapsedProjects(_ cwds: Set<String>) {
    prefs.setStringList(Self.foldedKey, cwds.sorted())
    objectWillChange.send()
  }

  static let sortKey = "pocketterm_terminal_sort"

  /// How the Terminal list orders its projects; by name until chosen.
  var projectSort: ProjectSort { prefs.string(Self.sortKey).flatMap(ProjectSort.init(rawValue:)) ?? .name }

  func setProjectSort(_ sort: ProjectSort) {
    prefs.setString(Self.sortKey, sort.rawValue)
    objectWillChange.send()
  }

  static let profileFilterKey = "pocketterm_profile_filter"

  /// The omp profile whose sessions the Terminal list shows for computer [desktop] ("" the default); nil, until
  /// chosen, shows every profile's.
  func profileFilter(_ desktop: String) -> String? { prefs.string("\(Self.profileFilterKey)_\(desktop)") }

  func setProfileFilter(_ desktop: String, _ profile: String?) {
    let key = "\(Self.profileFilterKey)_\(desktop)"
    if let profile { prefs.setString(key, profile) } else { prefs.remove(key) }
    objectWillChange.send()
  }

  static let newProfileKey = "pocketterm_new_profile"

  /// The omp profile a new session on computer [desktop] starts in, as last picked; "" (the default) until then.
  func newSessionProfile(_ desktop: String) -> String { prefs.string("\(Self.newProfileKey)_\(desktop)") ?? "" }

  func setNewSessionProfile(_ desktop: String, _ profile: String) {
    prefs.setString("\(Self.newProfileKey)_\(desktop)", profile)
  }

  static let looksKey = "pocketterm_tile_looks"

  /// The names and colours the person gave rows in the Terminal list, by computer and row key. A row keeps them
  /// while its window lives; a window that closes leaves only a stale entry, which costs nothing.
  func tileLooks(_ desktop: String) -> [String: TileLook] {
    var out: [String: TileLook] = [:]
    for (key, value) in looks() where key.hasPrefix("\(desktop)|") {
      out[String(key.dropFirst(desktop.count + 1))] = value
    }
    return out
  }

  func setTileLooks(_ desktop: String, _ looks: [String: TileLook]) {
    var all = self.looks().filter { !$0.key.hasPrefix("\(desktop)|") }
    for (key, value) in looks where value.name != nil || value.color != nil { all["\(desktop)|\(key)"] = value }
    prefs.setString(Self.looksKey, JSON.object(all.mapValues { .object($0.toJson()) }).encoded())
    objectWillChange.send()
  }

  private func looks() -> [String: TileLook] {
    guard let json = JSON.tryParse(prefs.string(Self.looksKey) ?? "{}")?.object else { return [:] }
    return json.compactMapValues { $0.object.map(TileLook.init(json:)) }
  }

  /// Unsent prompt text per session.
  var drafts: Drafts { Drafts(prefs: prefs) }

  static let desktopKey = "pocketterm_desktop"
  static let desktopsKey = "pocketterm_desktops"

  /// The account's computers, starting from the list and the choice this phone kept, and keeping them as they
  /// change.
  func desktops() -> Desktops {
    let cached = (JSON.tryParse(prefs.string(Self.desktopsKey) ?? "[]")?.array ?? []).compactMap {
      $0.object.flatMap(Desktop.init(json:))
    }
    let prefs = prefs
    return Desktops(
      server!, cached: cached, saved: prefs.string(Self.desktopKey),
      onChanged: { all, selected in
        prefs.setString(Self.desktopsKey, JSON.array(all.map { .object($0.toJson()) }).encoded())
        if let selected { prefs.setString(Self.desktopKey, selected) } else { prefs.remove(Self.desktopKey) }
      })
  }

  // MARK: Push

  override func onSignedIn(_ user: Account) async {
    if prefs.bool(Self.movedKey) != nil {
      prefs.remove(Self.movedKey)
      objectWillChange.send()
    }
    exitDemo()
    if pushEnabled ?? false { _ = await registerPush(user.device.id) }
    await checkNotifications()
  }

  /// Whether the phone lets PocketTerm's notifications show; nil until known. Notifications on here but off in
  /// the phone's Settings (turned off there after saying yes) show nothing: the account sheet says so.
  @Published private(set) var notificationsAllowed: Bool?

  /// Asks the phone again (at sign-in, coming back to the app, after a change here).
  func checkNotifications() async {
    let allowed = await native.notificationsAllowed()
    if allowed != notificationsAllowed { notificationsAllowed = allowed }
  }

  static let pushChoiceKey = "pocketterm_push_on"

  /// The person's push choice on the signed-in server (kept per server id): nil until asked (the push consent
  /// page), and while signed out. Nothing registers for push before it's true.
  var pushEnabled: Bool? {
    guard let user else { return nil }
    return prefs.bool("\(Self.pushChoiceKey)_\(user.id)")
  }

  private var pushChoice = 0

  /// Turns push on (the system's permission, then this phone's token to the server) or off (the server forgets
  /// this phone's tokens, followed sessions end and Follow goes away). False: [on], but the phone didn't allow
  /// notifications, so it stays off.
  @discardableResult
  func setPushEnabled(_ on: Bool) async -> Bool {
    guard let u = user else { return false }
    let key = "\(Self.pushChoiceKey)_\(u.id)"
    // A later choice (Not now while Turn on still waits) wins.
    pushChoice += 1
    let choice = pushChoice
    if !on {
      let was = pushEnabled ?? false
      pushUnsent = false
      prefs.setBool(key, false)
      objectWillChange.send()
      // Not now, the first time: nothing was registered.
      if was { await pushOff() }
      return true
    }
    let registered = await registerPush(u.device.id)
    if choice != pushChoice { return true }
    prefs.setBool(key, registered)
    await checkNotifications()
    objectWillChange.send()
    return registered
  }

  /// Push is on, but the server missed this phone's token (offline): it is sent again ([retryPush]) when the
  /// app comes back, when the computer's connection is back, and when the account sheet opens.
  @Published private(set) var pushUnsent = false

  /// A missed token is on its way to the server again: the account sheet shows that instead of the old warning.
  @Published private(set) var pushRegistering = false
  private var pushTried: Date?

  /// Sends a token the server missed again, one try at a time. [force] (the app coming back, the account sheet
  /// opening) tries at once; otherwise (the connection back) not within 30 s of the last try, so a server that
  /// keeps refusing isn't asked on every state.
  func retryPush(force: Bool = false) async {
    guard pushUnsent, !pushRegistering, let user, pushEnabled ?? false else { return }
    if !force, let tried = pushTried, Date().timeIntervalSince(tried) < 30 { return }
    pushTried = Date()
    pushRegistering = true
    defer { pushRegistering = false }
    _ = await registerPush(user.device.id)
  }

  /// Hands this phone's APNs token to the server, which from then on relays the computer's terminal news
  /// (POST /v1/push/notify), sealed by each computer with its key. False: not allowed, or no token in time. A
  /// server that missed it (offline) leaves [pushUnsent] for [retryPush].
  private func registerPush(_ deviceId: String) async -> Bool {
    guard let token = await native.registerPush() else { return false }
    if user?.device.id != deviceId { return true }
    var unsent = false
    do {
      _ = try await server!.push(
        "register", ["token": .string(token), "label": .string(device), "platform": .string(native.pushPlatform)])
    } catch {
      debugLog("PocketTerm: push registration failed: \(error)")
      unsent = true
    }
    if unsent != pushUnsent { pushUnsent = unsent }
    return true
  }

  /// Push off: followed sessions end here, and the server forgets every token of this phone (its push token and
  /// its followed sessions').
  private func pushOff() async {
    await native.endAllActivities()
    await tryServer("push unregister") { try await $0.push("unregister", [:]) }
  }

  override func onSigningOut() async throws {
    let push = pushEnabled ?? false
    await forgetHere()
    // The server forgets this phone's push token and its followed sessions'.
    if push { await tryServer("push unregister") { try await $0.push("unregister", [:]) } }
  }

  /// However the sign-in went, also without signOut here (the computer signed this phone out, the server was
  /// erased): its followed sessions leave this phone.
  override func onSignedOut() async {
    await forgetHere()
  }

  /// Drops what this phone keeps for the server: the push registration's record and the push choice (the next
  /// sign-in asks again), every computer's key (the next sign-in scans a code, which brings its computer's),
  /// and the followed sessions, ended at once.
  private func forgetHere() async {
    openedSession = nil
    pushUnsent = false
    pushRegistering = false
    pushTried = nil
    // Every server's: the sign-in may already be gone, and with it its id.
    for k in prefs.keys(withPrefix: "\(Self.pushChoiceKey)_") { prefs.remove(k) }
    prefs.remove(Self.desktopKey)
    prefs.remove(Self.desktopsKey)
    native.removeAllChannelKeys()
    computerKeys.removeAll()
    await native.endAllActivities()
    objectWillChange.send()
  }

  /// One server call of a clean-up; a failed one (offline) doesn't stop the rest.
  private func tryServer(_ what: String, _ call: (Server) async throws -> Any) async {
    guard let server else { return }
    do {
      _ = try await call(server)
    } catch {
      debugLog("PocketTerm: \(what) failed: \(error)")
    }
  }
}

/// What the phone's own side does for [AppModel]: the Keychain's channel keys, push, followed sessions.
struct PhoneNative {
  var channelKeys: () -> [String: ChannelKey]
  var setChannelKey: (ChannelKey, String) throws -> Void
  var removeAllChannelKeys: () -> Void
  var registerPush: () async -> String?
  var notificationsAllowed: () async -> Bool
  var endAllActivities: () async -> Void
  var pushPlatform = "ios"

  static let ios = PhoneNative(
    channelKeys: { ChannelKeys.all() },
    setChannelKey: { try ChannelKeys.set($0, for: $1) },
    removeAllChannelKeys: { ChannelKeys.removeAll() },
    registerPush: { await Push.shared.register() },
    notificationsAllowed: { await Push.shared.allowed() },
    endAllActivities: { await SessionActivities.shared.endAll() })
}
