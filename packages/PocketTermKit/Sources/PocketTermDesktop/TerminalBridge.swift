#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals

/// The desktop side of Terminal from the phone (protocol: PocketTermKit's Live.swift): the coding sessions `LiveHub`
/// knows and the terminals' windows (`Terminals`) go out on this computer's topic on the server (its id), sealed with
/// its channel key (E2E.swift); what the phone asks for is done here, where the window's terminal can do it. The
/// terminals are polled only while a phone has said hello lately.
@MainActor
public final class TerminalBridge {
  public init(
    _ server: Server, _ desktopId: String, _ key: ChannelKey, _ terms: Terminals, _ hub: LiveHub, _ host: DesktopHost,
    agent: @escaping @MainActor () -> Agent, app: @escaping @MainActor () -> String,
    roots: @escaping @MainActor () -> [String],
    agents: (@MainActor () async throws -> [Agent: AgentIntegration])? = nil,
    ompProfiles: (@MainActor () -> [String])? = nil, onPhone: (@MainActor () -> Void)? = nil,
    placement: (@MainActor () -> Placement)? = nil
  ) {
    self.server = server
    self.desktopId = desktopId
    channelKey = key
    self.terms = terms
    self.hub = hub
    self.host = host
    self.agent = agent
    self.app = app
    self.roots = roots
    self.agents = agents
    self.ompProfiles = ompProfiles
    self.onPhone = onPhone
    self.placement = placement ?? { .projectWindow }
  }

  private let server: Server

  /// This computer, among the user's (AppController).
  private let desktopId: String

  /// This computer's channel key (channel keys).
  private let channelKey: ChannelKey
  private let terms: Terminals
  private let hub: LiveHub

  /// Keeps this computer awake while the bridge runs.
  private let host: DesktopHost

  /// The agent a new session from the phone starts (this computer's setting).
  private let agent: @MainActor () -> Agent

  /// The terminal app it opens in: an app's id or `auto` (this computer's setting).
  private let app: @MainActor () -> String

  /// Whether that is a tab in the project's window or a window of its own (this computer's setting).
  private let placement: @MainActor () -> Placement

  /// This computer's Project folders setting.
  private let roots: @MainActor () -> [String]

  /// Where PocketTerm stands in each coding agent found here (this computer's checks, which keep themselves fresh);
  /// none told if nil.
  private let agents: (@MainActor () async throws -> [Agent: AgentIntegration])?
  private var agentsNow: [Agent: AgentIntegration]?

  /// This computer's omp profiles besides the default.
  private let ompProfiles: (@MainActor () -> [String])?

  /// A phone said hello: one is signed in to this account.
  private let onPhone: (@MainActor () -> Void)?

  /// A phone that hasn't said hello for this long has left.
  static let gone: TimeInterval = 12

  /// How often a watched window's screen is read; the window list every third time.
  static let tickEvery: TimeInterval = 0.7

  /// Live ops wait this long to go out together.
  static let batch: TimeInterval = 0.15

  /// The server closes a socket on a frame over 256 KiB, and sealed and in base64 a message grows by a third (see
  /// chunkJson in Live.swift): a full screen is cut to this much JSON, a state to `maxStateJson`.
  nonisolated static let maxScreenJson = 60000
  nonisolated static let maxStateJson = 150000

  private lazy var ch = TerminalChannel(
    server, desktopId,
    [
      "hello": { [weak self] m in self?.onHello(m) },
      "sync": { [weak self] m in self?.onSync(m) },
      "run": { [weak self] m in Task { await self?.onRun(m) } },
    ],
    key: channelKey, name: "terminal bridge")
  private var tick: MainTimer?
  private var ticks = 0
  private var polling = false
  private var listeners: [HubListener] = []
  private var eventsTask: Task<Void, Never>?

  /// Each listening phone (its `from`): what it shows, when it last said hello.
  private var phones: [String: (session: String?, window: String?, seen: Date)] = [:]

  private var windows: [TermWindow] = []
  private var termError: String?
  private var projects: [String]?
  private var projectsAt: Date?
  private var projectsRoots: [String] = []

  /// The installed terminals and how they stand, and where a new session opens (its label), as of `statusesAt`.
  private var statuses: [TermStatus] = []
  private var opensIn: String?
  private var statusesAt: Date?

  /// The last state sent: without the sessions' seq and time, which change with every live op, and with them.
  private var sentState: String?
  private var sentClock: String?
  private var sentAt = Date.distantPast
  private var stateSoon: MainTimer?

  /// A state that differs only in seq and time (live ops already carry those) goes out at most this often; phones
  /// use it to notice lost ops.
  static let clockEvery: TimeInterval = 4

  /// Per watched window: the version and lines the phones have.
  private var screens: [String: (v: Int, lines: [String])] = [:]
  private var fullScreen = Set<String>()

  /// Ops waiting for the next batch, per session key, in the order they came.
  private var pendingOps: [(key: String, epoch: String, ops: [LiveOp])] = []
  private var flush: MainTimer?

  /// Asks (their ids) whose screen is being followed: plan reviews, and Claude Code's approvals, which its plugin
  /// can't see answered.
  private var followed = Set<String>()
  private var stopped = false

  /// How often a followed ask's screen is read: often while it opens, then now and then to follow its cursor and
  /// notice it go.
  static let askSoon: TimeInterval = 0.5
  static let askOpening = 6
  static let askEvery: TimeInterval = 3

  /// Sessions whose screen is followed for pickers (/resume, /model …) after a slash command from the phone, and
  /// the pickers' ids so far.
  private var menus: [String: MenuWatch] = [:]
  private var menuIds = 0

