import Combine
import CryptoKit
import Foundation

// The phone side of the terminal protocol (Live.swift): the computer's coding sessions and terminal
// windows, what the phone watches, and a disk cache so the Terminal tab shows the last known state before
// the computer answers.

/// How the phone stands with one computer.
public enum TerminalLink: String, Sendable {
  /// Joining the topic.
  case connecting

  /// The server can't be reached (offline, Tailscale off, the server down): trying again.
  case unreachable

  /// Joined; no answer from the computer yet.
  case waiting

  /// The computer answers.
  case online

  /// The computer stopped answering, or never did.
  case offline
}

/// A terminal window's text as the phone has it: version [v] of its [lines] (ANSI), and how many lines
/// have scrolled off the top since the phone first saw it ([base]), so a view can keep its place while it
/// scrolls.
public struct TermScreen: Sendable, Hashable {
  public init(_ v: Int, _ lines: [String], _ base: Int) {
    self.v = v
    self.lines = lines
    self.base = base
  }
  public let v: Int
  public let lines: [String]
  public let base: Int
}

/// What goes out on the topic; tests pass their own.
public typealias TerminalSend = @MainActor (_ event: String, _ payload: JSONObject) -> Void

/// Where images and files go on their way to the computer (the server's blobs, sealed); tests pass their
/// own.
public typealias ImageUpload = @Sendable (_ path: String, _ sealed: Data) async throws -> Void

/// A file a prompt takes along, as it is: its name and type go inside the sealed request, its bytes sealed
/// in a blob.
public struct PromptFile: Sendable, Hashable {
  public init(name: String, mime: String, bytes: Data) {
    self.name = name
    self.mime = mime
    self.bytes = bytes
  }
  public let name: String
  public let mime: String
  public let bytes: Data
}

/// No answer from the computer in time: it may have done it all the same.
final class NoAnswer: TerminalException, @unchecked Sendable {
  init() { super.init("The computer did not answer.") }
}

/// The phone side for one computer ([desktopId]): its coding sessions (structured, per [LiveView]) and
/// terminal windows (as screens). The channel and the hellos run between [attach] and [detach]: while the
/// app is in front. Everything goes sealed with that computer's [key] (E2E.swift). Its disk cache is
/// `terminal/<desktopId>` in the given support directory. `send` and `upload`, when handed in (tests and
/// the phone's demo, which answer locally), replace the channel and the image upload.
@MainActor
public final class TerminalRemote: ObservableObject {
  public init(
    _ server: Server, supportDir: URL, desktopId: String, key: ChannelKey, send: TerminalSend? = nil,
    upload: ImageUpload? = nil, from: String? = nil
  ) {
    self.server = server
    cacheDir = supportDir.appendingPathComponent("terminal").appendingPathComponent(desktopId)
    transmit = send
    uploadImage = upload
    self.desktopId = desktopId
    self.key = key
    self.from = from ?? UUID().uuidString.lowercased()
    load()
  }

  private let server: Server
  private let cacheDir: URL
  private let transmit: TerminalSend?
  private let uploadImage: ImageUpload?

  /// The computer this talks to (Desktops.swift).
  public let desktopId: String

  /// That computer's channel key, from its QR code.
  public let key: ChannelKey

  /// What the phone calls that computer (its name in the list), for "asking MacBook Pro…"; nil while not
  /// known.
  public var desktopName: String? {
    didSet { if desktopName != oldValue { notifyListeners() } }
  }

  /// When that computer last told the server it's there (the computers list's seen_at, every minute while
  /// PocketTerm runs there with Terminal from phone on); nil while not known. Not answering and not seen
  /// for a while, it's asleep or off rather than just quiet.
  public var desktopSeenAt: Date? {
    didSet { if desktopSeenAt != oldValue { notifyListeners() } }
  }

  /// This phone, to the computer.
  public let from: String

  static let helloEvery: TimeInterval = 4
  static let silent: TimeInterval = 10

  /// A sync unanswered this long is taken as lost.
  static let syncWait: TimeInterval = 8

  /// A watched session behind the state's seq this long, without live ops catching it up, syncs.
  static let behindWait: TimeInterval = 3
  static let writeEvery: TimeInterval = 2
  static let keepFor: TimeInterval = 14 * 24 * 3600

