import Foundation

/// Receives one message, opened: its fields as the sender gave them.
public typealias TopicHandler = @MainActor (JSONObject) -> Void

/// Seals what goes out on [topic] with the computer's [key] and opens what comes in (E2E.swift). Each
/// message gets a `ts`, a random `mid`, this seal's `ep` (random, new for each seal: each start of a sender)
/// and `seq` (1, 2, 3 …). What doesn't open or the [ReplayGuard] refuses (stale, seen before, out of order)
/// is dropped and logged once per kind. The guard is the computer's for this run of the app
/// ([ReplayGuard.of]) unless one is given (`guard`, or a fresh one on a test `clock`).
public final class ChannelSeal: @unchecked Sendable {
  public init(
    _ key: ChannelKey, _ topic: String, name: String = "channel", guard replayGuard: ReplayGuard? = nil,
    clock: (@Sendable () -> Date)? = nil
  ) {
    self.key = key
    self.topic = topic
    self.name = name
    self.clock = clock ?? { Date() }
    self.replayGuard = replayGuard ?? (clock == nil ? ReplayGuard.of(topic) : ReplayGuard(clock: clock))
  }

  public let key: ChannelKey
  public let topic: String

  /// Who this is, in the log.
  public let name: String
  private let clock: @Sendable () -> Date
  private let replayGuard: ReplayGuard
  private let epoch = newMessageId()
  private struct State {
    var logged: Set<String> = []
    var seq = 0
    var clockOff: TimeInterval?
  }
  private let state = Locked(State())

  /// [payload] of [event], as it goes on the topic. Seal in the order sent: a receiver drops a `seq` below
  /// one it already took. The payload goes whole under `m`, beside the envelope's `ts`, `mid`, `ep` and
  /// `seq`, so a payload's own keys of those names (an items catch-up's `seq`) stay.
  public func seal(_ event: String, _ payload: JSONObject) -> JSONObject {
    let seq = state.with { s -> Int in
      s.seq += 1
      return s.seq
    }
    return sealEnvelope(
      key,
      [
        "m": .object(payload), "ts": .int(millisecondsSinceEpoch(clock())), "mid": .string(newMessageId()),
        "ep": .string(epoch), "seq": .int(seq),
      ], channelAad(topic, event))
  }

  /// How far the other side's clock is ahead of this one in seconds (behind: negative), as the last message
  /// dropped for its time showed; nil once a message opens. The guard drops every message more than its
  /// window off, so with a clock that wrong nothing gets through at all.
  public var clockOff: TimeInterval? { state.get.clockOff }

  /// What [wire] (an [event] off the topic) says: the payload [seal] put in; nil when it's dropped.
  public func open(_ event: String, _ wire: JSONObject) -> JSONObject? {
    let opened = openEnvelope(key, wire, channelAad(topic, event))
    let why = opened.drop ?? replayGuard.check(opened.message!)
    if why == "time", let ts = opened.message?["ts"]?.int {
      let off = TimeInterval(ts - millisecondsSinceEpoch(clock())) / 1000
      // A message from before this app started is old, not off.
      if abs(off) > replayGuard.window {
        let first = state.with { s -> Bool in
          s.clockOff = off
          return s.logged.insert("clock").inserted
        }
        if first { debugLog("PocketTerm: \(name): the other side's clock is off by \(Int(off)) s") }
      }
    }
    if let why {
      if state.with({ $0.logged.insert("\(event) \(why)").inserted }) {
        debugLog("PocketTerm: \(name): dropped \(event) (\(why)); more alike go unlogged")
      }
      return nil
    }
    state.with { $0.clockOff = nil }
    guard let payload = opened.message?["m"]?.object else {
      if state.with({ $0.logged.insert("\(event) shape").inserted }) {
        debugLog("PocketTerm: \(name): dropped \(event) (no payload)")
      }
      return nil
    }
    return payload
  }
}