  /// A picker's screen is read this often for `menuOpening` after the command or an answer, then `menuEvery`, until
  /// nothing changed for `menuIdle`.
  static let menuSoon: TimeInterval = 0.4
  static let menuOpening: TimeInterval = 3
  static let menuEvery: TimeInterval = 1.5
  static let menuIdle: TimeInterval = 2 * 60

  /// Each session's Live Activity state as last seen (LiveActivity.swift) and as last pushed; a change goes out once
  /// it has held for `activityWait`, so a quick busy flicker between turns stays home.
  private var activitySeen: [String: ActivityStatus] = [:]
  private var activitySent: [String: ActivityStatus] = [:]
  private var activitySoon: [String: MainTimer] = [:]
  static let activityWait: TimeInterval = 2

  /// Phones show this session now (said so within `gone`).
  public func watching(_ sessionKey: String) -> Bool { phones.values.contains { $0.session == sessionKey } }

  /// How far a phone's clock is off this computer's while it's too far for anything from it to be taken (more than
  /// 5 minutes), in seconds; nil otherwise.
  public var clockOff: TimeInterval? { ch.clockOff }

  public func start() async {
    stopped = false
    ch.open()
    listeners.append(hub.onOps { [weak self] s, ops in self?.onOps(s, ops) })
    listeners.append(
      hub.onChange { [weak self] in
        self?.stateChanged()
        self?.activitiesChanged()
      })
    let events = hub.events
    eventsTask = Task { [weak self] in
      for await e in events {
        guard let self else { return }
        if case .asked(let s, let ask) = e, ask.isPlan || (ask.isApproval && s.agent == .claude) {
          let key = s.key
          Task { await self.followAsk(key, ask.id) }
        }
      }
    }
    // Away from the computer, an idle sleep would end the bridge; the lid still sleeps it.
    await host.setKeepAwake(on: true)
  }

  public func stop() async {
    stopped = true
    for w in menus.values { w.wake() }
    for l in listeners { l.cancel() }
    listeners.removeAll()
    eventsTask?.cancel()
    eventsTask = nil
    tick?.cancel()
    tick = nil
    flush?.cancel()
    flush = nil
    stateSoon?.cancel()
    stateSoon = nil
    for t in activitySoon.values { t.cancel() }
    activitySoon.removeAll()
    await host.setKeepAwake(on: false)
    phones.removeAll()
    ch.close()
  }

  private func send(_ event: String, _ payload: JSONObject) {
    do {
      try ch.send(event, payload)
    } catch {
      debugLog("PocketTerm: terminal bridge: \(error)")
    }
  }

  // ------------------------------------------------------------ phones

  private func onHello(_ p: JSONObject) {
    guard let from = p["from"]?.string else { return }
    let window = p["window"]?.string
    let before = phones[from]
    phones[from] = (p["session"]?.string, window, Date())
    if before == nil { onPhone?() }
    // Every hello gets the state: it's how the phone knows the computer is there.
    sentState = nil
    if let window, before?.window != window { fullScreen.insert(window) }
    if tick == nil {
      tick = MainTimer(every: Self.tickEvery) { [weak self] in
        guard let self else { return }
        Task { await self.poll() }
      }
    }
    Task { await poll(windows: true) }
  }

  private func onSync(_ p: JSONObject) {
    guard let from = p["from"]?.string else { return }
    if let window = p["window"]?.string {
      fullScreen.insert(window)
      Task { await poll() }
      return
    }
    guard let key = p["session"]?.string, let s = hub[key] else { return }
    // Pending ops would arrive after this answer, which covers them already.
    flushNow()
    let log = s.log
    let since = p["since"]?.int ?? 0
    let reset = p["epoch"] != .string(log.epoch) || since > log.seq || since <= 0
    let items = reset ? log.items : log.since(since)
    let chunks = chunkJson(items.map { $0.toJson() })
    for (n, chunk) in chunks.enumerated() {
      send(
        "items",
        [
          "to": .string(from), "session": .string(key), "epoch": .string(log.epoch), "seq": .int(log.seq),
          "reset": .bool(reset), "items": .array(chunk.map(JSON.object)), "last": .bool(n == chunks.count - 1),
          "older": .bool(log.older),
        ])
    }
  }

  // ------------------------------------------------------------ live sessions

  private func onOps(_ s: LiveSession, _ ops: [LiveOp]) {
    if !watching(s.key) { return }
    if let i = pendingOps.firstIndex(where: { $0.key == s.key }) {
      if pendingOps[i].epoch == s.log.epoch {
        pendingOps[i].ops += ops
      } else {
        flushNow()
        pendingOps.append((s.key, s.log.epoch, ops))
      }
    } else {
      pendingOps.append((s.key, s.log.epoch, ops))
    }
    if flush == nil { flush = MainTimer(Self.batch) { [weak self] in self?.flushNow() } }
  }

  private func flushNow() {
    flush?.cancel()
    flush = nil
    let pending = pendingOps
    pendingOps.removeAll()
    for p in pending {
      for chunk in chunkJson(p.ops.map { $0.toJson() }) {
        send("live", ["session": .string(p.key), "epoch": .string(p.epoch), "ops": .array(chunk.map(JSON.object))])
      }
    }
  }

  private func stateChanged() {
    if phones.isEmpty { return }
    if stateSoon == nil {
      stateSoon = MainTimer(0.2) { [weak self] in
        self?.stateSoon = nil
        self?.sendState()
      }
    }
  }