  private lazy var ch: TerminalChannel = {
    var handlers: [String: TopicHandler] = [:]
    for event in ["state", "items", "live", "screen", "ran"] {
      handlers[event] = { [weak self] p in self?.receive(event, p) }
    }
    return TerminalChannel(
      server, desktopId, handlers, key: key, name: "terminal remote",
      onJoined: { [weak self] joined in
        // Ops may have gone by while away.
        if joined { self?.watched() }
        self?.notifyListeners()
      },
      onUnreachable: { [weak self] in self?.notifyListeners() })
  }()
  private var timer: MainTimer?

  /// Debug timing ([timing]): a state came since [attach]; sessions caught up since then.
  private var stateSinceAttach = false
  private var caughtUp: Set<String> = []

  /// The server this goes through, as [TerminalLink.unreachable] tells it.
  public var backend: Backend { server.backend }

  private var openedAt = Date()
  private var heard: Date?
  private var users = 0

  public private(set) var windows: [TermWindow] = []
  public private(set) var sessions: [LiveSummary] = []

  /// The computer's orchestrator ([LiveSummary.orchestrator]): the latest one, when several report; nil when
  /// none.
  public var orchestrator: LiveSummary? {
    var found: LiveSummary?
    for s in sessions where s.orchestrator {
      let at = s.at.map(millisecondsSinceEpoch) ?? 0
      if found == nil || at > (found!.at.map(millisecondsSinceEpoch) ?? 0) { found = s }
    }
    return found
  }

  public private(set) var projects: [String] = []

  /// The computer's Project folders, where a new project can be made; nil from a computer that predates
  /// them (and can't make one).
  public private(set) var roots: [String]?

  /// The computer's home folder, shown as ~.
  public private(set) var home = ""

  /// What a new session starts on the computer (its setting).
  public private(set) var agent = Agent.omp

  /// Where PocketTerm stands in each coding agent found on the computer; empty from a computer that doesn't
  /// say.
  public private(set) var agents: [Agent: AgentIntegration] = [:]

  /// The computer's omp profiles besides the default, sorted; empty from a computer that has none or
  /// doesn't say.
  public private(set) var profiles: [String] = []

  /// Where a session the phone starts opens ("kitty", "Ghostty (in tmux)"); nil from a computer that doesn't
  /// say.
  public private(set) var opensIn: String?

  /// Whether that is a tab in the project's window or a window of its own; nil from a computer that doesn't
  /// say.
  public private(set) var placement: Placement?

  /// The computer's terminals (installed ones, and tmux) and how each stands; empty from a computer that
  /// doesn't say.
  public private(set) var terminals: [TermStatus] = []

  /// What the computer can't do with its terminals, as it says it (none reachable, one not set up …).
  public private(set) var error: String?

  /// Phone: the sessions followed (Live Activities, Android notifications); set by the app (nil in tests
  /// and wherever there are none).
  public var activities: LiveActivities?

  /// When the computer last sent its state; [fromCache]: that was before this launch, read from disk.
  public private(set) var stateAt: Date?
  public private(set) var fromCache = false

  private var views: [String: LiveView] = [:]

  /// Sessions with no cache file, so [view] doesn't look again.
  private var uncached: Set<String> = []

  /// Sessions with a sync out: when it went.
  private var syncing: [String: Date] = [:]

  /// Live ops that came while a sync was out, applied after it.
  private var held: [String: [(String, [LiveOp])]] = [:]

  /// Watched sessions the state says are ahead: since when.
  private var behind: [String: Date] = [:]

  private var screens: [String: TermScreen] = [:]

  /// Each watched window's colors, as its terminal draws it.
  public private(set) var colors: [String: TermColors] = [:]

  private final class Watch {
    init(session: String? = nil, window: String? = nil) {
      self.session = session
      self.window = window
    }
    let session: String?
    let window: String?
  }
  private var watches: [Watch] = []

  /// A request waiting for the computer's `ran`.
  private final class Waiter {
    var continuation: CheckedContinuation<JSONObject, Error>?
    var timer: MainTimer?
    var late: ((JSONObject) -> Void)?
    var lateTimer: MainTimer?
  }
  private var pending: [String: Waiter] = [:]
  private var writes: [String: MainTimer] = [:]

