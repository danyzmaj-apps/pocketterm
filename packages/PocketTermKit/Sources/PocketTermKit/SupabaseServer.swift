import Foundation

/// A Realtime token for this device, when it runs out, and the project's publishable key (Realtime takes
/// it with every connection).
public struct LiveToken: Sendable, Hashable {
  public let token: String
  public let expires: Date
  public let apikey: String
}

/// PocketTerm set up on a Supabase project (apps/pocketterm-desktop/supabase): the same REST paths as the
/// PocketTerm server under `<project>/functions/v1/pocketterm`, so everything but the live channel is
/// [PocketTermServerClient]'s. The live channel is Supabase Realtime broadcast on private topics: the
/// function mints this device a Realtime token for 10 minutes at a time (POST /v1/live/token), which
/// Realtime checks against the devices still signed in on every join and refresh.
public final class SupabaseServerClient: PocketTermServerClient, @unchecked Sendable {
  /// Computer only: a setup link for another computer (POST /v1/setup/new). The one before stops working;
  /// nobody is signed out.
  public func newSetupLink() async throws -> URL {
    guard let setup = try await request("POST", "/v1/setup/new")?["setup"]?.string else {
      throw ServerException(500, "internal", "The server didn't send a setup link.")
    }
    return backend.linkWithSetup(setup)
  }

  /// A Realtime token for this device (POST /v1/live/token).
  public func liveToken() async throws -> LiveToken {
    let answer = try await request("POST", "/v1/live/token")
    guard let token = answer?["token"]?.string, let expires = answer?["expires"]?.int,
      let apikey = answer?["apikey"]?.string
    else { throw ServerException(500, "internal", "The server didn't send a live channel token.") }
    return LiveToken(token: token, expires: Date(timeIntervalSince1970: TimeInterval(expires)), apikey: apikey)
  }

  public override func connectLive() async throws -> LiveSocket {
    let first = try await liveToken()
    guard var c = URLComponents(string: backend.url) else { throw ServerException(0, "offline", backend.unreachable) }
    c.scheme = c.scheme == "https" ? "wss" : "ws"
    c.path = "/realtime/v1/websocket"
    c.percentEncodedQuery = "apikey=\(encodeQueryComponent(first.apikey))&vsn=1.0.0"
    let ws = try await WebSocketLive.connect(URLRequest(url: c.url!), timeout: 20)
    return RealtimeLive(self, ws, first)
  }
}

/// Supabase Realtime (Phoenix channels, protocol 1.0.0) as a [LiveSocket]: PROTOCOL.md's frames in and out.
/// A `join` joins the private channel `realtime:<topic>` with this device's token, `send` broadcasts,
/// `ping` is Phoenix's heartbeat. The token is renewed a minute before it runs out; a refusal (the device
/// was signed out) closes this with 4003. A join Realtime refuses, or a channel it closes, closes this too
/// (the live channel connects again), after asking the server whether the sign-in still holds. `pt.left` on
/// a topic (someone was signed out) asks it too.
final class RealtimeLive: LiveSocket, @unchecked Sendable {
  /// [ws] carries Phoenix's frames; [send] stands in for it in tests.
  init(_ server: SupabaseServerClient?, _ ws: LiveSocket?, _ token: LiveToken, send: (@Sendable (String) -> Void)? = nil,
    recheck: (@Sendable () async -> Void)? = nil, renewToken: (@Sendable () async throws -> LiveToken)? = nil)
  {
    self.server = server
    self.ws = ws
    self.sendRaw = send ?? { [weak ws] in ws?.add($0) }
    self.recheckNow = recheck ?? { [weak server] in await server?.recheck() }
    self.renewToken = renewToken ?? { [weak server] in
      guard let server else { throw ServerException(0, "offline", "Closed.") }
      return try await server.liveToken()
    }
    (frames, out) = AsyncStream.makeStream(of: String.self)
    state = Locked(State(token: token))
    if let ws {
      reader = Task { [weak self] in
        for await data in ws.frames { self?.receive(data) }
        self?.gone()
      }
    }
    renewLater()
  }

  private weak var server: SupabaseServerClient?
  private let ws: LiveSocket?
  private let sendRaw: @Sendable (String) -> Void
  private let recheckNow: @Sendable () async -> Void
  private let renewToken: @Sendable () async throws -> LiveToken
  private var reader: Task<Void, Never>?
  let frames: AsyncStream<String>
  private let out: AsyncStream<String>.Continuation

  private struct State {
    var token: LiveToken
    var renew: Task<Void, Never>?
    var code: Int?
    var ref = 0
    var closed = false
    /// The topics joined (or joining) and their join refs.
    var joins: [String: String] = [:]
    /// Join refs waiting for Realtime's answer, and their topics.
    var joining: [String: String] = [:]
    /// Heartbeat refs waiting for an answer.
    var beats: Set<String> = []
  }
  private let state: Locked<State>

  var closeCode: Int? { state.get.code ?? ws?.closeCode }

  private func next() -> String { state.with { s in s.ref += 1; return "\(s.ref)" } }

  private func phx(_ topic: String, _ event: String, _ payload: JSONObject, ref: String?, joinRef: String? = nil) {
    if state.get.closed { return }
    var frame: JSONObject = ["topic": .string(topic), "event": .string(event), "payload": .object(payload), "ref": ref.map(JSON.string) ?? .null]
    if let joinRef { frame["join_ref"] = .string(joinRef) }
    sendRaw(frame.encoded())
  }