  // ------------------------------------------------------------ Live Activities

  /// A session started or stopped working, asks or stopped asking, or went: the phones following it hear about it
  /// through the server (POST /v1/push/activity, `activityPush`), which does nothing for a session no phone follows.
  /// A session seen for the first time pushes nothing: no phone can follow it yet.
  private func activitiesChanged() {
    for s in hub.sessions {
      let status = activityStatus(busy: s.busy, ask: s.ask)
      let seen = activitySeen[s.key]
      activitySeen[s.key] = status
      if seen == nil {
        if activitySent[s.key] == nil { activitySent[s.key] = status }
      } else if seen != status {
        schedulePush(s.key)
      }
    }
    for key in activitySeen.keys where hub[key] == nil {
      if activitySeen[key]!.state == .ended { continue }
      activitySeen[key] = ActivityStatus(state: .ended)
      schedulePush(key)
    }
  }

  private func schedulePush(_ key: String) {
    activitySoon[key]?.cancel()
    activitySoon[key] = MainTimer(Self.activityWait) { [weak self] in self?.pushActivity(key) }
  }

  private func pushActivity(_ key: String) {
    activitySoon[key] = nil
    guard let status = activitySeen[key], status != activitySent[key] else { return }
    activitySent[key] = status
    if status.state == .ended {
      activitySeen[key] = nil
      activitySent[key] = nil
    }
    let body = Self.activityPush(channelKey, desktopId, key, status)
    let server = server
    Task {
      do {
        _ = try await server.push("activity", body)
      } catch {
        debugLog("PocketTerm: Live Activity push: \(error)")
      }
    }
  }

  /// What goes to POST /v1/push/activity for coding session `key` now at `status`: its routed key (for the server to
  /// find the phones following it; it never reaches the relay), state and kind in the clear for iPhones' Live
  /// Activities (Apple can't open anything sealed), and the same sealed with this computer's `channelKey` as `enc`,
  /// the only thing Android phones get, with this computer's push tag to find the key by.
  nonisolated static func activityPush(
    _ channelKey: ChannelKey, _ desktopId: String, _ key: String, _ status: ActivityStatus
  ) -> JSONObject {
    let session = routedKey(desktopId, key)
    let state = activityJson(status)
    var sealed: JSONObject = ["session": .string(session)]
    sealed.merge(state) { _, new in new }
    sealed["since"] = .int(millisecondsSinceEpoch(Date()) / 1000)
    var out: JSONObject = ["session": .string(session)]
    out.merge(state) { _, new in new }
    out["tag"] = .string(pushTag(channelKey))
    out["enc"] = .string(sealActivity(channelKey, desktopId, sealed))
    return out
  }

  private func sendState() {
    var full: JSONObject = [
      "windows": .array(windows.map { .object($0.toJson()) }),
      "sessions": .array(hub.sessions.map { .object($0.summary.toJson()) }),
      "projects": projects.map(JSON.strings) ?? .null,
      "roots": .strings(roots()),
      "home": .string(terms.home),
      "agent": .string(agent().name),
      "placement": .string(placement().name),
      "terminals": .array(phoneTerminals(statuses).map { .object($0.toJson()) }),
    ]
    if let opensIn { full["opensIn"] = .string(opensIn) }
    if let termError { full["error"] = .string(termError) }
    if let a = agentsNow { full["agents"] = .object(AgentIntegration.toJsonAll(a)) }
    if let p = ompProfiles?(), !p.isEmpty { full["profiles"] = .strings(p) }
    let state = Self.fitState(full, watched: Set(phones.values.compactMap(\.session)))
    let sessions = state["sessions"]?.array?.compactMap(\.object) ?? []
    var unclocked = state
    unclocked["sessions"] = .array(
      sessions.map { s in
        var s = s
        s["seq"] = .null
        s["at"] = .null
        return .object(s)
      })
    let key = unclocked.encoded()
    let clock = JSON.strings(sessions.map { "(\(dartInterpolated($0["seq"])), \(dartInterpolated($0["at"])))" })
      .encoded()
    let now = Date()
    if key == sentState && (clock == sentClock || now.timeIntervalSince(sentAt) < Self.clockEvery) { return }
    sentState = key
    sentClock = clock
    sentAt = now
    send("state", state)
  }