  // ------------------------------------------------------------------ listeners

  private var listeners: [UUID: @MainActor () -> Void] = [:]

  /// Calls [listener] after every change (Dart's `addListener`); the returned closure stops it.
  public func addListener(_ listener: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let id = UUID()
    listeners[id] = listener
    return { [weak self] in self?.listeners[id] = nil }
  }

  private func notifyListeners() {
    objectWillChange.send()
    for l in Array(listeners.values) { l() }
  }

  // ------------------------------------------------------------------ state

  public var link: TerminalLink {
    // A transport handed in (tests) is always there.
    if transmit == nil && !ch.joined { return ch.unreachable ? .unreachable : .connecting }
    let now = Date()
    if let heard, now.timeIntervalSince(heard) < Self.silent { return .online }
    if heard == nil && now.timeIntervalSince(openedAt) < Self.silent { return .waiting }
    return .offline
  }

  public var online: Bool { link == .online }

  /// How far the computer's clock is off this phone's, in seconds, while it's too far for anything from it
  /// to be taken (more than 5 minutes: both should set the time automatically); nil otherwise. Then the
  /// computer reads as offline, though it's there.
  public var clockOff: TimeInterval? { transmit == nil ? ch.clockOff : nil }

  public func window(_ key: String) -> TermWindow? { windows.first { $0.key == key } }
  public func session(_ key: String) -> LiveSummary? { sessions.first { $0.key == key } }
  public func screen(_ window: String) -> TermScreen? { screens[window] }

  /// The session's transcript as far as the phone has it: in memory, else from the disk cache; nil if
  /// neither has it.
  public func view(_ key: String) -> LiveView? {
    if let v = views[key] { return v }
    if uncached.contains(key) { return nil }
    let f = sessionFile(key)
    if let data = try? Data(contentsOf: f) {
      if let j = JSON.tryParse(data)?.object, let v = LiveView(json: j) {
        views[key] = v
        return v
      }
      debugLog("PocketTerm: terminal cache: \(f.lastPathComponent) unreadable")
    }
    uncached.insert(key)
    return nil
  }

  /// The session the phone shows, if it shows one.
  public var watchedSession: String? { watches.last?.session }

  /// The window whose screen the phone shows, if it shows one.
  public var watchedWindow: String? { watches.last?.window }

  /// Pages call these on appear and the returned closure on disappear; the newest one open is what the
  /// computer hears about (one at a time), and closing it goes back to the one under it.
  public func watchSession(_ key: String) -> @MainActor () -> Void { watch(Watch(session: key)) }
  public func watchWindow(_ key: String) -> @MainActor () -> Void { watch(Watch(window: key)) }

  private func watch(_ w: Watch) -> @MainActor () -> Void {
    watches.append(w)
    watched()
    return { [weak self] in
      guard let self else { return }
      let top = self.watches.last === w
      self.watches.removeAll { $0 === w }
      if top { self.watched() }
    }
  }

  /// Tells the computer what's watched now and catches up with it.
  private func watched() {
    hello()
    if let s = watchedSession { sync(s, force: true) }
    if let w = watchedWindow { post("sync", ["from": .string(from), "window": .string(w)]) }
  }

  /// The app calls this when it comes to the front and [detach] when it leaves.
  public func attach() {
    users += 1
    if users > 1 { return }
    timing("attach")
    stateSinceAttach = false
    caughtUp.removeAll()
    openedAt = Date()
    if transmit != nil { return }
    ch.open()
    timer = MainTimer(every: Self.helloEvery) { [weak self] in
      guard let self else { return }
      self.hello()
      // A session left behind with no state to come still catches up.
      self.checkBehind(Date())
      // The link can turn offline without a message.
      self.notifyListeners()
    }
  }

  public func detach() {
    if users == 0 { return }
    users -= 1
    if users > 0 { return }
    timer?.cancel()
    timer = nil
    heard = nil
    syncing.removeAll()
    held.removeAll()
    behind.removeAll()
    if transmit == nil { ch.close() }
    flush()
  }

  /// Retry: a new connection at once (TerminalChannel.swift), and the computer asked again, given its 10
  /// seconds to answer before it reads as not answering. Only while attached.
  public func reconnect() {
    if users == 0 { return }
    openedAt = Date()
    heard = nil
    if transmit == nil {
      ch.reconnect()
    } else {
      hello()
    }
    notifyListeners()
  }

