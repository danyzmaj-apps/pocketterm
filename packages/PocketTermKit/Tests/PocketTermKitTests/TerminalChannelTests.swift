import Foundation
import XCTest

@testable import PocketTermKit

/// terminal_channel_test.dart, over an in-memory live channel ([FakeSocket]); InteropTests runs the real
/// server's WebSocket.
@MainActor
final class TerminalChannelTests: XCTestCase {
  let topic = "abcd1234"
  let key = ChannelKey(Data(repeating: 3, count: 32))!
  var server: FakeServer!
  var sockets: Locked<[FakeSocket]>!
  var refuse: Locked<Int>!
  var channel: TerminalChannel!
  var states: [Bool] = []
  var received: [JSONObject] = []
  /// The computer's side of the topic; its guard starts with the test, before anything is sealed.
  var computer: ChannelSeal!

  override func setUp() async throws {
    server = FakeServer()
    let sockets = Locked<[FakeSocket]>([])
    let refuse = Locked(0)
    self.sockets = sockets
    self.refuse = refuse
    server.live = {
      let refused = refuse.with { n -> Bool in
        if n > 0 {
          n -= 1
          return true
        }
        return false
      }
      if refused { throw ServerException(401, "unauthorized", "No.") }
      let s = FakeSocket()
      sockets.with { $0.append(s) }
      return s
    }
    states = []
    computer = ChannelSeal(key, topic, guard: ReplayGuard())
    received = []
    channel = TerminalChannel(
      server, topic, ["state": { [weak self] in self?.received.append($0) }], key: key, name: "test",
      onJoined: { [weak self] joined in self?.states.append(joined) })
  }

  override func tearDown() async throws {
    channel.close()
  }

  var socket: FakeSocket? { sockets.get.last }

  func until(_ seconds: TimeInterval = 5, _ check: @escaping () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !check() && Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
    let ok = check()
    XCTAssertTrue(ok)
  }

  func testDroppedConnectionIsMadeAgain() async {
    channel.open()
    await until { self.channel.joined }
    socket!.drop(1001)
    await until { !self.channel.joined }
    await until(3) { self.sockets.get.count == 2 && self.channel.joined }
    XCTAssertEqual(states, [true, false, true])
    socket!.deliver(topic, "state", computer.seal("state", ["windows": 3]))
    await until { !self.received.isEmpty }
    XCTAssertEqual(received, [["windows": 3]])
  }

  func testOrderUnsealedAndSent() async throws {
    channel.open()
    await until { self.channel.joined }
    socket!.deliver(topic, "state", ["windows": 99])
    for i in 0..<20 { socket!.deliver(topic, "state", computer.seal("state", ["windows": .int(i)])) }
    await until { self.received.count == 20 }
    XCTAssertEqual(received.map { $0["windows"]?.int }, Array(0..<20))

    try channel.send("hello", ["from": "phone"])
    let sent = socket!.sent
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(Set(sent[0].payload.keys), ["v", "n", "c"], "the server sees only the envelope")
    XCTAssertEqual(computer.open(sent[0].event, sent[0].payload), ["from": "phone"])
  }

  func testRefusedAtTheDoorIsTriedAgain() async {
    refuse.with { $0 = 2 }
    channel.open()
    await until(6) { self.channel.joined }
    XCTAssertEqual(states, [true])
    XCTAssertGreaterThanOrEqual(server.rechecks, 2, "refused at the door: the sign-in is asked about")
  }

  func testRetryConnectsAtOnce() async {
    refuse.with { $0 = 1000 }
    channel.open()
    // Refused at 0, 1 and 3 s: the next try would be at 7 s.
    await until(5) { self.refuse.get <= 997 }
    XCTAssertTrue(channel.unreachable)
    refuse.with { $0 = 0 }
    let retried = Date()
    channel.reconnect()
    XCTAssertFalse(channel.unreachable, "trying again, not given up")
    await until { self.channel.joined }
    XCTAssertLessThan(Date().timeIntervalSince(retried), 1)
    XCTAssertEqual(states, [true])
  }