  /// `state` cut to at most `maxBytes` of JSON, least needed first: the slash commands of the sessions no phone shows
  /// (`watched`: the ones phones show), the queued prompts of those sessions to their start, the repositories in the
  /// Project folders that don't fit, every command's description, every session's commands, every queued prompt to
  /// its start, then windows from the end of the list. Many coding sessions (each with its agent's whole list of
  /// commands) or a Project folder with thousands of repositories would otherwise make a state the server can't take.
  nonisolated static func fitState(_ state: JSONObject, watched: Set<String>, maxBytes: Int = maxStateJson)
    -> JSONObject
  {
    func size(_ json: JSON) -> Int { json.encoded().utf8.count }
    let text = state.encoded()
    // UTF-8 takes at most three bytes per UTF-16 unit: most states are measured without encoding them.
    if text.utf16.count * 3 <= maxBytes { return state }
    var total = text.utf8.count
    if total <= maxBytes { return state }
    var out = state
    func cmds(_ keep: (JSONObject, [JSON]) -> JSON?) {
      out["sessions"] = .array(
        (out["sessions"]?.array ?? []).map { sj in
          guard let s = sj.object, case .array(let c)? = s["cmds"] else { return sj }
          var kept = s
          kept["cmds"] = keep(s, c)
          return .object(kept)
        })
      total = size(.object(out))
    }

    cmds { s, c in s["key"]?.string.map(watched.contains) == true ? .array(c) : nil }
    // A queued prompt cut to its start: the phone shows it, but doesn't offer to edit it.
    func queues(_ which: (JSONObject) -> Bool) {
      if total <= maxBytes { return }
      out["sessions"] = .array(
        (out["sessions"]?.array ?? []).map { sj in
          guard var s = sj.object, case .array(let queue)? = s["queue"], which(s) else { return sj }
          s["queue"] = .array(
            queue.map { qj in
              guard var q = qj.object, let t = q["t"]?.string, dartLength(t) > queuedStart else { return qj }
              q["t"] = .string("\(dartSubstring(t, 0, queuedStart))…")
              q["c"] = true
              return .object(q)
            })
          return .object(s)
        })
      total = size(.object(out))
    }

    queues { s in s["key"]?.string.map(watched.contains) != true }
    if case .array(let projects)? = out["projects"], total > maxBytes {
      var room = maxBytes - (total - size(.array(projects)))
      out["projects"] = .array(
        projects.filter { p in
          room -= size(p) + 1
          return room >= 0
        })
      total = size(.object(out))
    }
    if total > maxBytes {
      cmds { _, c in
        .array(
          c.compactMap { cmd in
            guard case .array(let l) = cmd, let first = l.first else { return nil }
            return .array([first])
          })
      }
    }
    if total > maxBytes { cmds { _, _ in nil } }
    queues { _ in true }
    if total > maxBytes {
      var windows = out["windows"]?.array ?? []
      while total > maxBytes, let last = windows.popLast() { total -= size(last) + 1 }
      out["windows"] = .array(windows)
    }
    return out
  }

  /// How much of a queued prompt's text a state too big for it keeps.
  nonisolated static let queuedStart = 200

  private var askingAgents = false

  /// Where the agents stand, in the background (it may run `claude`); a change goes out with the next state.
  private func askAgents() {
    guard let ask = agents, !askingAgents else { return }
    askingAgents = true
    Task {
      defer { askingAgents = false }
      do {
        let a = try await ask()
        if stopped || a == agentsNow { return }
        agentsNow = a
        stateChanged()
      } catch {
        debugLog("PocketTerm: coding agents: \(error)")
      }
    }
  }

  // ------------------------------------------------------------ terminals

  /// How often Settings-like statuses are read again while phones listen.
  static let statusEvery: TimeInterval = 30

  private func poll(windows refresh: Bool = false) async {
    if polling { return }
    polling = true
    defer { polling = false }
    let now = Date()
    phones = phones.filter { now.timeIntervalSince($0.value.seen) <= Self.gone }
    if phones.isEmpty {
      tick?.cancel()
      tick = nil
      screens.removeAll()
      return
    }
    var list = refresh
    if !list {
      list = ticks % 3 == 0
      ticks += 1
    }
    if list {
      windows = await terms.windows()
      relink()
      if refresh || statusesAt.map({ now.timeIntervalSince($0) > Self.statusEvery }) ?? true {
        statusesAt = now
        statuses = await terms.statuses()
        opensIn = terms.describe(await terms.opensIn(app()))
      }
      termError = terminalsError(statuses, nothingShown: windows.isEmpty && hub.sessions.isEmpty)
      askAgents()
      let roots = roots()
      if projectsAt.map({ now.timeIntervalSince($0) > 5 * 60 }) ?? true || roots != projectsRoots {
        projectsAt = now
        projectsRoots = roots
        let terms = terms
        Task {
          let p = await terms.projects(roots)
          // A scan of folders since changed (a slow one, of ~ say) is stale.
          if roots != projectsRoots { return }
          projects = p
          stateChanged()
        }
      }
    }
    sendState()
    var watched: [String] = []
    for v in phones.values { if let w = v.window, !watched.contains(w) { watched.append(w) } }
    screens = screens.filter { watched.contains($0.key) }
    for w in watched {
      guard let shown = windows.first(where: { $0.key == w }), shown.can(.read) else { continue }
      do {
        try await sendScreen(w)
      } catch {
        debugLog("PocketTerm: terminal screen \(w): \(error)")
      }
    }
  }

  /// What the windows (and the sessions' windows) were at the last relink.
  private var relinkedFor: String?

  /// Sessions without a window look for one again once the windows change (a Ghostty window's title follows its
  /// session's).
  private func relink() {
    if hub.sessions.allSatisfy({ $0.window != nil }) { return }
    let now = (windows.map { "\($0.key)\t\($0.title)\t\($0.cwd)" } + hub.sessions.compactMap(\.window))
      .joined(separator: "\n")
    if now == relinkedFor { return }
    relinkedFor = now
    let hub = hub
    Task { await hub.relink() }
  }

  private func sendScreen(_ window: String) async throws {
    let lines = Self.fitLines(try await terms.lines(window, history: true), Self.maxScreenJson)
    let before = screens[window]
    let full = before == nil ? true : fullScreen.remove(window) != nil
    if !full, let before, before.lines.count == lines.count, zip(before.lines, lines).allSatisfy(sameText) { return }
    let v = (before?.v ?? 0) + 1
    screens[window] = (v, lines)
    if !full, let before, let diff = ScreenDiff.between(before.lines, lines) {
      send("screen", ["window": .string(window), "v": .int(v), "diff": .object(diff.toJson())])
      return
    }
    var payload: JSONObject = ["window": .string(window), "v": .int(v), "lines": .strings(lines)]
    if before == nil, let colors = try await terms.colors(window) { payload["colors"] = .object(colors) }
    send("screen", payload)
  }