  public func hello() {
    var p: JSONObject = ["from": .string(from)]
    if let s = watchedSession { p["session"] = .string(s) }
    if let w = watchedWindow { p["window"] = .string(w) }
    post("hello", p)
  }

  private func receive(_ event: String, _ p: JSONObject) {
    handle(event, p)
  }

  /// One message from the computer; also handed in directly by tests and the phone's demo, which answer
  /// locally.
  public func handle(_ event: String, _ p: JSONObject) {
    switch event {
    case "state": onState(p)
    case "items": onItems(p)
    case "live": onLive(p)
    case "screen": onScreen(p)
    case "ran":
      guard let id = p["id"]?.string, let w = pending.removeValue(forKey: id) else { return }
      if let c = w.continuation {
        w.continuation = nil
        w.timer?.cancel()
        c.resume(returning: p)
      } else if let late = w.late {
        w.lateTimer?.cancel()
        late(p)
      }
    default: break
    }
  }

  private func send(_ event: String, _ payload: JSONObject) throws {
    if let t = transmit {
      t(event, payload)
    } else {
      try ch.send(event, payload)
    }
  }

  private func post(_ event: String, _ payload: JSONObject) {
    do {
      try send(event, payload)
    } catch {
      debugLog("PocketTerm: terminal: \(error)")
    }
  }

  /// Asks the computer for what [key]'s view misses. Unforced, it waits for a sync already out.
  private func sync(_ key: String, force: Bool = false) {
    let now = Date()
    if !force, let out = syncing[key], now.timeIntervalSince(out) < Self.syncWait { return }
    syncing[key] = now
    held[key] = nil
    let v = view(key)
    var p: JSONObject = ["from": .string(from), "session": .string(key), "since": .int(v?.seq ?? 0)]
    if let v { p["epoch"] = .string(v.epoch) }
    post("sync", p)
  }

  private func syncOut(_ key: String) -> Bool {
    guard let out = syncing[key] else { return false }
    return Date().timeIntervalSince(out) < Self.syncWait
  }

  private func applyState(_ p: JSONObject) {
    windows = (p["windows"]?.array ?? []).compactMap { $0.object.flatMap(TermWindow.fromJson) }
    sessions = (p["sessions"]?.array ?? []).compactMap { $0.object.flatMap(LiveSummary.init(json:)) }
    if let list = p["projects"]?.array { projects = list.compactMap(\.string) }
    roots = p["roots"]?.array?.compactMap(\.string)
    home = p["home"]?.string ?? home
    agent = Agent.parse(p["agent"])
    agents = AgentIntegration.parseAll(p["agents"])
    profiles = (p["profiles"]?.array ?? []).compactMap(\.string).filter(isOmpProfile)
    opensIn = p["opensIn"]?.string
    placement = p["placement"]?.string.flatMap(Placement.init(rawValue:))
    terminals = (p["terminals"]?.array ?? []).compactMap { $0.object.map(TermStatus.init(json:)) }
  }

  private func onState(_ p: JSONObject) {
    #if DEBUG
      if !stateSinceAttach {
        stateSinceAttach = true
        timing("first state")
      }
    #endif
    let now = Date()
    heard = now
    stateAt = now
    fromCache = false
    applyState(p)
    error = p["error"]?.string
    checkBehind(now)
    dirty(Self.stateKey)
    notifyListeners()
  }

  /// Syncs the watched session when the state says the computer has more than live ops brought (a new
  /// epoch, or a seq ahead for [behindWait]).
  private func checkBehind(_ now: Date) {
    guard let watched = watchedSession, let s = session(watched) else { return }
    let v = view(s.key)
    if v == nil || (!s.epoch.isEmpty && s.epoch != v!.epoch) {
      sync(s.key)
    } else if s.seq > v!.seq {
      let since = behind[s.key] ?? now
      behind[s.key] = since
      if now.timeIntervalSince(since) >= Self.behindWait {
        behind[s.key] = nil
        sync(s.key)
      }
    } else {
      behind[s.key] = nil
    }
  }