/// A computer's [topic] (its id) on the server's live channel (GET /v1/ws, packages/pocketterm_server/PROTOCOL.md;
/// Supabase Realtime for a Supabase project, SupabaseServer.swift), kept joined while open. Everything on it
/// is sealed with the computer's key ([ChannelSeal]): the server only relays envelopes; handlers get the
/// opened messages, in the order they came.
///
/// Whenever it isn't joined (no connection, the server went away or restarted, a join nobody answers, two
/// pings without a pong) this connects again after 1 s, 2 s, 4 s … up to [maxWait]. A close with 4003 (this
/// device was revoked or left) ends the sign-in instead ([Server.refused]).
@MainActor
public final class TerminalChannel {
  public init(
    _ server: Server, _ topic: String, _ handlers: [String: TopicHandler], key: ChannelKey, name: String,
    onJoined: (@MainActor (_ joined: Bool) -> Void)? = nil, onUnreachable: (@MainActor () -> Void)? = nil
  ) {
    self.server = server
    self.topic = topic
    self.handlers = handlers
    self.name = name
    self.onJoined = onJoined
    self.onUnreachable = onUnreachable
    seal = ChannelSeal(key, topic, name: name)
  }

  private let server: Server

  /// The topic joined: the computer's id.
  public let topic: String
  private let handlers: [String: TopicHandler]
  private let seal: ChannelSeal

  /// Who this is, in the log.
  public let name: String

  /// The channel joined (true), or stopped being joined (false).
  public var onJoined: (@MainActor (_ joined: Bool) -> Void)?

  /// [unreachable] changed.
  public var onUnreachable: (@MainActor () -> Void)?

  static let firstWait: TimeInterval = 1
  static let maxWait: TimeInterval = 30

  /// How long a join may take before it counts as stuck.
  static let stuck: TimeInterval = 20

  /// How often to ping the server; two without a pong and the link is dead.
  static let pingEvery: TimeInterval = 25

  private var ws: LiveSocket?
  private var reader: Task<Void, Never>?
  private var isOpen = false
  public private(set) var joined = false
  private var retry: MainTimer?
  private var joinWait: MainTimer?
  private var ping: MainTimer?
  private var unanswered = 0
  private var wait = firstWait

  /// Bumped by [open] and [close]: a connection still on its way from before must not make a second one.
  private var gen = 0

  /// How far the other side's clock is off this one's, while it's too far for its messages to be taken
  /// ([ChannelSeal.clockOff]).
  public var clockOff: TimeInterval? { seal.clockOff }

  /// The last try to connect got no connection to the server (offline, DNS, TLS, a timeout), as opposed to
  /// one still on its way; false again once a connection is made, and after [close].
  public private(set) var unreachable = false

  public func open() {
    if isOpen { return }
    isOpen = true
    gen += 1
    let gen = gen
    debugLog("PocketTerm: \(name): open")
    wait = Self.firstWait
    Task { await connect(gen) }
  }

  public func close() {
    if !isOpen { return }
    isOpen = false
    gen += 1
    debugLog("PocketTerm: \(name): close")
    retry?.cancel()
    retry = nil
    unreachable = false
    drop()
  }

  /// Connects again at once, on a new socket, with the wait between tries back at its shortest: the person
  /// asked (Retry), so whatever the last try ran into may be gone. Nothing while closed.
  public func reconnect() {
    if !isOpen { return }
    gen += 1
    let gen = gen
    debugLog("PocketTerm: \(name): reconnect")
    retry?.cancel()
    retry = nil
    drop()
    wait = Self.firstWait
    setUnreachable(false)
    Task { await connect(gen) }
  }

  /// The largest frame the server takes (packages/pocketterm_server/PROTOCOL.md); a larger one would close the
  /// socket, and every message after it would be lost until the next join.
  public static let maxFrameBytes = 256 * 1024

  /// Drops [event] if the channel isn't joined: whoever waits on an answer times out, and the other side
  /// catches up after the next join. A message too big for the server fails with a [TerminalException] and
  /// goes nowhere; the connection stays.
  public func send(_ event: String, _ payload: JSONObject) throws {
    guard let ws, joined else { return }
    let sealed = seal.seal(event, payload)
    // Sealed, it's all ASCII: its length is its size in bytes.
    let frame = (["t": "send", "topic": .string(topic), "event": .string(event), "payload": .object(sealed)] as JSONObject)
      .encoded()
    if frame.utf8.count > Self.maxFrameBytes {
      debugLog("PocketTerm: \(name): \(event) not sent: \(frame.utf8.count) bytes, over \(Self.maxFrameBytes)")
      throw TerminalException("That is too big to send in one go. Send it in smaller parts.")
    }
    ws.add(frame)
  }