  /// The newest of `lines` that take at most `maxBytes` as JSON (one line at least, itself cut to fit): what a screen
  /// sends whole. Its diffs are made between these too, so they're never larger.
  nonisolated static func fitLines(_ lines: [String], _ maxBytes: Int) -> [String] {
    var size = 2
    var from = lines.count
    while from > 0 {
      let next = size + jsonBytes(lines[from - 1]) + 3
      if next > maxBytes { break }
      size = next
      from -= 1
    }
    if from == lines.count, let last = lines.last {
      // One line longer than all of it: its start, which is what a terminal shows of it.
      let units = Array(last.utf16)
      var end = units.count
      while end > 0 && jsonBytes(utf16: Array(units[0..<end])) + 5 > maxBytes { end = end * 3 / 4 }
      return [dartSubstring(last, 0, end)]
    }
    return from == 0 ? lines : Array(lines[from...])
  }

  // ------------------------------------------------------------ requests

  /// The phones' requests of the last minutes, by id.
  private let runs = RunLog()

  private func onRun(_ p: JSONObject) async {
    guard let id = p["id"]?.string, runs.start(id, { [weak self] ran in self?.send("ran", ran) }) else { return }
    var error: String?
    var window: String?
    var place: String?
    var busy: Bool?
    var queued: String?
    let op = p["op"]?.string
    do {
      switch op {
      case "send":
        try await terms.send(try castRequiredString(p["window"]), try castString(p["text"]) ?? "", enter: p["enter"] != false)
      case "key":
        let pressed = try castRequiredString(p["window"])
        try await terms.press(pressed, try castRequiredString(p["key"]))
        // Esc on a picker, say: see it go soon.
        for s in hub.sessions where s.window == pressed { menus[s.key]?.arm() }
      case "close":
        try await terms.close(try castRequiredString(p["window"]))
      case "probe":
        busy = try await screenChanges(terms, try castRequiredString(p["window"]))
      case "switch":
        let at = try castRequiredString(p["window"])
        guard let agent = p["agent"]?.string.flatMap(Agent.init(rawValue:)) else {
          throw TerminalException("Unknown coding agent.")
        }
        // As the windows are now: it may have closed since the phone's list.
        guard let shown = await terms.windows().first(where: { $0.key == at }) else {
          throw TerminalException("That window has closed.")
        }
        // Typed into a shell: only a profile this computer has (else the default's conversation).
        let known = ompProfiles?() ?? []
        let profile = known.contains(shown.profile) ? shown.profile : ""
        try await switchToConversation(terms, at, agent, tty: shown.tty, profile: profile)
      case "launch":
        // An older phone says `omp` for "start the coding agent".
        let start = p["agent"] == true || p["omp"] == true
        let host = await terms.opensIn(app())
        let agent = start ? agent() : nil
        let cwd = try castRequiredString(p["cwd"])
        let opened = try await terms.launch(
          cwd, host: host, agent: agent, placement: placement(),
          profile: try agent.map { try launchProfile(p["profile"], $0, ompProfiles?() ?? []) } ?? "")
        window = opened.window
        place = opened.where
      case "create":
        let agent = p["agent"] == true ? agent() : nil
        let root = try castRequiredString(p["root"])
        let name = try castString(p["name"]) ?? ""
        let roots = roots()
        let host = await terms.opensIn(app())
        let opened = try await terms.launchNewProject(
          root, name, roots: roots, host: host, agent: agent,
          profile: try agent.map { try launchProfile(p["profile"], $0, ompProfiles?() ?? []) } ?? "")
        window = opened.window
        place = opened.where
      case "prompt":
        queued = try await prompt(p)
      case "queue":
        try await queue(p)
      case "abort":
        try await hub.abort(try castRequiredString(p["session"]))
      case "answer":
        try await answer(p)
      case "older":
        try await hub.older(try castRequiredString(p["session"]))
      case "orchestrator":
        window = try await orchestrator()
      default:
        error = "Unknown request."
      }
    } catch let e as TerminalException {
      error = e.message
    } catch let e as LiveException {
      error = e.message
    } catch let e as LiveArgumentError {
      // Dart's ArgumentError.
      error = "The computer could not do that: Invalid argument(s): \(e.message)"
    } catch let e {
      error = "The computer could not do that: \(e)"
    }
    var ran: JSONObject = ["id": .string(id)]
    if let error { ran["error"] = .string(error) }
    if let window { ran["window"] = .string(window) }
    if let place { ran["where"] = .string(place) }
    if let busy { ran["busy"] = .bool(busy) }
    if let queued { ran["queued"] = .string(queued) }
    runs.done(id, ran)
    send("ran", ran)
    let refresh = op.map { ["launch", "create", "close", "switch", "orchestrator"].contains($0) } ?? false
    Task { await poll(windows: refresh) }
  }