  private func onItems(_ p: JSONObject) {
    guard p["to"]?.string == from, let key = p["session"]?.string, let epoch = p["epoch"]?.string,
      let seq = p["seq"]?.int
    else { return }
    heard = Date()
    let last = p["last"]?.bool == true
    let v: LiveView
    if let existing = view(key) {
      v = existing
    } else {
      v = LiveView(epoch: epoch)
      views[key] = v
    }
    v.catchUp(
      epoch: epoch, seq: seq, reset: p["reset"]?.bool == true,
      items: (p["items"]?.array ?? []).compactMap { $0.object.flatMap(LiveItem.init(json:)) }, last: last,
      older: p["older"]?.bool)
    if last && v.epoch == epoch {
      #if DEBUG
        if key == watchedSession && caughtUp.insert(key).inserted { timing("caught up") }
      #endif
      syncing[key] = nil
      behind[key] = nil
      for (e, ops) in held.removeValue(forKey: key) ?? [] {
        if !v.apply(e, ops) {
          sync(key)
          break
        }
      }
    }
    dirty(key)
    notifyListeners()
  }

  private func onLive(_ p: JSONObject) {
    guard let key = p["session"]?.string, let epoch = p["epoch"]?.string else { return }
    heard = Date()
    let ops = (p["ops"]?.array ?? []).compactMap { $0.object.flatMap(LiveOp.init(json:)) }
    let watched = key == watchedSession
    if watched && syncOut(key) {
      held[key, default: []].append((epoch, ops))
      return
    }
    // Other phones' sessions too, when this one has them at hand.
    guard let v = views[key] ?? (watched ? view(key) : nil) else {
      if watched { sync(key) }
      return
    }
    if !v.apply(epoch, ops) && watched { sync(key) }
    dirty(key)
    notifyListeners()
  }

  private func onScreen(_ p: JSONObject) {
    guard let window = p["window"]?.string, let v = p["v"]?.int else { return }
    heard = Date()
    if let c = p["colors"]?.object, let colors = TermColors(json: c) { self.colors[window] = colors }
    let old = screens[window]
    let lines = p["lines"]?.array?.compactMap(\.string)
    let diff = p["diff"]?.object.flatMap(ScreenDiff.init(json:))
    if let lines {
      // How far it scrolled, if it did.
      let drop = old.flatMap { ScreenDiff.between($0.lines, lines)?.drop } ?? 0
      screens[window] = TermScreen(v, lines, (old?.base ?? 0) + drop)
    } else if let diff {
      if let old, old.v == v - 1, let next = diff.apply(old.lines) {
        screens[window] = TermScreen(v, next, old.base + diff.drop)
      } else if window == watchedWindow {
        post("sync", ["from": .string(from), "window": .string(window)])
      }
    }
    notifyListeners()
  }

  // ------------------------------------------------------------------ ops

  /// How long a request waits for the computer's answer, in seconds (a prompt with images three times as
  /// long).
  var answerWait: TimeInterval = 10

  /// How long an answer that came too late is still taken.
  static let lateFor: TimeInterval = 120

  /// [request]'s answer from the computer, sending included within [wait] ([answerWait] by default), under
  /// [id] (a new one by default). With [onLate], an answer that comes after [wait] (the computer did it
  /// after all) still goes there, for a while.
  @discardableResult
  private func run(
    _ request: JSONObject, wait: TimeInterval? = nil, id: String? = nil,
    onLate: ((JSONObject) -> Void)? = nil
  ) async throws -> JSONObject {
    if !online { throw TerminalException("The computer is not answering.") }
    let runId = id ?? UUID().uuidString.lowercased()
    let waiter = Waiter()
    pending[runId] = waiter
    var payload = request
    payload["id"] = .string(runId)
    let reply: JSONObject = try await withCheckedThrowingContinuation { c in
      waiter.continuation = c
      waiter.timer = MainTimer(wait ?? answerWait) { [weak self] in
        guard let c = waiter.continuation else { return }
        waiter.continuation = nil
        if let onLate {
          waiter.late = onLate
          waiter.lateTimer = MainTimer(Self.lateFor) { [weak self] in
            if self?.pending[runId] === waiter { self?.pending[runId] = nil }
          }
        } else if self?.pending[runId] === waiter {
          self?.pending[runId] = nil
        }
        c.resume(throwing: NoAnswer())
      }
      do {
        try send("run", payload)
      } catch {
        waiter.continuation = nil
        waiter.timer?.cancel()
        if pending[runId] === waiter { pending[runId] = nil }
        c.resume(throwing: error)
      }
    }
    if let error = reply["error"]?.string { throw TerminalException(error) }
    return reply
  }