  func testAfterCloseNothingJoinsAgain() async throws {
    channel.open()
    await until { self.channel.joined }
    let first = socket!
    channel.close()
    first.drop(1001)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    XCTAssertEqual(sockets.get.count, 1)
    XCTAssertFalse(channel.joined)
    XCTAssertTrue(first.closed)
  }

  func testTooBigIsRefusedBeforeItGoes() async throws {
    channel.open()
    await until { self.channel.joined }
    XCTAssertThrowsError(try channel.send("run", ["text": .string(String(repeating: "x", count: 200 * 1024))])) {
      XCTAssertTrue($0 is TerminalException)
    }
    try channel.send("run", ["text": "small"])
    XCTAssertEqual(socket!.sent.count, 1)
    XCTAssertEqual(computer.open("run", socket!.sent[0].payload), ["text": "small"])
    XCTAssertEqual(states, [true], "never dropped")
  }

  func testNotJoinedDropsWhatGoesOut() throws {
    try channel.send("hello", ["from": "phone"])
    XCTAssertTrue(sockets.get.isEmpty)
  }

  func testRevokedEndsTheSignIn() async throws {
    channel.open()
    await until { self.channel.joined }
    socket!.drop(4003)
    await until { self.server.refusedCount == 1 }
    try await Task.sleep(nanoseconds: 1_500_000_000)
    XCTAssertEqual(sockets.get.count, 1)
    XCTAssertFalse(channel.joined)
  }