  /// The phone's prompt, with its images and files fetched from Storage (and deleted): the id it waits under in the
  /// session's queue, if it waits there.
  private func prompt(_ p: JSONObject) async throws -> String? {
    // The agent's own commands (/resume, /model …) are read by its editor, not the model: type them into its window
    // like the person would, and follow the pickers they open.
    let text = dartTrim(try castString(p["text"]) ?? "")
    let key = try castRequiredString(p["session"])
    let window = hub[key]?.window
    let paths = try (castList(p["images"]) ?? []).map { try castRequiredString($0) }
    var files: [(path: String, name: String, mime: String)] = []
    for f in try castList(p["files"]) ?? [] {
      guard let path = f["path"]?.string, let name = f["name"]?.string else { throw LiveException("Bad file.") }
      files.append((path, name, f["mime"]?.string ?? ""))
    }
    let blobs = paths + files.map(\.path)
    if text.dartStartsWith("/") && blobs.isEmpty {
      // Sent as a prompt instead, the agent would take it for chat.
      if let why = cantCommand(terms, window) { throw LiveException(why) }
      try await terms.send(window!, text, enter: true)
      Task { await followMenus(key) }
      return nil
    }
    for path in blobs where !Servers.isBlobPath(path) { throw LiveException("Bad image or file path.") }
    let server = server
    // The server drops one once it's downloaded; one that didn't come down goes too.
    defer {
      for path in blobs {
        Task {
          do {
            try await server.deleteBlob(path)
          } catch {
            debugLog("PocketTerm: blob cleanup: \(error)")
          }
        }
      }
    }
    var images: [PromptImage] = []
    for path in paths { images.append(try await Self.image(try Self.openBlob(channelKey, path, try await server.getBlob(path)))) }
    var opened: [PromptFile] = []
    for f in files {
      opened.append(
        PromptFile(name: f.name, mime: f.mime, bytes: try Self.openBlob(channelKey, f.path, try await server.getBlob(f.path))))
    }
    return try await hub.prompt(
      key, try castString(p["text"]) ?? "", images: images, files: opened, followUp: p["deliver"] == "followUp",
      id: try castString(p["id"]))
  }

  /// The phone's change to a session's queue (LiveHub).
  private func queue(_ p: JSONObject) async throws {
    let key = try castRequiredString(p["session"])
    let item = try castString(p["item"]) ?? ""
    switch p["do"]?.string {
    case "edit": try hub.editQueued(key, item, try castString(p["text"]) ?? "")
    case "remove": try hub.removeQueued(key, item)
    case "move": try hub.moveQueued(key, item, to: try castTruncated(p["to"]) ?? 0)
    case "send": try await hub.sendQueuedNow(key, item)
    case "pause": try hub.pauseQueue(key, paused: true)
    case "resume": try hub.pauseQueue(key, paused: false)
    default: throw LiveException("Unknown change to the queue.")
    }
  }

  /// A phone's image or file as stored at `path`, opened with `key` (the phone sealed it for that path:
  /// TerminalRemote).
  nonisolated static func openBlob(_ key: ChannelKey, _ path: String, _ sealed: Data) throws -> Data {
    guard let plain = openBytes(key, sealed, imageAad(path)) else {
      throw LiveException("The image or file didn't open: it wasn't sealed with this computer's key.")
    }
    return plain
  }

  /// PNG and JPEG go as they are; on a Mac anything else (HEIC from Photos) becomes PNG first, which every model
  /// reads. Elsewhere (no `sips`) only PNG and JPEG do; the phone sends JPEG anyway.
  nonisolated static func image(_ bytes: Data, macos: Bool = true) async throws -> PromptImage {
    func starts(_ magic: [UInt8]) -> Bool { bytes.count > magic.count && bytes.prefix(magic.count).elementsEqual(magic) }
    if starts([0x89, 0x50, 0x4E, 0x47]) { return PromptImage(bytes: bytes, mimeType: "image/png") }
    if starts([0xFF, 0xD8, 0xFF]) { return PromptImage(bytes: bytes, mimeType: "image/jpeg") }
    if !macos { throw LiveException("This computer reads PNG and JPEG images only.") }
    var template = Array(Paths.join(systemTempDir(), "pocketterm-imageXXXXXX").utf8CString)
    guard let made = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
    let dir = String(cString: made)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let input = "\(dir)/in"
    try bytes.write(to: URL(fileURLWithPath: input))
    let png = "\(dir)/out.png"
    let conv = try await runProcess("/usr/bin/sips", ["-s", "format", "png", input, "--out", png])
    if conv?.code != 0 { throw LiveException("The computer couldn't read that image.") }
    return PromptImage(bytes: try Data(contentsOf: URL(fileURLWithPath: png)), mimeType: "image/png")
  }

  /// Follows on its screen an ask whose end the agent's extension can't see: a plan review (dismissed with Esc at
  /// the computer), or Claude Code's approval (its plugin hears only once the tool has run). A plan's options are
  /// published once it has rendered, and again when its cursor moves. An ask gone from the screen twice running goes
  /// from the hub too.
  private func followAsk(_ key: String, _ id: String) async {
    guard followed.insert(id).inserted else { return }
    defer { followed.remove(id) }
    var misses = 0
    var n = 0
    while !stopped {
      let opening = n < Self.askOpening
      n += 1
      await pause(opening ? Self.askSoon : Self.askEvery)
      guard let s = hub[key], let ask = s.ask, ask.id == id, let window = s.window, terms.can(window, .read) else {
        return
      }
      let screen: String
      do {
        screen = try await terms.plainScreen(window)
      } catch {
        debugLog("PocketTerm: ask on screen \(window): \(error)")
        if opening { continue }
        return
      }
      if let review = ask.isPlan ? parsePlanReview(screen, agent: s.agent) : nil {
        misses = 0
        if review.options != ask.options || review.current != ask.selected {
          hub.updateAsk(key, id, .plan(id, title: ask.title, options: review.options, selected: review.current))
        }
      } else if askOnScreen(ask, screen, agent: s.agent) {
        misses = 0
      } else if !opening {
        misses += 1
        if misses >= 2 {
          hub.updateAsk(key, id, nil)
          return
        }
      }
    }
  }