  /// Types [text] into [window], then Enter.
  public func send(_ window: String, _ text: String) async throws {
    try await run(["op": "send", "window": .string(window), "text": .string(text)])
  }

  /// One of [phoneKeys], where the window's terminal can press keys.
  public func press(_ window: String, _ key: String) async throws {
    try await run(["op": "key", "window": .string(window), "key": .string(key)])
  }

  /// Closes [window] on the computer, with what runs in it.
  public func close(_ window: String) async throws { try await run(["op": "close", "window": .string(window)]) }

  /// Whether the agent in [window] looks at work: its screen changed over two seconds on the computer.
  public func probe(_ window: String) async throws -> Bool {
    try await run(["op": "probe", "window": .string(window)])["busy"]?.bool == true
  }

  /// Switches [agent] in [window], which shows only as a screen, to reporting its session: omp quits and
  /// starts again on the same conversation, Claude Code reloads its plugins. The session shows up in
  /// [sessions] once the agent reports.
  public func switchToConversation(_ window: String, _ agent: Agent) async throws {
    try await run(["op": "switch", "window": .string(window), "agent": .string(agent.rawValue)], wait: answerWait * 2)
  }

  /// A new terminal window in [cwd] (where [opensIn] and [placement] say), running the computer's coding
  /// [agent] if [startAgent], in omp [profile] (one of [profiles]; '' the default).
  public func launch(_ cwd: String, startAgent: Bool, profile: String = "") async throws -> Opened {
    var r: JSONObject = ["op": "launch", "cwd": .string(cwd), "agent": .bool(startAgent)]
    if startAgent && !profile.isEmpty { r["profile"] = .string(profile) }
    return try await open(r)
  }

  /// A new folder [name] under [root] (one of [roots]) on the computer, with a window in it as [launch].
  public func create(_ root: String, _ name: String, startAgent: Bool, profile: String = "") async throws -> Opened {
    var r: JSONObject = ["op": "create", "root": .string(root), "name": .string(name), "agent": .bool(startAgent)]
    if startAgent && !profile.isEmpty { r["profile"] = .string(profile) }
    return try await open(r)
  }

  /// Starts the computer's orchestrator, or finds the one running; its window key.
  public func startOrchestrator() async throws -> String { try await open(["op": "orchestrator"]).window }

  /// Runs [request], which opens a window. Starting a terminal app can take a while; a window that opens
  /// after the phone stopped waiting is still taken as new ([fresh]).
  private func open(_ request: JSONObject) async throws -> Opened {
    let reply = try await run(
      request, wait: answerWait * 2,
      onLate: { [weak self] r in
        if let window = r["window"]?.string { self?.fresh(window) }
      })
    guard let window = reply["window"]?.string else { throw TerminalException("The computer did not say which window.") }
    fresh(window)
    return Opened(window: window, where: reply["where"]?.string ?? "")
  }

  /// A window just opened under [window]'s key. A key can come back (tmux numbers panes from %0 again once
  /// its server restarts, Terminal reuses ttys): what the phone kept for it is an ended session's, and goes.
  private func fresh(_ window: String) {
    views[window] = nil
    writes.removeValue(forKey: window)?.cancel()
    try? FileManager.default.removeItem(at: sessionFile(window))
  }

  /// The last prompt the computer didn't answer (the app went to the background, the network dropped): what
  /// it was and the id it went under. The same prompt sent again soon goes under the same id, which the
  /// computer answers without running it twice if it got it the first time (TerminalBridge on the computer).
  private var unansweredPrompt: (what: String, id: String, at: Date)?
  static let sameFor: TimeInterval = 120

