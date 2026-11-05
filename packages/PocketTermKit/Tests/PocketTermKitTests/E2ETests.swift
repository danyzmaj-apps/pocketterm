import Foundation
import XCTest

@testable import PocketTermKit

/// A clock a test moves by hand.
final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ start: Date) { value = start }
  var now: Date {
    get { lock.lock(); defer { lock.unlock() }; return value }
    set { lock.lock(); value = newValue; lock.unlock() }
  }
  func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
  var read: @Sendable () -> Date { { [unowned self] in self.now } }
}

final class E2EVectorTests: XCTestCase {
  let crypto = Vectors.section("crypto")

  func key(_ name: String?) -> ChannelKey {
    ChannelKey(Vectors.hex(crypto["keys"]![name ?? "key"]!["hex"]!.string!))!
  }

  func testConstants() {
    let c = crypto["constants"]!
    XCTAssertEqual(c["nonceLength"]?.int, nonceLength)
    XCTAssertEqual(c["tagLength"]?.int, tagLength)
    XCTAssertEqual(c["sealedOverhead"]?.int, sealedOverhead)
    XCTAssertEqual(c["envelopeVersion"]?.int, envelopeVersion)
    XCTAssertEqual(c["keyLength"]?.int, ChannelKey.length)
  }

  func testKeysSpellings() {
    for (name, k) in crypto["keys"]!.object! {
      let key = key(name)
      XCTAssertEqual(key.toBase64(), k["base64"]?.string, name)
      XCTAssertEqual(key.toBase64Url(), k["base64url"]?.string, name)
      XCTAssertEqual(ChannelKey.tryParse(k["base64"]?.string), key, name)
      XCTAssertEqual(ChannelKey.tryParse(k["base64url"]?.string), key, name)
    }
  }

  func testKeyParse() {
    let cases = Vectors.cases("crypto", "keyParse")
    XCTAssertFalse(cases.isEmpty)
    for c in cases {
      XCTAssertEqual(ChannelKey.tryParse(c["input"]?.string)?.bytes.hexString, c["hex"]?.string, c["note"]!.string!)
    }
  }

  func testAad() {
    for c in Vectors.cases("crypto", "aad") {
      let args = c["args"]!.strings!
      let aad: String
      switch c["fn"]!.string! {
      case "channel": aad = channelAad(args[0], args[1])
      case "image": aad = imageAad(args[0])
      case "push": aad = pushAad(args[0])
      case "activity": aad = activityAad(args[0])
      default: return XCTFail("unknown fn")
      }
      XCTAssertEqual(aad, c["aad"]?.string, c["note"]!.string!)
    }
  }

  func testTags() {
    for c in Vectors.cases("crypto", "pushTag") {
      XCTAssertEqual(pushTag(key(c["key"]?.string)), c["tag"]?.string)
    }
    for c in Vectors.cases("crypto", "sessionTag") {
      XCTAssertEqual(sessionTag(key(c["key"]?.string), c["routedKey"]!.string!), c["tag"]?.string)
    }
  }

  func testOpen() {
    for c in Vectors.cases("crypto", "open") {
      let plain = openBytes(key(c["key"]?.string), Vectors.bytes(c["sealed"]), c["aad"]!.string!)
      XCTAssertEqual(plain, Vectors.bytes(c["plain"]), c["note"]!.string!)
    }
  }

  func testSealFixedNonce() {
    for c in Vectors.cases("crypto", "sealFixedNonce") {
      let sealed = sealBytes(
        key(c["key"]?.string), Vectors.bytes(c["plain"]), c["aad"]!.string!, nonce: Vectors.bytes(c["nonce"]))
      XCTAssertEqual(sealed, Vectors.bytes(c["sealed"]), c["note"]!.string!)
    }
  }

  func testOpenFails() {
    for c in Vectors.cases("crypto", "openFails") {
      let plain = openBytes(key(c["key"]?.string), Vectors.bytes(c["sealed"]), c["aad"]!.string!)
      XCTAssertEqual(plain, c["plain"]!.isNull ? nil : Vectors.bytes(c["plain"]), c["note"]!.string!)
    }
  }