  private static func answers(_ p: JSONObject) throws -> [LiveAnswer] {
    try (castList(p["answers"]) ?? []).map { a in
      guard let o = try castMap(a), let answer = LiveAnswer(json: o) else {
        throw HubCastError(value: a, type: "Map<dynamic, dynamic>")
      }
      return answer
    }
  }

  /// Picks the plan review option `p` names, once the screen still lists it there. Claude Code's rows go by their
  /// number. omp's cursor moves from where it is now (someone may have moved it at the computer) down or up to it,
  /// and Enter goes once the screen shows the cursor there: ↓/↑ skip an option omp has disabled, which plain text
  /// doesn't show, and a cursor that won't land on the option means omp won't take it.
  private func answerPlan(_ window: String, _ ask: LiveAsk, _ agent: Agent, _ p: JSONObject) async throws {
    let answers = try Self.answers(p)
    let pick = answers.count == 1 && answers[0].picks.count == 1 ? answers[0].picks[0] : -1
    if pick < 0 { throw LiveException("Pick one option.") }
    for _ in 0..<4 {
      guard let review = parsePlanReview(try await terms.plainScreen(window), agent: agent) else {
        throw LiveException("The plan review isn't ready on the computer's screen. Open the screen to answer it there.")
      }
      if pick >= review.options.count || (pick < ask.options.count && review.options[pick] != ask.options[pick]) {
        throw LiveException("The plan review on the computer has changed. Open the screen to answer it there.")
      }
      if agent == .claude {
        try await terms.pressKeys(window, [claudeRowKey(pick)])
        return
      }
      if review.current == pick {
        try await terms.pressKeys(window, ["enter"])
        return
      }
      try await terms.pressKeys(window, try menuKeys(review.current, pick, enter: false))
      await pause(0.2)
    }
    throw LiveException("omp won't move to that option. Open the screen to answer it there.")
  }

  /// Follows session `key`'s screen for the pickers a slash command opens (/resume, /model, /tree …) and publishes
  /// each as a menu ask: its rows, cursor and search as they change, a new ask for each new picker (one can open
  /// another), none once it has gone two reads running. Read often for a while after the command or an answer, then
  /// less; it stops when no picker is up after that while, or nothing changed for `menuIdle`. The agent's own asks
  /// come first: a picker never replaces one. Again for a session already followed just reads sooner.
  private func followMenus(_ key: String) async {
    if let known = menus[key] {
      known.arm()
      return
    }
    let w = MenuWatch()
    menus[key] = w
    var published: String?
    var misses = 0
    while !stopped {
      var now = Date()
      if now.timeIntervalSince(w.changed) > Self.menuIdle { break }
      let opening = now.timeIntervalSince(w.armed) < Self.menuOpening
      if published == nil && !opening { break }
      await w.sleep(opening ? Self.menuSoon : Self.menuEvery)
      guard let s = hub[key], let window = s.window, !stopped, terms.can(window, .read) else { break }
      let current = s.ask
      // The agent asks something itself, or the picker's ask went (a new session's hello).
      if let current, current.id != published { break }
      if current == nil && published != nil { published = nil }
      let screen: String
      do {
        screen = try await terms.plainScreen(window)
      } catch {
        debugLog("PocketTerm: picker \(window): \(error)")
        break
      }
      now = Date()
      guard let menu = parseMenu(screen) else {
        if published != nil {
          misses += 1
          if misses >= 2 {
            hub.updateAsk(key, published, nil)
            published = nil
            w.query = ""
          }
        }
        continue
      }
      misses = 0
      let same = current != nil && sameText(current!.title, menu.title)
      let id: String
      if same {
        id = current!.id
      } else {
        menuIds += 1
        id = "menu-\(menuIds)"
      }
      let ask = LiveAsk.menu(id, title: menu.title, items: menu.items, selected: menu.current, filter: menu.filter)
      if same && ask.toJson().encoded() == current!.toJson().encoded() { continue }
      if !hub.updateAsk(key, published, ask) { break }
      if !same { w.query = "" }
      published = ask.id
      w.changed = now
    }
    if menus[key] === w { menus[key] = nil }
    if let published { hub.updateAsk(key, published, nil) }
  }

  /// Answers a picker: a pick moves its cursor from where it is now to the row (once that row still reads the same)
  /// and presses Enter; typed text becomes its search, by typing what's new and erasing only what was typed from the
  /// phone before (Backspace on an empty search can mean something else: /resume deletes the session). The picker is
  /// then read again soon, as is whatever it opens next.
  private func answerMenu(_ key: String, _ window: String, _ ask: LiveAsk, _ p: JSONObject) async throws {
    let answers = try Self.answers(p)
    let answer = answers.count == 1 ? answers[0] : nil
    let watch = menus[key]
    let menu = parseMenu(try await terms.plainScreen(window))
    guard let w = watch, let menu, sameText(menu.title, ask.title) else {
      throw LiveException("The menu isn't on the computer's screen anymore. Open the screen to see what is.")
    }
    if let answer, let query = answer.custom, answer.picks.isEmpty {
      if !menu.filter { throw LiveException("This menu can't be searched.") }
      let typed = Array(query.utf16)
      let before = Array(w.query.utf16)
      var same = 0
      while same < typed.count && same < before.count && typed[same] == before[same] { same += 1 }
      try await terms.pressKeys(window, Array(repeating: "backspace", count: before.count - same))
      if same < typed.count { try await terms.type(window, dartSubstring(query, same)) }
      w.query = query
      w.arm()
      return
    }
    let pick = answer.map { $0.picks.count == 1 ? $0.picks[0] : -1 } ?? -1
    if pick < 0 || pick >= ask.items.count { throw LiveException("Pick one item.") }
    var shown = menu
    for _ in 0..<4 {
      if pick >= shown.items.count || !sameText(shown.items[pick].label, ask.items[pick].label) {
        throw LiveException("The menu on the computer has changed. Pick again.")
      }
      if shown.current == pick {
        try await terms.pressKeys(window, ["enter"])
        w.query = ""
        w.arm()
        return
      }
      try await terms.pressKeys(window, try menuKeys(shown.current, pick, enter: false))
      await pause(0.15)
      guard let again = parseMenu(try await terms.plainScreen(window)), sameText(again.title, ask.title) else {
        throw LiveException("The menu isn't on the computer's screen anymore. Open the screen to see what is.")
      }
      shown = again
    }
    throw LiveException("The agent won't move to that item. Open the screen to pick it there.")
  }