  private func connect(_ gen: Int) async {
    func stale() -> Bool { !isOpen || gen != self.gen }
    let ws: LiveSocket
    do {
      timing("socket connecting")
      ws = try await server.connectLive()
    } catch {
      timing("socket failed")
      if stale() { return }
      // Refused at the door: maybe the token stopped working.
      let server = server
      Task { await server.recheck() }
      setUnreachable(true)
      return again(nil, "\(error)")
    }
    if stale() {
      Task { await ws.close() }
      return
    }
    timing("socket open")
    setUnreachable(false)
    self.ws = ws
    reader = Task { @MainActor [weak self] in
      for await data in ws.frames { self?.frame(ws, data) }
      self?.closed(ws)
    }
    ws.add((["t": "join", "topic": .string(topic)] as JSONObject).encoded())
    joinWait = MainTimer(Self.stuck) { [weak self] in self?.again(ws, "no answer to the join") }
    unanswered = 0
    ping = MainTimer(every: Self.pingEvery) { [weak self] in
      guard let self else { return }
      if self.unanswered >= 2 { return self.again(ws, "no answer to the pings") }
      self.unanswered += 1
      ws.add((["t": "ping"] as JSONObject).encoded())
    }
  }

  private func frame(_ ws: LiveSocket, _ data: String) {
    guard ws === self.ws, let frame = JSON.tryParse(data) else { return }
    switch frame["t"]?.string {
    case "joined":
      guard frame["topic"]?.string == topic else { return }
      timing("joined")
      joinWait?.cancel()
      wait = Self.firstWait
      setJoined(true)
    case "msg":
      guard frame["topic"]?.string == topic, let event = frame["event"]?.string, let p = frame["payload"]?.object,
        let handler = handlers[event]
      else { return }
      // Opening is synchronous here, so messages are handled in the order they came.
      if let message = seal.open(event, p) { handler(message) }
    case "pong":
      unanswered = 0
    case "error":
      guard let error = frame["error"]?.string else { return }
      debugLog("PocketTerm: \(name): the server said \(error)")
      // Joined on the server no more (it restarted under us).
      if error == "not_joined" { again(ws, error) }
    default:
      break
    }
  }

  private func closed(_ ws: LiveSocket) {
    guard ws === self.ws else { return }
    if ws.closeCode == 4003 {
      debugLog("PocketTerm: \(name): this device was signed out on the server")
      drop()
      let server = server
      Task { await server.refused() }
      return
    }
    again(ws, "closed\(ws.closeCode.map { " (\($0))" } ?? "")")
  }

  /// Leaves the connection there is, if any.
  private func drop() {
    joinWait?.cancel()
    ping?.cancel()
    joinWait = nil
    ping = nil
    setJoined(false)
    let ws = self.ws
    self.ws = nil
    reader?.cancel()
    reader = nil
    if let ws { Task { await ws.close() } }
  }

  /// [ws] (nil: none was made) is no good: a new one after a while.
  private func again(_ ws: LiveSocket?, _ why: String) {
    guard isOpen, retry == nil, ws === self.ws else { return }
    drop()
    let wait = self.wait
    self.wait = min(self.wait * 2, Self.maxWait)
    debugLog("PocketTerm: \(name): joining again in \(Int(wait)) s (\(why))")
    let gen = gen
    retry = MainTimer(wait) { [weak self] in
      guard let self else { return }
      self.retry = nil
      if gen == self.gen { Task { await self.connect(gen) } }
    }
  }

  private func setUnreachable(_ value: Bool) {
    if unreachable == value { return }
    unreachable = value
    onUnreachable?()
  }

  private func setJoined(_ value: Bool) {
    if joined == value { return }
    joined = value
    debugLog("PocketTerm: \(name): \(value ? "joined" : "not joined")")
    onJoined?(value)
  }
}