  func testEnvelopes() {
    for c in Vectors.cases("crypto", "envelopes") {
      XCTAssertEqual(c["aad"]?.string, channelAad(c["topic"]!.string!, c["event"]!.string!))
      let opened = openEnvelope(key(c["key"]?.string), c["envelope"]!.object!, c["aad"]!.string!)
      XCTAssertNil(opened.drop, c["note"]!.string!)
      XCTAssertEqual(opened.message.map(JSON.object), c["message"], c["note"]!.string!)
    }
  }

  func testEnvelopeDrops() {
    for c in Vectors.cases("crypto", "envelopeDrops") {
      let opened = openEnvelope(key(c["key"]?.string), c["envelope"]?.object ?? [:], c["aad"]!.string!)
      XCTAssertEqual(opened.drop, c["drop"]?.string, c["note"]!.string!)
      XCTAssertEqual(opened.message.map(JSON.object) ?? .null, c["message"] ?? .null, c["note"]!.string!)
    }
  }

  func testChannelOpen() {
    let rows = Vectors.cases("crypto", "channelOpen")
    let clock = TestClock(dateFromMilliseconds(rows[0]["startMs"]!.int!))
    let receiver = ChannelSeal(key("key"), "abcd1234", clock: clock.read)
    for r in rows.dropFirst() {
      clock.now = dateFromMilliseconds(r["nowMs"]!.int!)
      let payload = receiver.open(r["event"]!.string!, r["envelope"]!.object!)
      XCTAssertEqual(payload.map(JSON.object) ?? .null, r["payload"] ?? .null, r["note"]!.string!)
    }
  }

  func testNoticesAndActivities() {
    for (section, aadOf) in [("notices", pushAad), ("activities", activityAad)] as [(String, (String) -> String)] {
      for c in Vectors.cases("crypto", section) {
        let k = key(c["key"]?.string)
        let desktop = c["desktop"]!.string!
        XCTAssertEqual(aadOf(desktop), c["aad"]?.string)
        let plain = openBytes(k, Vectors.bytes(c["enc"]), c["aad"]!.string!)
        XCTAssertEqual(plain.flatMap { JSON.tryParse($0) }, c["inner"], c["note"]!.string!)
        if section == "activities" {
          XCTAssertNil(openBytes(k, Vectors.bytes(c["enc"]), pushAad(desktop)), "an activity never opens as a push")
        }
        // Sealing here opens to the input plus a ts and a 16-character id.
        let mine = section == "notices" ? sealNotice(k, desktop, c["input"]!.object!) : sealActivity(k, desktop, c["input"]!.object!)
        let inner = JSON.tryParse(openBytes(k, Data(base64Encoded: mine)!, c["aad"]!.string!)!)!.object!
        XCTAssertEqual(inner["id"]?.string?.count, 16)
        XCTAssertNotNil(inner["ts"]?.int)
        for (k2, v) in c["input"]!.object! { XCTAssertEqual(inner[k2], v) }
      }
    }
  }

  func testImages() {
    for c in Vectors.cases("crypto", "images") {
      let k = key(c["key"]?.string)
      let path = c["path"]!.string!
      XCTAssertEqual(imageAad(path), c["aad"]?.string)
      XCTAssertEqual(openBytes(k, Vectors.bytes(c["sealed"]), imageAad(path)), Vectors.bytes(c["plain"]))
      let other = openBytes(k, Vectors.bytes(c["sealed"]), imageAad(path + "x")) != nil
      XCTAssertEqual(other, c["opensWithOtherPath"]?.bool)
    }
  }

  func testReplayGuardScenarios() {
    let scenarios = Vectors.cases("replayGuard", "scenarios")
    XCTAssertFalse(scenarios.isEmpty)
    for s in scenarios {
      let clock = TestClock(dateFromMilliseconds(s["startMs"]!.int!))
      let g = ReplayGuard(
        window: TimeInterval(s["windowMs"]!.int!) / 1000, remember: TimeInterval(s["rememberMs"]!.int!) / 1000,
        maxEpochs: s["maxEpochs"]!.int!, maxIds: s["maxIds"]!.int!, clock: clock.read)
      for step in s["steps"]!.array! {
        clock.now = dateFromMilliseconds(step["nowMs"]!.int!)
        XCTAssertEqual(
          g.check(step["message"]!.object!), step["result"]?.string,
          "\(s["note"]!.string!): \(step["note"]!.string!)")
      }
    }
  }