  /// An orchestrator launch still going: another `orchestrator` op meanwhile (Send again, a second phone) gets it.
  private var orchestratorStart: Task<String, Error>?

  /// The phone's `orchestrator` op: the orchestrator's window key, starting it (omp in `LiveHub.orchestratorDir`,
  /// Orchestrator.swift) unless one runs or is starting. Always omp, whatever new sessions start: only its extension
  /// has the orchestrator's tools.
  private func orchestrator() async throws -> String {
    if let running = hub.sessions.first(where: \.orchestrator) { return running.key }
    if let starting = orchestratorStart { return try await starting.value }
    let start = Task { try await startOrchestrator() }
    orchestratorStart = start
    defer { orchestratorStart = nil }
    return try await start.value
  }

  private func startOrchestrator() async throws -> String {
    guard let dir = hub.orchestratorDir else { throw LiveException("PocketTerm's local API isn't running.") }
    // omp already in its folder that hasn't said hello yet (slow to start): that one, not a second.
    if let early = await terms.windows().first(where: { $0.agent == .omp && isOrchestratorDir($0.cwd, dir) }) {
      return early.key
    }
    switch agentsNow?[.omp] {
    case .missing?:
      throw LiveException("Install PocketTerm in omp first: Settings → Coding agents on this computer.")
    case .outdated?:
      throw LiveException("Update PocketTerm in omp first: Settings → Coding agents on this computer.")
    case nil, .installed?, .off?:
      break
    }
    try prepareOrchestratorDir(dir)
    let host = await terms.opensIn(app())
    let opened = try await terms.launch(
      dir, host: host, agent: .omp, placement: placement(), flags: "--append-system-prompt \(orchestratorPromptFile)")
    return opened.window
  }

  /// Answers the agent's question, approval, plan review or a picker with keystrokes in its terminal window, once
  /// its screen shows that it is up: only where the terminal can both show its screen and press keys.
  private func answer(_ p: JSONObject) async throws {
    let s = hub[try castRequiredString(p["session"])]
    guard let s, let ask = s.ask, p["ask"] == .string(ask.id) else {
      throw LiveException("That is no longer being asked.")
    }
    guard let window = s.window else {
      throw LiveException(
        "PocketTerm can't tell which terminal window this session runs in: answer it on the computer.")
    }
    if let why = cantAnswer(terms, window) { throw LiveException(why) }
    if ask.isPlan { return try await answerPlan(window, ask, s.agent, p) }
    if ask.isMenu { return try await answerMenu(s.key, window, ask, p) }
    let steps = try answerKeys(ask, answers: try Self.answers(p), approve: p["approve"] == true, agent: s.agent)
    if !askOnScreen(ask, try await terms.plainScreen(window), agent: s.agent) {
      throw LiveException("The question isn't on the computer's screen. Open the screen to answer it there.")
    }
    for step in steps {
      switch step {
      case .keys(let keys): try await terms.pressKeys(window, keys)
      case .typed(let text): try await terms.type(window, text)
      case .settle: await pause(0.45)
      }
    }
    try await answered(s, window, ask)
  }

  /// omp's ask dialog on its last tab, the answers listed above Submit.
  private static let submitTab = TermRegex("Review answers[\\s\\S]*❯[\(jsSpaceChars)]*Submit")

  /// Waits for the agent to take the answer: its extension drops the ask (omp's when the tool ends, Claude Code's once
  /// the tool has run), or the dialog leaves the screen, which comes first for an approved long command; the ask goes
  /// then. omp's dialog still waiting on its Submit tab gets one more Enter: keys that came while it redrew were
  /// dropped.
  private func answered(_ s: LiveSession, _ window: String, _ ask: LiveAsk) async throws {
    let key = s.key
    func pending() -> Bool { hub[key]?.ask?.id == ask.id }
    var nudged = false
    var gone = 0
    for i in 0..<16 {
      if !pending() { break }
      await pause(0.25)
      if i < 2 || !pending() { continue }
      let screen = try await terms.plainScreen(window)
      if !askOnScreen(ask, screen, agent: s.agent) {
        gone += 1
        if gone < 2 { continue }
        hub.updateAsk(key, ask.id, nil)
        return
      }
      gone = 0
      if i >= 7 && !nudged && s.agent == .omp && Self.submitTab.hasMatch(screen) {
        nudged = true
        try await terms.pressKeys(window, ["enter"])
      }
    }
    if pending() {
      throw LiveException(
        "\(s.agent.label) hasn't taken the answer yet. Open the screen to check what it's waiting for.")
    }
  }
}
#endif