  /// Prompts [session] with [text], [images] (image files: PNG, JPEG) and [files] (any file, as it is).
  /// Their bytes pass through the server sealed with [key]; a file's name and type go inside the sealed
  /// request. While omp works the prompt steers it, or waits for the turn to end if [followUp]; Claude Code
  /// always waits. One that waits goes to the session's queue on the computer: the id it waits under there
  /// ([LiveSummary.queue]), else nil.
  @discardableResult
  public func prompt(
    _ session: String, _ text: String, images: [Data] = [], files: [PromptFile] = [], followUp: Bool = false
  ) async throws -> String? {
    if !online { throw TerminalException("The computer is not answering.") }
    func sha1(_ d: Data) -> String { Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    var parts: [JSON] = [.string(session), .string(text), .bool(followUp)]
    parts += images.map { .string(sha1($0)) }
    parts += files.map { .array([.string($0.name), .string($0.mime), .string(sha1($0.bytes))]) }
    let what = sha1(Data(JSON.array(parts).encoded().utf8))
    let now = Date()
    let again: (what: String, id: String, at: Date)? =
      if let u = unansweredPrompt, u.what == what, now.timeIntervalSince(u.at) < Self.sameFor { u } else { nil }
    let id = again?.id ?? UUID().uuidString.lowercased()
    let server = server
    let upload: ImageUpload = uploadImage ?? { [server] path, bytes in try await server.putBlob(path, bytes) }
    var paths: [String] = []
    var sent: [JSONObject] = []
    func forget() {
      for path in paths + sent.compactMap({ $0["path"]?.string }) {
        Task {
          do { try await server.deleteBlob(path) } catch { debugLog("\(error)") }
        }
      }
    }
    func sealed(_ bytes: Data) async throws -> String {
      let path = server.newBlobPath()
      try await upload(path, sealBytes(key, bytes, imageAad(path)))
      return path
    }
    do {
      for bytes in images { paths.append(try await sealed(bytes)) }
      for f in files {
        sent.append(["path": .string(try await sealed(f.bytes)), "name": .string(f.name), "mime": .string(f.mime)])
      }
    } catch {
      forget()
      throw TerminalException("The \(paths.count < images.count ? "image" : "file") didn't upload: \(error)")
    }
    let bytes = (images + files.map(\.bytes)).reduce(0) { $0 + $1.count }
    var request: JSONObject = [
      "op": "prompt", "session": .string(session), "text": .string(text), "images": .strings(paths),
      "deliver": .string(followUp ? "followUp" : "steer"),
    ]
    if !sent.isEmpty { request["files"] = .array(sent.map(JSON.object)) }
    do {
      let reply = try await run(
        request,
        // The computer downloads them first: a second more for each MB.
        wait: bytes == 0 ? answerWait : answerWait * 3 + TimeInterval(bytes >> 20), id: id)
      unansweredPrompt = nil
      // The computer had it already, with the images and files sent the first time.
      if reply["repeat"]?.bool == true { forget() }
      return reply["queued"]?.string
    } catch let e as TerminalException {
      unansweredPrompt = e is NoAnswer ? (what, id, again?.at ?? now) : nil
      // The computer deletes them once used; unanswered, nobody would.
      forget()
      throw e
    }
  }

  /// Esc: stops what the agent is doing.
  public func abort(_ session: String) async throws { try await run(["op": "abort", "session": .string(session)]) }

  /// Changes [session]'s queue on the computer ([LiveSummary.queue]): [item]'s text to [text].
  public func editQueued(_ session: String, _ item: String, _ text: String) async throws {
    try await queue(session, "edit", ["item": .string(item), "text": .string(text)])
  }

  /// Takes [item] out of [session]'s queue: it never goes.
  public func removeQueued(_ session: String, _ item: String) async throws {
    try await queue(session, "remove", ["item": .string(item)])
  }

  /// Moves [item] to place [to] (0: next) in [session]'s queue.
  public func moveQueued(_ session: String, _ item: String, _ to: Int) async throws {
    try await queue(session, "move", ["item": .string(item), "to": .int(to)])
  }

  /// Sends [item] now, out of [session]'s queue: it steers the run (omp).
  public func sendQueuedNow(_ session: String, _ item: String) async throws {
    try await queue(session, "send", ["item": .string(item)])
  }

  /// Holds [session]'s queue, or lets it go on ([paused] false): the next prompt goes when the run ends, or
  /// now if it has ended.
  public func pauseQueue(_ session: String, paused: Bool) async throws {
    try await queue(session, paused ? "pause" : "resume")
  }

  private func queue(_ session: String, _ what: String, _ args: JSONObject = [:]) async throws {
    var r: JSONObject = ["op": "queue", "session": .string(session), "do": .string(what)]
    r.merge(args) { _, new in new }
    try await run(r)
  }

  /// Answers [ask]: [answers] (one per question), or [approve] an approval.
  public func answer(_ session: String, _ ask: LiveAsk, answers: [LiveAnswer] = [], approve: Bool = false)
    async throws
  {
    var r: JSONObject = ["op": "answer", "session": .string(session), "ask": .string(ask.id)]
    if ask.isApproval {
      r["approve"] = .bool(approve)
    } else {
      r["answers"] = .array(answers.map { .object($0.toJson()) })
    }
    try await run(r)
  }

  /// Fetches items before the oldest the computer has; they arrive as live ops.
  public func older(_ session: String) async throws { try await run(["op": "older", "session": .string(session)]) }

  // ---------------------------------------------------------------- cache

  /// [writes]' key for state.json (session keys are never empty).
  static let stateKey = ""

  private var stateFile: URL { cacheDir.appendingPathComponent("state.json") }
  private var sessionDir: URL { cacheDir.appendingPathComponent("sessions") }
  private func sessionFile(_ key: String) -> URL {
    let hash = Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return sessionDir.appendingPathComponent("\(hash).json")
  }

  private func load() {
    if let data = try? Data(contentsOf: stateFile) {
      if let j = JSON.tryParse(data)?.object {
        applyState(j)
        stateAt = j["at"]?.int.map(dateFromMilliseconds)
        fromCache = true
      } else {
        debugLog("PocketTerm: terminal cache: state.json unreadable")
      }
    }
    let fm = FileManager.default
    guard
      let files = try? fm.contentsOfDirectory(
        at: sessionDir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
    else { return }
    let now = Date()
    for f in files {
      let values = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
      if now.timeIntervalSince(modified) > Self.keepFor { try? fm.removeItem(at: f) }
    }
  }

  /// Writes [key]'s file (a session, or [stateKey]) soon, at most every [writeEvery].
  private func dirty(_ key: String) {
    if writes[key] != nil { return }
    writes[key] = MainTimer(Self.writeEvery) { [weak self] in
      self?.writes[key] = nil
      self?.write(key)
    }
  }

  /// Writes every file waiting to be.
  public func flush() {
    for key in Array(writes.keys) {
      writes.removeValue(forKey: key)?.cancel()
      write(key)
    }
  }

  private func write(_ key: String) {
    let now = millisecondsSinceEpoch(Date())
    let file: URL
    var json: JSONObject
    if key == Self.stateKey {
      file = stateFile
      json = [
        "windows": .array(windows.map { .object($0.toJson()) }),
        "sessions": .array(sessions.map { .object($0.toJson()) }),
        "projects": .strings(projects),
        "home": .string(home),
        "agent": .string(agent.rawValue),
        "agents": .object(AgentIntegration.toJsonAll(agents)),
        "terminals": .array(terminals.map { .object($0.toJson()) }),
        "at": .int(stateAt.map(millisecondsSinceEpoch) ?? now),
      ]
      if let roots { json["roots"] = .strings(roots) }
      if !profiles.isEmpty { json["profiles"] = .strings(profiles) }
      if let opensIn { json["opensIn"] = .string(opensIn) }
      if let placement { json["placement"] = .string(placement.rawValue) }
    } else {
      guard let v = views[key] else { return }
      file = sessionFile(key)
      json = v.toJson()
      json["key"] = .string(key)
      json["at"] = .int(now)
    }
    do {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Whole or not at all, should the app be killed mid-write.
      try Data(json.encoded().utf8).write(to: file, options: .atomic)
    } catch {
      debugLog("PocketTerm: terminal cache: \(error)")
    }
  }

  /// Stops everything: the channel, the timers; requests waiting for an answer fail.
  public func dispose() {
    users = 1
    detach()
    for (_, w) in pending {
      w.timer?.cancel()
      w.lateTimer?.cancel()
      if let c = w.continuation {
        w.continuation = nil
        c.resume(throwing: TerminalException("Closed."))
      }
    }
    pending.removeAll()
  }
}