  private func emit(_ frame: JSONObject) {
    if !state.get.closed { out.yield(frame.encoded()) }
  }

  func add(_ frame: String) {
    guard let f = JSON.tryParse(frame) else { return }
    switch f["t"]?.string {
    case "join":
      guard let topic = f["topic"]?.string else { return }
      let ref = next()
      let token = state.with { s -> String in
        s.joins[topic] = ref
        s.joining[ref] = topic
        return s.token.token
      }
      phx(
        "realtime:\(topic)", "phx_join",
        [
          "config": [
            "broadcast": ["self": false, "ack": false],
            "presence": ["key": "", "enabled": false],
            "private": true,
          ],
          "access_token": .string(token),
        ], ref: ref, joinRef: ref)
    case "send":
      guard let topic = f["topic"]?.string, let event = f["event"]?.string, let payload = f["payload"] else { return }
      let joinRef = state.with { s -> String? in
        s.joining.values.contains(topic) ? nil : s.joins[topic]
      }
      guard let joinRef else {
        return emit(["t": "error", "error": "not_joined", "message": .string("Join \(topic) first.")])
      }
      phx("realtime:\(topic)", "broadcast", ["type": "broadcast", "event": .string(event), "payload": payload], ref: next(), joinRef: joinRef)
    case "leave":
      guard let topic = f["topic"]?.string else { return }
      if let joinRef = state.with({ $0.joins.removeValue(forKey: topic) }) {
        phx("realtime:\(topic)", "phx_leave", [:], ref: next(), joinRef: joinRef)
      }
    case "ping":
      let ref = next()
      _ = state.with { $0.beats.insert(ref) }
      phx("phoenix", "heartbeat", [:], ref: ref)
    default:
      break
    }
  }

  /// One frame from Realtime.
  func receive(_ data: String) {
    guard let m = JSON.tryParse(data)?.object else { return }
    var topic = m["topic"]?.string ?? ""
    if let r = topic.range(of: "realtime:") { topic.replaceSubrange(r, with: "") }
    let payload = m["payload"]
    let ref = m["ref"]?.string
    switch m["event"]?.string {
    case "phx_reply":
      if let ref, state.with({ $0.beats.remove(ref) }) != nil { return emit(["t": "pong"]) }
      if let ref, let joined = state.with({ $0.joining.removeValue(forKey: ref) }) {
        if payload?["status"]?.string == "ok" { return emit(["t": "joined", "topic": .string(joined)]) }
        debugLog("PocketTerm: Realtime refused \(joined): \(payload?["response"] ?? payload ?? .null)")
        refused()
      }
    case "broadcast":
      guard state.get.joins[topic] != nil, let event = payload?["event"]?.string, let inner = payload?.object?["payload"]
      else { return }
      // Someone was signed out: this device asks whether it was.
      if event == "pt.left" {
        let recheck = recheckNow
        Task { await recheck() }
        return
      }
      emit(["t": "msg", "topic": .string(topic), "event": .string(event), "payload": inner])
    case "phx_error", "phx_close":
      guard state.get.joins[topic] != nil else { return }
      debugLog("PocketTerm: Realtime closed \(topic) (\(m["event"]?.string ?? ""))")
      refused()
    case "system":
      guard payload?["status"]?.string == "error" else { return }
      debugLog("PocketTerm: Realtime: \(payload?["message"] ?? .null)")
      refused()
    default:
      break
    }
  }

  /// Realtime turned this device away or closed its channel (an old token, a device signed out meanwhile):
  /// ask the server, then connect again.
  private func refused() {
    let recheck = recheckNow
    Task {
      await recheck()
    }
    Task { await self.close(1000) }
  }

  private func renewLater(after: TimeInterval? = nil) {
    let wait = after ?? max(10, state.get.token.expires.timeIntervalSinceNow - 60)
    let task = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.renewNow()
    }
    state.with {
      $0.renew?.cancel()
      $0.renew = task
    }
  }

  private func renewNow() async {
    let token: LiveToken
    do {
      token = try await renewToken()
    } catch let e as ServerException where e.status == 401 {
      return await close(4003)
    } catch {
      return renewLater(after: 15)
    }
    let joins = state.with { s -> [String: String]? in
      if s.closed { return nil }
      s.token = token
      return s.joins
    }
    guard let joins else { return }
    for (topic, joinRef) in joins {
      phx("realtime:\(topic)", "access_token", ["access_token": .string(token.token)], ref: next(), joinRef: joinRef)
    }
    renewLater()
  }

  /// Renews the token now (tests: the first renewal waits at least 10 s).
  func renewForTests() async { await renewNow() }

  private func gone() {
    let first = state.with { s -> Bool in
      s.renew?.cancel()
      defer { s.closed = true }
      return !s.closed
    }
    if first { out.finish() }
  }

  func close(_ code: Int) async {
    let first = state.with { s -> Bool in
      if s.code == nil, code != 1000 { s.code = code }
      s.renew?.cancel()
      defer { s.closed = true }
      return !s.closed
    }
    if first { out.finish() }
    reader?.cancel()
    await ws?.close(1000)
  }
}