  func testLocalApiPing() {
    for c in Vectors.cases("localApiPing") {
      XCTAssertEqual(
        pingProof(token: c["token"]!.string!, port: c["port"]!.int!, nonce: c["nonce"]!.string!), c["proof"]?.string,
        c["note"]!.string!)
      XCTAssertEqual(pingNonceAccepted(c["nonce"]!.string!), c["nonceAccepted"]?.bool, c["note"]!.string!)
    }
  }
}

/// e2e_test.dart.
final class E2ETests: XCTestCase {
  let key = ChannelKey(Data((0..<32).map { UInt8($0) }))!
  let other = ChannelKey(Data((0..<32).map { UInt8(255 - $0) }))!
  let topic = "abcd1234"

  func testSealedBytesRoundTrip() {
    let plain = Data("a photo, really".utf8)
    let sealed = sealBytes(key, plain, imageAad("u1/x"))
    XCTAssertEqual(sealed.count, 12 + plain.count + 16)
    XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("photo"))
    XCTAssertEqual(openBytes(key, sealed, imageAad("u1/x")), plain)
    XCTAssertNotEqual(sealBytes(key, Data([1, 2, 3]), pushAad(topic)), sealBytes(key, Data([1, 2, 3]), pushAad(topic)))
  }

  func testChangedBytesOpenToNothing() {
    let sealed = sealBytes(key, Data("hello there".utf8), imageAad("u1/x"))
    for i in [0, 11, 12, sealed.count - 17, sealed.count - 1] {
      var changed = sealed
      changed[i] ^= 1
      XCTAssertNil(openBytes(key, changed, imageAad("u1/x")), "byte \(i)")
    }
    XCTAssertNil(openBytes(key, sealed.prefix(27), imageAad("u1/x")))
    XCTAssertNil(openBytes(other, sealed, imageAad("u1/x")))
    XCTAssertNil(openBytes(key, sealed, imageAad("u1/y")))
    XCTAssertNil(openBytes(key, sealed, pushAad(topic)))
  }

  func testEnvelopes() {
    let env = sealEnvelope(key, ["a": 1, "b": "two"], channelAad(topic, "state"))
    XCTAssertEqual(Set(env.keys), ["v", "n", "c"])
    XCTAssertFalse(env.encoded().contains("two"))
    XCTAssertEqual(openEnvelope(key, env, channelAad(topic, "state")).message, ["a": 1, "b": "two"])
    XCTAssertEqual(openEnvelope(key, env, channelAad(topic, "run")).drop, "sealed")
    XCTAssertEqual(openEnvelope(key, env, channelAad("zzzz9999", "state")).drop, "sealed")
    var c = Data(base64Encoded: env["c"]!.string!)!
    c[0] ^= 1
    var changed = env
    changed["c"] = .string(c.base64EncodedString())
    XCTAssertEqual(openEnvelope(key, changed, channelAad(topic, "state")).drop, "sealed")
    var v2 = env
    v2["v"] = 2
    XCTAssertEqual(openEnvelope(key, v2, channelAad(topic, "state")).drop, "version")
    XCTAssertEqual(openEnvelope(key, ["windows": 3], channelAad(topic, "state")).drop, "version")
    var bad = env
    bad["n"] = "not base64!"
    XCTAssertEqual(openEnvelope(key, bad, channelAad(topic, "state")).drop, "sealed")
  }

  func testLiveChannel() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_792_670_400))
    var phone = ChannelSeal(key, topic, clock: clock.read)
    var desktop = ChannelSeal(key, topic, clock: clock.read)
    XCTAssertEqual(desktop.open("hello", phone.seal("hello", ["from": "p1"])), ["from": "p1"])
    XCTAssertEqual(phone.open("state", desktop.seal("state", ["windows": []])), ["windows": []])

    // A payload's own seq, ts, mid and ep come through untouched.
    let items: JSONObject = ["session": "s1", "epoch": "e1", "seq": 42, "ts": 7, "mid": "m", "ep": "x", "items": []]
    XCTAssertEqual(phone.open("items", desktop.seal("items", items)), items)

    // Taken once: the server replaying it gets nothing through, also 3 minutes later.
    let wire = phone.seal("run", ["id": "r1", "op": "send"])
    XCTAssertNotNil(desktop.open("run", wire))
    XCTAssertNil(desktop.open("run", wire))
    clock.advance(180)
    XCTAssertNil(desktop.open("run", wire))

    // More than 5 minutes off the clock: dropped either way.
    phone = ChannelSeal(key, topic, clock: clock.read)
    desktop = ChannelSeal(key, topic, clock: clock.read)
    let fromPhone = phone.seal("hello", ["from": "p1"])
    let fromDesktop = desktop.seal("state", ["windows": 1])
    clock.advance(301)
    XCTAssertNil(desktop.open("hello", fromPhone))
    XCTAssertNil(phone.open("state", fromDesktop))

    // Another computer's key.
    let stranger = ChannelSeal(other, topic, clock: clock.read)
    XCTAssertNil(desktop.open("hello", stranger.seal("hello", ["from": "p1"])))
  }

  func testGuardOutlivesAChannelAndStartIsRemembered() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_792_670_400))
    let phone = ChannelSeal(key, topic, clock: clock.read)
    let replayGuard = ReplayGuard(clock: clock.read)
    let first = ChannelSeal(key, topic, guard: replayGuard, clock: clock.read)
    let wire = phone.seal("run", ["id": "r1", "op": "send"])
    XCTAssertNotNil(first.open("run", wire))
    clock.advance(60)
    let next = ChannelSeal(key, topic, guard: replayGuard, clock: clock.read)
    XCTAssertNil(next.open("run", wire))
    XCTAssertEqual(next.open("run", phone.seal("run", ["id": "r2"])), ["id": "r2"])

    // Sealed before the app started: dropped; a fresh one goes through.
    let old = phone.seal("run", ["id": "r3"])
    clock.advance(30)
    let restarted = ChannelSeal(key, topic, clock: clock.read)
    XCTAssertNil(restarted.open("run", old))
    XCTAssertEqual(restarted.open("run", phone.seal("run", ["id": "r4"])), ["id": "r4"])
  }

  func testOrderAndEpochs() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_792_670_400))
    let phone = ChannelSeal(key, topic, clock: clock.read)
    let desktop = ChannelSeal(key, topic, clock: clock.read)
    let first = desktop.seal("screen", ["n": 1])
    let second = desktop.seal("screen", ["n": 2])
    let third = desktop.seal("ran", ["id": "r1"])
    XCTAssertEqual(phone.open("screen", second), ["n": 2])
    XCTAssertNil(phone.open("screen", first), "older than one already taken")
    XCTAssertNil(phone.open("screen", second), "replayed")
    XCTAssertEqual(phone.open("ran", third), ["id": "r1"])
    XCTAssertNil(phone.open("ran", third))

    let computer = ChannelSeal(key, topic, guard: ReplayGuard(clock: clock.read), clock: clock.read)
    let sender = ChannelSeal(key, topic, clock: clock.read)
    let old = sender.seal("run", ["id": "r1"])
    XCTAssertNotNil(computer.open("run", old))
    let relaunched = ChannelSeal(key, topic, clock: clock.read)
    XCTAssertEqual(computer.open("hello", relaunched.seal("hello", ["from": "p1"])), ["from": "p1"])
    XCTAssertEqual(computer.open("run", relaunched.seal("run", ["id": "r2"])), ["id": "r2"])
    XCTAssertNil(computer.open("run", old))
    XCTAssertEqual(computer.open("run", sender.seal("run", ["id": "r3"])), ["id": "r3"])

    // Without its epoch and count: dropped.
    let env = sealEnvelope(
      key, ["id": "r1", "ts": .int(millisecondsSinceEpoch(clock.now)), "mid": .string(newMessageId())],
      channelAad(topic, "run"))
    XCTAssertNil(desktop.open("run", env))
  }

  func testEpochLimit() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_792_670_400))
    let g = ReplayGuard(maxEpochs: 2, clock: clock.read)
    func msg(_ ep: String, _ seq: Int) -> JSONObject {
      ["ts": .int(millisecondsSinceEpoch(clock.now)), "mid": .string(newMessageId()), "ep": .string(ep), "seq": .int(seq)]
    }
    for ep in ["a", "b", "c"] { XCTAssertNil(g.check(msg(ep, 5))) }
    XCTAssertEqual(g.check(msg("c", 5)), "order")
    XCTAssertEqual(g.check(msg("b", 4)), "order")
    XCTAssertNil(g.check(msg("a", 1)), "forgotten")
  }

  func testClockOff() {
    let clock = TestClock(Date(timeIntervalSince1970: 1_792_670_400))
    let phone = ChannelSeal(key, topic, clock: clock.read)
    let ahead = TestClock(clock.now.addingTimeInterval(600))
    let desktop = ChannelSeal(key, topic, clock: ahead.read)
    XCTAssertNil(phone.open("state", desktop.seal("state", [:])))
    XCTAssertEqual(phone.clockOff ?? 0, 600, accuracy: 0.01)
    let inTime = ChannelSeal(key, topic, clock: clock.read)
    XCTAssertNotNil(phone.open("state", inTime.seal("state", [:])))
    XCTAssertNil(phone.clockOff)
  }

  func testPushes() {
    let before = millisecondsSinceEpoch(Date())
    let a = sealNotice(key, topic, ["title": "Claude", "body": "Needs approval"])
    let b = sealNotice(key, topic, ["title": "Claude", "body": "Needs approval"])
    let opened = JSON.tryParse(openBytes(key, Data(base64Encoded: a)!, pushAad(topic))!)!
    let again = JSON.tryParse(openBytes(key, Data(base64Encoded: b)!, pushAad(topic))!)!
    XCTAssertEqual(opened["title"], "Claude")
    XCTAssertGreaterThanOrEqual(opened["ts"]!.int!, before)
    XCTAssertNotEqual(opened["id"], again["id"])
    XCTAssertNil(openBytes(key, Data(base64Encoded: a)!, pushAad("zzzz9999")))
    let activity = sealActivity(key, topic, ["session": "s1", "state": "working"])
    XCTAssertNil(openBytes(key, Data(base64Encoded: activity)!, pushAad(topic)))
    XCTAssertNotNil(openBytes(key, Data(base64Encoded: activity)!, activityAad(topic)))
  }

  func testKeySpellings() {
    XCTAssertEqual(ChannelKey.tryParse(key.toBase64()), key)
    XCTAssertEqual(ChannelKey.tryParse(key.toBase64Url()), key)
    XCTAssertFalse(key.toBase64Url().contains("="))
    XCTAssertNil(ChannelKey.tryParse(Data(repeating: 1, count: 16).base64EncodedString()))
    XCTAssertNil(ChannelKey.tryParse("not a key"))
    XCTAssertNil(ChannelKey.tryParse(nil))
    XCTAssertNotEqual(ChannelKey.generate(), ChannelKey.generate())
    XCTAssertEqual(newMessageId().count, 16)
  }
}

/// JSON.swift: what Dart's jsonDecode / jsonEncode do.
final class JSONTests: XCTestCase {
  func testIntsStayInts() throws {
    XCTAssertEqual(try JSON.parse("1"), .int(1))
    XCTAssertEqual(try JSON.parse("1.0"), .double(1))
    XCTAssertEqual(try JSON.parse("1e3"), .double(1000))
    XCTAssertEqual(try JSON.parse("-0"), .int(0))
    XCTAssertNil(JSON.tryParse("[1,]"))
    XCTAssertNil(JSON.tryParse("{\"a\":1} x"))
    XCTAssertEqual(try JSON.parse(#"" \u00e9\ud83d\ude00\n""#), .string(" é😀\n"))
  }

  func testEncodesAsDart() {
    XCTAssertEqual(JSON.object(["b": 1, "a": [true, nil, 1.5, "x/\u{1}\"\\é"]]).encoded(), #"{"a":[true,null,1.5,"x/\u0001\"\\é"],"b":1}"#)
    XCTAssertEqual(JSON.double(2).encoded(), "2.0")
  }
}