  func testNotJoinedErrorJoinsAgain() async {
    channel.open()
    await until { self.channel.joined }
    socket!.raw(#"{"t":"error","error":"not_joined","message":"Join first."}"#)
    await until(3) { self.sockets.get.count == 2 && self.channel.joined }
    XCTAssertEqual(states, [true, false, true])
  }

  func testUnreachableUntilLetInAgain() async {
    var told = 0
    channel = TerminalChannel(server, topic, [:], key: key, name: "test", onUnreachable: { told += 1 })
    channel.open()
    await until { self.channel.joined }
    XCTAssertFalse(channel.unreachable)
    refuse.with { $0 = 1 }
    socket!.drop(1001)
    await until { self.channel.unreachable }
    XCTAssertFalse(channel.joined)
    await until(5) { self.channel.joined }
    XCTAssertFalse(channel.unreachable)
    XCTAssertEqual(told, 2, "once when it went, once when it came back")
    channel.close()
    XCTAssertFalse(channel.unreachable, "closed, nothing is tried")
  }

  func testClockOffIsToldApart() {
    let skew = Locked<TimeInterval>(12 * 60)
    let phone = ChannelSeal(key, topic, clock: { Date().addingTimeInterval(skew.get) })
    let mac = ChannelSeal(key, topic, clock: { Date() })
    XCTAssertNil(mac.open("hello", phone.seal("hello", ["from": "p"])))
    XCTAssertEqual(mac.clockOff ?? 0, 12 * 60, accuracy: 2)
    skew.with { $0 = -30 * 60 }
    XCTAssertNil(mac.open("hello", phone.seal("hello", ["from": "p"])))
    XCTAssertEqual(mac.clockOff ?? 0, -30 * 60, accuracy: 2)
    skew.with { $0 = 0 }
    XCTAssertEqual(mac.open("hello", phone.seal("hello", ["from": "p"])), ["from": "p"])
    XCTAssertNil(mac.clockOff)
    // A message from before the receiver started is old, not off.
    let then = Date().addingTimeInterval(-30)
    let early = ChannelSeal(key, topic, clock: { then })
    let late = ChannelSeal(key, topic, clock: { Date() })
    XCTAssertNil(late.open("hello", early.seal("hello", [:])))
    XCTAssertNil(late.clockOff)
  }
}

/// supabase_server.dart's Realtime: PROTOCOL.md's frames in Phoenix's.
final class RealtimeLiveTests: XCTestCase {
  func testFramesBothWays() async throws {
    let rechecks = Locked(0)
    let token = LiveToken(token: "jwt-1", expires: Date().addingTimeInterval(600), apikey: "pk")
    let sent = Locked<[JSONObject]>([])
    let rt = RealtimeLive(
      nil, nil, token, send: { frame in sent.with { $0.append(JSON.tryParse(frame)!.object!) } },
      recheck: { rechecks.with { $0 += 1 } }, renewToken: { token })
    var frames = rt.frames.makeAsyncIterator()

    rt.add(#"{"t":"join","topic":"abcd1234"}"#)
    var join = sent.get.last!
    XCTAssertEqual(join["topic"], "realtime:abcd1234")
    XCTAssertEqual(join["event"], "phx_join")
    XCTAssertEqual(join["payload"]?["access_token"], "jwt-1")
    XCTAssertEqual(join["payload"]?["config"]?["private"], true)
    XCTAssertEqual(join["ref"], join["join_ref"])

    // Sending before the join is answered: not joined.
    rt.add(#"{"t":"send","topic":"abcd1234","event":"hello","payload":{"v":1}}"#)
    let notJoined = await frames.next()!
    XCTAssertEqual(JSON.tryParse(notJoined)?["error"], "not_joined")

    rt.receive(JSON.object(["topic": "realtime:abcd1234", "event": "phx_reply", "ref": join["ref"]!, "payload": ["status": "ok"]]).encoded())
    let joined = await frames.next()!
    XCTAssertEqual(JSON.tryParse(joined), ["t": "joined", "topic": "abcd1234"])

    rt.add(#"{"t":"send","topic":"abcd1234","event":"hello","payload":{"v":1}}"#)
    let broadcast = sent.get.last!
    XCTAssertEqual(broadcast["event"], "broadcast")
    XCTAssertEqual(broadcast["payload"], ["type": "broadcast", "event": "hello", "payload": ["v": 1]])
    XCTAssertEqual(broadcast["join_ref"], join["ref"])

    rt.receive(#"{"topic":"realtime:abcd1234","event":"broadcast","ref":null,"payload":{"type":"broadcast","event":"state","payload":{"v":1,"n":"x","c":"y"}}}"#)
    let msg = await frames.next()!
    XCTAssertEqual(
      JSON.tryParse(msg), ["t": "msg", "topic": "abcd1234", "event": "state", "payload": ["v": 1, "n": "x", "c": "y"]])

    // A broadcast on a topic not joined is not this device's.
    rt.receive(#"{"topic":"realtime:zzzz9999","event":"broadcast","payload":{"event":"state","payload":{}}}"#)

    rt.add(#"{"t":"ping"}"#)
    let beat = sent.get.last!
    XCTAssertEqual(beat["topic"], "phoenix")
    XCTAssertEqual(beat["event"], "heartbeat")
    rt.receive(JSON.object(["topic": "phoenix", "event": "phx_reply", "ref": beat["ref"]!, "payload": ["status": "ok"]]).encoded())
    let pong = await frames.next()!
    XCTAssertEqual(JSON.tryParse(pong), ["t": "pong"])

    // Someone was signed out: asks whether it was this device.
    rt.receive(#"{"topic":"realtime:abcd1234","event":"broadcast","payload":{"event":"pt.left","payload":{}}}"#)
    for _ in 0..<50 where rechecks.get == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(rechecks.get, 1)

    rt.add(#"{"t":"leave","topic":"abcd1234"}"#)
    XCTAssertEqual(sent.get.last?["event"], "phx_leave")

    // A refused join closes it after asking the server.
    rt.add(#"{"t":"join","topic":"abcd1234"}"#)
    join = sent.get.last!
    rt.receive(JSON.object(["topic": "realtime:abcd1234", "event": "phx_reply", "ref": join["ref"]!, "payload": ["status": "error", "response": ["reason": "unauthorized"]]]).encoded())
    let end = await frames.next()
    XCTAssertNil(end, "closed")
    XCTAssertGreaterThanOrEqual(rechecks.get, 1)
  }

  func testRefusedRenewalClosesWith4003() async throws {
    let token = LiveToken(token: "jwt-1", expires: Date(), apikey: "pk")
    let rt = RealtimeLive(
      nil, nil, token, send: { _ in }, recheck: {},
      renewToken: { throw ServerException(401, "unauthorized", "Signed out.") })
    // The first renewal waits at least 10 s; ask now.
    rt.add(#"{"t":"join","topic":"abcd1234"}"#)
    await rt.renewForTests()
    XCTAssertEqual(rt.closeCode, 4003)
  }
}
