#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals

/// The desktop app: `Session` plus its main window and the terminal bridge.
@MainActor
open class AppController: Session {
  /// `prefs`: the app's preferences (UserDefaultsPreferenceStore, Flutter's migrated once); `device`: this
  /// computer's name; `host`: its window, menu-bar item, launch at login, keeping awake. The rest stand in for
  /// the real ones in tests.
  public init(
    prefs: PreferenceStore,
    device: String,
    host: DesktopHost,
    integrations: Integrations? = nil,
    secrets: SecureStore? = nil,
    tailscale: Tailscale? = nil,
    serverDir: (() -> URL)? = nil,
    builtInServer: (@MainActor (_ dataDir: URL, _ tailscale: Tailscale) -> BuiltInServer)? = nil,
    commands: Commands? = nil,
    terminals: Terminals? = nil,
    hostingPort: Int = 47900
  ) {
    let secrets = secrets ?? SystemSecrets.standard()
    self.prefs = prefs
    self.host = host
    self.integrations = integrations ?? Integrations()
    self.keys = ChannelKeys(secrets)
    self.tailscale = tailscale ?? Tailscale()
    self.commands = commands ?? Commands()
    self.serverDir = serverDir ?? Self.appServerDir
    self.makeBuiltInServer = builtInServer ?? { BuiltInServer(dataDir: $0, tailscale: $1) }
    self.terminals = terminals ?? Terminals.standard(kittyDir: Self.kittyDir(testHooks()))
    self.hostingPort = hostingPort
    super.init(
      device: device, deviceTokens: SecretDeviceTokens(secrets), backendStore: PreferencesBackendStore(prefs))
  }

  private let prefs: PreferenceStore

  /// The computer's side: the window, the menu-bar item, launch at login, keeping awake.
  public let host: DesktopHost

  /// Installs PocketTerm into the coding agents (Integrations.swift).
  public let integrations: Integrations

  /// Installs the setup offers to run (Homebrew's tmux and Tailscale), each once the person confirmed it.
  public let commands: Commands

  private func changed() { objectWillChange.send() }

  // ---------------------------------------------------------------- launch at login

  /// Whether PocketTerm starts at login, as the system has it; nil until `refreshLaunchAtLogin` asked.
  @Published public private(set) var launchAtLogin: Bool?

  public func refreshLaunchAtLogin() async {
    launchAtLogin = await host.launchAtLogin()
  }

  /// Throws what the system said when it refused; `launchAtLogin` is then how it stands still.
  public func setLaunchAtLogin(on: Bool) async throws {
    do {
      try await host.setLaunchAtLogin(on: on)
    } catch {
      await refreshLaunchAtLogin()
      throw error
    }
    await refreshLaunchAtLogin()
  }

  // ---------------------------------------------------------------- terminal from phone

  /// Set once this computer has had its first sign-in (`onSignedIn`).
  static let firstSignInKey = "first_sign_in_done"

  static let terminalKey = "terminal_bridge"

  /// The phone may see and type into this computer's terminals and the coding sessions (TerminalBridge):
  /// whoever holds the account can then type here. Turned on by the first sign-in (`onSignedIn`), then as
  /// Settings has it.
  public var terminalOn: Bool { prefs.bool(Self.terminalKey) ?? false }

  private var bridge: TerminalBridge?

  /// Whose `<desktop id>` topic `bridge` is on: the server's id.
  private var bridgeUser: String?

  /// The bridge running now, for the app's status (its phones, its clock check).
  public var terminalBridge: TerminalBridge? { bridge }

  /// How far a phone's clock is off this computer's while it's too far for anything from it to be taken
  /// (TerminalBridge.clockOff); nil otherwise.
  open var phoneClockOff: TimeInterval? { bridge?.clockOff }

  /// `startBridge` calls, one after the other.
  private var bridging: Task<Void, Error>?

  /// While the bridge runs: this computer tells the server it's there (`seen`) every `seenEvery`, so the phone
  /// lists it.
  private var seenTimer: MainTimer?
  private var seenOut: Task<Void, Never>?
  static let seenEvery: TimeInterval = 60

  private static let idChars = Array("abcdefghijklmnopqrstuvwxyz0123456789")

  /// This computer on server `userId` (its desktops list): made up the first time, then kept.
  public func desktopId(_ userId: String) -> String {
    let key = "desktop_id_\(userId)"
    if let id = prefs.string(key) { return id }
    var rng = SystemRandomNumberGenerator()
    let id = String((0..<8).map { _ in Self.idChars[Int.random(in: 0..<Self.idChars.count, using: &rng)] })
    prefs.setString(key, id)
    return id
  }

  private let keys: ChannelKeys

  /// This computer's channel key for the signed-in account (ChannelKeys.swift).
  public func channelKey() async throws -> ChannelKey { try await keys.of(desktopId(user!.id)) }

  open override func pairingComputer() async -> ComputerKey? {
    guard let user, let key = try? await keys.of(desktopId(user.id)) else { return nil }
    return ComputerKey(desktop: desktopId(user.id), key: key)
  }

  /// A new channel key (Settings → Phone → Reset key): every phone has to scan this computer's code again. The
  /// bridge starts over with it.
  public func resetChannelKey() async throws {
    try await keys.reset(desktopId(user!.id))
    bridgeUser = nil
    try await startBridge()
  }

  /// What the phone calls this computer: its name, as the server takes it.
  nonisolated public static func desktopName(_ device: String) -> String {
    let name = device.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "Computer" }
    // UTF-16 units, as Dart counts the 80.
    let units = Array(name.utf16)
    return units.count <= 80 ? name : String(decoding: units[..<80], as: UTF16.self)
  }

  /// This computer's terminals (kitty's sockets are in `kittyDir`).
  public let terminals: Terminals

  /// Where kitty's sockets are: /tmp, or the directory `POCKETTERM_KITTY_DIR` names in a test build
  /// (`testHooks`), so a second PocketTerm under test talks to a kitty of its own.
  nonisolated public static func kittyDir(_ env: [String: String]) -> String {
    if let dir = env["POCKETTERM_KITTY_DIR"], !dir.isEmpty { return dir }
    return "/tmp"
  }

  static let terminalAppKey = "terminal_app"

  /// The terminal app new sessions from the phone open in: an app's id (TerminalHost.id), or `auto` (the one
  /// used last).
  public var terminalApp: String { prefs.string(Self.terminalAppKey) ?? "auto" }

  public func setTerminalApp(_ id: String) {
    prefs.setString(Self.terminalAppKey, id)
    changed()
  }

  static let placementKey = "session_placement"

  /// Whether a new session from the phone opens as a tab in its project's window (the default) or in a window
  /// of its own.
  public var placement: Placement { prefs.string(Self.placementKey).flatMap(Placement.init(rawValue:)) ?? .projectWindow }

  public func setPlacement(_ placement: Placement) {
    prefs.setString(Self.placementKey, placement.name)
    changed()
  }

  static let projectRootsKey = "project_roots"

  /// Folders holding the user's projects (Settings → Project folders): the phone lists the git repositories
  /// under them and makes new projects there.
  public var projectRoots: [String] { prefs.stringList(Self.projectRootsKey) ?? [] }

  public func setProjectRoots(_ roots: [String]) {
    prefs.setStringList(Self.projectRootsKey, roots)
    changed()
  }

  static let agentKey = "coding_agent"

  /// The coding agent a new session from the phone starts.
  public var codingAgent: Agent { Agent.parse(prefs.string(Self.agentKey).map(JSON.string)) }

  public func setCodingAgent(_ agent: Agent) {
    prefs.setString(Self.agentKey, agent.name)
    changed()
  }

  static let setupStepKey = "setup_step"
  static let setupAddressKey = "setup_address"

  /// Where the first-run setup was left: the screen's name, nil on the first one. It opens there again.
  public var setupStep: String? { prefs.string(Self.setupStepKey) }

  public func setSetupStep(_ step: String?) {
    if let step { prefs.setString(Self.setupStepKey, step) } else { prefs.remove(Self.setupStepKey) }
  }

  /// The VPS address typed in the first-run setup, as typed.
  public var setupAddress: String { prefs.string(Self.setupAddressKey) ?? "" }

  public func setSetupAddress(_ address: String) { prefs.setString(Self.setupAddressKey, address) }

  static let getReadyKey = "get_ready_done"

  /// The setup checklist was finished or skipped on this computer; until then the signed-in window shows it.
  public var getReadyDone: Bool { prefs.bool(Self.getReadyKey) ?? false }

  public func setGetReadyDone(_ done: Bool) {
    prefs.setBool(Self.getReadyKey, done)
    changed()
  }

  // ---------------------------------------------------------------- agents

  /// The coding agents found on this computer and PocketTerm in each, as of the last `checkAgents`; nil
  /// before the first one ends.
  @Published public private(set) var agents: [Agent: AgentCheck]?
  private var checkingAgents: Task<Void, Never>?

  /// This computer's omp profiles besides the default, as of the last `checkAgents`; empty without omp.
  @Published public private(set) var ompProfiles: [String] = []
  private var agentsAt: Date?

  /// Looks for the coding agents and PocketTerm in them. One look at a time: a call while one runs waits for it.
  public func checkAgents() async {
    if let checkingAgents { return await checkingAgents.value }
    let look = Task { await lookForAgents() }
    checkingAgents = look
    await look.value
    checkingAgents = nil
  }

  private func lookForAgents() async {
    var found: [Agent: AgentCheck] = [:]
    for agent in Agent.allCases {
      do {
        if !(await integrations.found(agent)) { continue }
        let state = try await integrations.state(agent)
        let modsOff = agent == .claude && state.installed ? await integrations.claudeModsOff() : false
        found[agent] = AgentCheck(state: state, modsOff: modsOff)
      } catch {
        found[agent] = AgentCheck(
          state: IntegrationState(installed: false, current: false, problem: "\(error)"), modsOff: false)
      }
    }
    agents = found
    ompProfiles = found[.omp] != nil ? integrations.ompProfiles() : []
    agentsAt = Date()
  }

  /// Installs (or updates) PocketTerm in `agent`, then looks again. Throws what went wrong.
  public func installAgent(_ agent: Agent) async throws {
    do {
      try await integrations.install(agent)
    } catch {
      await checkAgents()
      throw error
    }
    await checkAgents()
  }

  /// What the phone hears (TerminalBridge): looked at again when the last look is older than `agentsEvery`,
  /// since it runs `claude`.
  private func agentsForPhone() async -> [Agent: AgentIntegration] {
    if agentsAt.map({ Date().timeIntervalSince($0) > Self.agentsEvery }) ?? true { await checkAgents() }
    return (agents ?? [:]).mapValues(integrationOf)
  }

  static let agentsEvery: TimeInterval = 30

  /// The terminal windows running a coding agent that no live session claims: started before PocketTerm was in
  /// it (or with it off), so they reach the phone only as screens.
  public func unreportedAgentWindows(_ windows: [TermWindow]) -> [TermWindow] {
    let claimed = Set(live.sessions.compactMap(\.window))
    return windows.filter { $0.agent != nil && !claimed.contains($0.key) }
  }

  // ---------------------------------------------------------------- phone

  /// A phone has signed in to this server: it's among the server's devices (`phoneCodeUsed`) or said hello to
  /// this computer. Kept per server on this computer once seen. Nil until known.
  public var phoneSignedIn: Bool? { phoneSignedInNow ?? (phoneKept ? true : nil) }
  @Published private var phoneSignedInNow: Bool?

  private var phoneKey: String { "phone_signed_in_\(user?.id ?? "")" }
  private var phoneKept: Bool { user != nil && (prefs.bool(phoneKey) ?? false) }

  /// Asks the server, until the answer is yes.
  public func checkPhone() async {
    if phoneSignedIn ?? false { return }
    do {
      let used = try await phoneCodeUsed()
      if used { return phoneHeard() }
      if used == phoneSignedInNow { return }
      phoneSignedInNow = used
    } catch {
      debugLog("PocketTerm: phone sign-in unknown: \(error)")
    }
  }

  /// A phone is signed in to this server (GET /v1/devices).
  open func phoneCodeUsed() async throws -> Bool {
    try await server!.devices().contains { $0.role == .phone }
  }

  private func phoneHeard() {
    if user != nil { prefs.setBool(phoneKey, true) }
    if phoneSignedInNow ?? false { return }
    phoneSignedInNow = true
  }

  /// The coding sessions reporting to the local API (integrations/).
  public private(set) lazy var live: LiveHub = {
    let hub = LiveHub(locate: LiveHub.locate(using: terminals))
    let events = hub.events
    liveEvents = Task { [weak self] in
      for await e in events { await self?.onLive(e) }
    }
    return hub
  }()
  private var liveEvents: Task<Void, Never>?

  open func setTerminal(on: Bool) async throws {
    prefs.setBool(Self.terminalKey, on)
    changed()
    try await startBridge()
  }

  /// One bridge for the signed-in user while `terminalOn`: a new one when the user changes, none when they're
  /// gone however they went. Calls run one at a time, so two at once (the switch while a sign-in lands) don't
  /// both build one.
  private func startBridge() async throws {
    let before = bridging
    let next = Task { @MainActor in
      _ = await before?.result
      try await self.syncBridge()
    }
    bridging = next
    try await next.value
  }

  private func syncBridge() async throws {
    let want = terminalOn ? user?.id : nil
    if want == bridgeUser { return }
    let old = bridge
    bridge = nil
    bridgeUser = nil
    seenTimer?.cancel()
    seenTimer = nil
    await old?.stop()
    changed()
    guard let want, let server else { return }
    let id = desktopId(want)
    let key = try await keys.of(id)
    bridgeUser = want
    let b = TerminalBridge(
      server, id, key, terminals, live, host,
      agent: { [unowned self] in self.codingAgent },
      app: { [unowned self] in self.terminalApp },
      roots: { [unowned self] in self.projectRoots },
      agents: { [unowned self] in await self.agentsForPhone() },
      ompProfiles: { [unowned self] in self.ompProfiles },
      onPhone: { [unowned self] in self.phoneHeard() },
      placement: { [unowned self] in self.placement }
    )
    bridge = b
    await b.start()
    changed()
    seen(id)
    seenTimer = MainTimer(every: Self.seenEvery) { [weak self] in self?.seen(id) }
  }

  /// Tells the server this computer `id` is there now (the server stamps seen_at by its own clock); a failure
  /// waits for the next beat.
  private func seen(_ id: String) {
    let before = seenOut
    let name = Self.desktopName(device)
    seenOut = Task { @MainActor [weak self] in
      await before?.value
      do {
        try await self?.server?.putDesktop(id, name: name, platform: "macos")
      } catch {
        debugLog("PocketTerm: computer not listed: \(error)")
      }
    }
  }

  /// A run ended, or the agent waits for an answer: the phones hear about it, unless it's showing that session
  /// right now.
  private func onLive(_ e: LiveEvent) async {
    let s = e.session
    if bridge?.watching(s.key) ?? false { return }
    let project = live.projectName(s)
    let place = project.isEmpty ? "" : " · \(project)"
    let (title, body, state): (String, String, String) =
      switch e {
      case .finished(_, let summary): ("\(s.agent.labelIn(s.profile)) finished\(place)", summary, "done")
      case .asked(_, let ask): ("\(s.agent.labelIn(s.profile)) needs you\(place)", ask.text, "needs")
      }
    _ = await notifyPhone(title, body, session: s.key, activity: state)
  }

  open override func start() async {
    await host.start { [weak self] event in await self?.onHost(event) }
    if prefs.bool(Self.hostingKey) ?? false {
      do {
        try await startHostingServer()
        // Where it listens now, should the port have moved: the sign-in kept for the old one doesn't count,
        // and this computer signs in again.
        hosting!.backend.save(to: backendStore)
      } catch {
        debugLog("PocketTerm: built-in server not started: \(error)")
      }
    }
    await super.start()
    await signInToOwnServer()
    // Not set up or signed out: there's nothing to do but that, so say so.
    if user == nil { await openMain() }
  }

  // ---------------------------------------------------------------- hosting

  /// This computer runs the server ("This computer" in the first-run setup): it starts with the app, until
  /// signing out here.
  static let hostingKey = "hosting"

  /// The port it listened on last, tried first next time.
  static let hostingPortKey = "hosting_port"

  /// Where the built-in server listens on its first start (the next free port above it when taken). Tests give
  /// 0, a port the system picks.
  public let hostingPort: Int

  /// The Tailscale CLI, which publishes the built-in server.
  public let tailscale: Tailscale

  /// Where the built-in server keeps its data.
  private let serverDir: () -> URL

  /// Makes the built-in server: the bundled binary's (`Contents/Helpers/pocketterm-server`) unless a test gives
  /// another.
  private let makeBuiltInServer: @MainActor (_ dataDir: URL, _ tailscale: Tailscale) -> BuiltInServer

  /// App support `pocketterm-server/`.
  static func appServerDir() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let bundle = Bundle.main.bundleIdentifier ?? "com.danyzmaj.pocketterm"
    return support.appendingPathComponent(bundle).appendingPathComponent("pocketterm-server")
  }

  /// The built-in server, while this computer runs it.
  @Published public private(set) var hosting: BuiltInServer?
  private var hostingChanges: Task<Void, Never>?

  open override var hostsServer: Bool { hosting?.running ?? false }

  /// The ports this app's built-in server listens on now and listened on last: a Serve entry to one of these
  /// is this app's own.
  public var ownServerPorts: Set<Int> {
    var ports = Set<Int>()
    if let h = hosting, h.running { ports.insert(h.port) }
    if let last = prefs.int(Self.hostingPortKey) { ports.insert(last) }
    return ports
  }

  /// "This computer": starts the built-in server, from now on at every launch, and signs this computer in to
  /// it. Throws what went wrong. A sign-in that fails (the Keychain refused it, say) takes it all back: the
  /// server stops and nothing is kept, so a later choice isn't overruled at the next launch; `authError` says
  /// why.
  public func startHosting() async throws {
    try await startHostingServer()
    await signInToOwnServer()
    if user == nil {
      await undoStart()
      return
    }
    prefs.setBool(Self.hostingKey, true)
  }

  private func undoStart() async {
    let why = authError
    await disconnect()
    authError = why
  }

  private func startHostingServer() async throws {
    if hosting != nil { return }
    let h = makeBuiltInServer(serverDir(), tailscale)
    do {
      let last = prefs.int(Self.hostingPortKey)
      try await h.start(port: last ?? hostingPort, earlier: last)
    } catch {
      h.dispose()
      throw error
    }
    hosting = h
    let changes = h.objectWillChange
    hostingChanges = Task { [weak self] in
      for await _ in changes.values { self?.changed() }
    }
    prefs.setInt(Self.hostingPortKey, h.port)
  }

  /// A computer running the server signs itself in with the server's own setup token, on 127.0.0.1.
  private func signInToOwnServer() async {
    guard let h = hosting, user == nil else { return }
    do {
      await connectLink(try await h.ownSetupLink())
    } catch {
      authError = "\(error)"
    }
  }

  private func stopHosting() async {
    guard let h = hosting else { return }
    hosting = nil
    hostingChanges?.cancel()
    hostingChanges = nil
    prefs.setBool(Self.hostingKey, false)
    await h.stop()
    h.dispose()
  }

  /// "Add a computer…": the link another computer sets up with (through Tailscale); nil until Tailscale serves
  /// this one.
  public func computerSetupLink() async -> URL? { try? await hosting?.setupLink() }

  /// A phone's code from a computer running the server carries its Tailscale address: phones can't reach
  /// 127.0.0.1.
  open override func pairingLink() async throws -> URL {
    guard let h = hosting else { return try await super.pairingLink() }
    guard let url = h.publicUrl else {
      throw PairingException("Tailscale isn’t serving this computer yet. See Settings → Account.")
    }
    let code: String
    do {
      code = try await server!.createPairingCode()
    } catch let e as ServerException {
      throw PairingException(e.message)
    }
    return Backend(url: url.absoluteString).linkWithCode(code, computer: await pairingComputer())
  }

  /// Every computer and phone signed in to the server.
  open func serverDevices() async throws -> [Device] { try await server!.devices() }

  /// Signs device `id` out of the server (a lost phone): its sign-in stops working and its push registrations
  /// go.
  open func revokeServerDevice(_ id: String) async throws { try await server!.revokeDevice(id) }

  /// Signing out of a server this computer runs stops it, and the first-run setup shows again. Its data stays:
  /// This computer starts it again with the same phones and computers.
  open override func signOut() async {
    await super.signOut()
    if hosting != nil { await disconnect() }
  }

  open override func disconnect() async {
    await super.disconnect()
    await stopHosting()
  }

  /// Erasing signs this computer out too; it signs in again at once, as the first computer of an empty server.
  open override func eraseServer() async throws {
    let key = phoneKey
    try await super.eraseServer()
    prefs.remove(key)
    await signInToOwnServer()
  }

  /// Stops what a quit ends with the process: the terminal bridge, the beat that lists this computer, the
  /// server connection. For a test that starts the app again in the same process.
  public func shutDown() async {
    seenTimer?.cancel()
    seenTimer = nil
    await seenOut?.value
    let b = bridge
    bridge = nil
    bridgeUser = nil
    await b?.stop()
    await hosting?.stop()
    server?.close()
  }

  /// The first sign-in on this computer turns on Terminal from phone (what PocketTerm is for); after that it
  /// stays as the user leaves it. Launch at login stays off until the user turns it on (Settings → Account): a
  /// login item is the person's to add.
  open override func onSignedIn(_ user: Account) async {
    if prefs.bool(Self.firstSignInKey) ?? false {
      do { try await startBridge() } catch { debugLog("PocketTerm: terminal bridge not started: \(error)") }
      return
    }
    do {
      try await setTerminal(on: true)
    } catch {
      debugLog("PocketTerm: terminal bridge not started: \(error)")
    }
    prefs.setBool(Self.firstSignInKey, true)
  }

  /// The phone stops listing this computer.
  open override func onSigningOut() async throws {
    seenTimer?.cancel()
    seenTimer = nil
    await seenOut?.value
    guard let id = prefs.string("desktop_id_\(user?.id ?? "null")") else { return }
    try await server?.deleteDesktop(id)
  }

  /// However the sign-in went (signed out here, the server stopped taking it): the terminal bridge stops.
  open override func onSignedOut() async {
    // The next account's phones are its own.
    phoneSignedInNow = nil
    do {
      try await startBridge()
    } catch {
      debugLog("PocketTerm: terminal bridge not stopped: \(error)")
    }
  }

  /// A setup link to another server waits for a yes: in the main window.
  open override func onLinkToConfirm() { Task { await openMain() } }

  /// What a link said while signed in shows in the main window.
  open override func onNotice(_ message: String) { Task { await openMain() } }

  // ---------------------------------------------------------------- window

  /// Runs when PocketTerm quits, before the app goes (a second at most): the local API takes itself out of
  /// cli.json.
  public var onQuit: (@MainActor () async -> Void)?

  /// What the host says: the menu-bar item, the Dock icon, quitting. A closed window (mainClosed) is only
  /// hidden: `mainHidden` says so.
  func onHost(_ event: String) async {
    switch event {
    // Settings is the window while signed in.
    case "openMain", "openSettings":
      await openMain()
    case "mainClosed":
      mainHidden = true
    case "quitting":
      let quit = onQuit
      let h = hosting
      async let a: Void = quit?() ?? ()
      async let b: Void = h?.stop() ?? ()
      _ = await (a, b)
    default:
      break
    }
  }

  /// Ticks each time the main window is shown: it stays alive while hidden, so Settings checks the terminals
  /// and the agent's integration afresh.
  @Published public private(set) var mainShown = 0

  /// The main window was closed (hidden) and not shown since.
  @Published public private(set) var mainHidden = false

  /// Shows the main window.
  public func openMain() async {
    mainShown += 1
    mainHidden = false
    await host.showMain()
  }

  /// Pushes `title` / `body` to the phones (POST /v1/push/notify) when nobody has touched this computer for a
  /// minute: at the desk, its own screen says it already. `session`: the coding session a tap opens;
  /// `activity`: where it stands (done, needs). Sealed with this computer's key; outside the seal go only this
  /// computer's push tag and the session's (pushTag, sessionTag), which mean nothing without the key (Live
  /// Activities move by the bridge's own pushes). False if it didn't go.
  open func notifyPhone(_ title: String, _ body: String, session: String? = nil, activity: String? = nil) async
    -> Bool
  {
    guard let user else { return false }
    if await host.idleSeconds() < 60 { return false }
    do {
      let id = desktopId(user.id)
      let key = try await keys.of(id)
      let routed = session.map { routedKey(id, $0) }
      var notice: JSONObject = ["title": .string(title), "body": .string(body)]
      if let routed { notice["session"] = .string(routed) }
      if let activity { notice["state"] = .string(activity) }
      var push: JSONObject = ["tag": .string(pushTag(key)), "enc": .string(sealNotice(key, id, notice))]
      // Lets a newer push for the same session replace an older one.
      if let routed { push["collapse"] = .string(sessionTag(key, routed)) }
      let data = try await invokePush("notify", push)
      return (data["sent"]?.int ?? 0) > 0
    } catch {
      debugLog("PocketTerm: notify failed: \(error)")
      return false
    }
  }

  /// Push `action` with `body` on the server; its answer.
  open func invokePush(_ action: String, _ body: JSONObject) async throws -> JSONObject {
    try await server!.push(action, body)
  }

  deinit {
    liveEvents?.cancel()
    hostingChanges?.cancel()
  }
}
#endif
