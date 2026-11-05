import Foundation
import XCTest

@testable import PocketTermKit

/// The phone's native side, recorded.
@MainActor
final class FakeActivityHost: ActivityHost {
  var pushPlatform = "ios"
  var running: [(key: String, token: String?)] = []
  var keys: [String: String] = [:]
  var tooMany = false
  var calls: [(String, String)] = []
  var started: [(key: String, project: String)] = []

  func liveActivities() async -> [(key: String, token: String?)] { running }
  func startActivity(key: String, title: String, project: String, state: String, kind: String?, since: Date)
    async throws -> Bool
  {
    if tooMany { throw TooManyActivities() }
    calls.append(("startActivity", key))
    started.append((key, project))
    return true
  }
  func updateActivity(key: String, state: String, kind: String?, since: Date) async {
    calls.append(("updateActivity", key))
  }
  func endActivity(_ key: String, immediate: Bool) async { calls.append(("endActivity", key)) }
  func channelKeys() async -> [String: String] { keys }
}

/// live_activity_test.dart.
@MainActor
final class LiveActivityTests: XCTestCase {
  var dir: URL!

  override func setUp() async throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm_activity_\(UUID().uuidString)")
  }

  override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

  func summary(busy: Bool = false, ask: LiveAsk? = nil) -> LiveSummary {
    LiveSummary(key: "kitty-1/2", id: "s", title: "Fix it", cwd: "/x/pocketterm", epoch: "e", seq: 0, busy: busy, ask: ask)
  }

  func settle() async { for _ in 0..<30 { await Task.yield() } }

  func testStatuses() {
    let question = LiveAsk.questions("q", [LiveQuestion(id: "a", question: "Which?", options: ["A", "B"])])
    XCTAssertEqual(summaryStatus(summary(busy: true)), ActivityStatus(state: .working))
    XCTAssertEqual(summaryStatus(summary()), ActivityStatus(state: .done))
    XCTAssertEqual(summaryStatus(summary(ask: question)), ActivityStatus(state: .needs, kind: .question))
    XCTAssertEqual(summaryStatus(summary(busy: true, ask: .approval("t", tool: "bash"))), ActivityStatus(state: .needs, kind: .approval))
    XCTAssertEqual(summaryStatus(summary(busy: true, ask: .plan("p"))), ActivityStatus(state: .needs, kind: .plan))
    XCTAssertEqual(summaryStatus(nil), ActivityStatus(state: .ended))
    XCTAssertEqual(activityJson(ActivityStatus(state: .working)), ["state": "working"])
    XCTAssertEqual(activityJson(ActivityStatus(state: .needs, kind: .plan)), ["state": "needs", "kind": "plan"])
  }

  func remote(_ client: Server, sessions: [JSON]) -> TerminalRemote {
    let r = TerminalRemote(
      client, supportDir: dir, desktopId: "abcd1234", key: ChannelKey(Data(repeating: 7, count: 32))!, send: { _, _ in })
    r.handle("state", ["windows": [], "sessions": .array(sessions)])
    return r
  }

  func testNativeSideKnowsASessionWithItsComputer() async throws {
    let host = FakeActivityHost()
    host.running = [("abcd1234/kitty-1/1", nil), ("zzzz9999/kitty-1/1", nil)]
    let client = FakeServer()
    let r = remote(
      client,
      sessions: [
        ["key": "kitty-1/1", "id": "s1", "title": "Old", "cwd": "/x", "epoch": "e", "seq": 0],
        ["key": "kitty-1/2", "id": "s2", "title": "Fix it", "cwd": #"C:\Users\me\app\"#, "epoch": "e", "seq": 0],
      ])
    let a = LiveActivities(client, r, host: host)
    await settle()
    XCTAssertTrue(a.following("kitty-1/1"))

    let started = try await a.follow("kitty-1/2", title: "Fix it")
    XCTAssertTrue(started)
    XCTAssertEqual(host.started.last?.key, "abcd1234/kitty-1/2")
    XCTAssertEqual(host.started.last?.project, "app")

    a.onNative("activityEnded", key: "zzzz9999/kitty-1/1", token: nil)
    XCTAssertTrue(a.following("kitty-1/1"))
    a.onNative("activityEnded", key: "abcd1234/kitty-1/1", token: nil)
    XCTAssertFalse(a.following("kitty-1/1"))

    await a.stop("kitty-1/2")
    XCTAssertEqual(host.calls.last?.0, "endActivity")
    XCTAssertEqual(host.calls.last?.1, "abcd1234/kitty-1/2")
  }

  func testTooManyIsToldApartAndThePromptGoesAllTheSame() async throws {
    let host = FakeActivityHost()
    host.tooMany = true
    let client = FakeServer()
    let r = remote(client, sessions: [["key": "kitty-1/2", "id": "s2", "title": "Fix it", "cwd": "/x/app", "epoch": "e", "seq": 0]])
    let a = LiveActivities(client, r, host: host)
    await settle()
    do {
      try await a.follow("kitty-1/2", title: "Fix it")
      XCTFail("followed")
    } catch is TooManyActivities {}
    try await a.prompted("kitty-1/2", title: "Fix it")
    XCTAssertFalse(a.following("kitty-1/2"))
  }

  func testAndroidNamesASessionByItsTag() async throws {
    let host = FakeActivityHost()
    host.keys = ["zzzz9999": ChannelKey(Data(repeating: 9, count: 32))!.toBase64()]
    let client = FakeServer()
    let r = remote(client, sessions: [])
    let a = LiveActivities(client, r, host: host)
    await settle()
    let fcm = String(repeating: "f", count: 160)
    host.pushPlatform = "android"
    a.onNative("activityToken", key: "abcd1234/kitty-1/2", token: fcm)
    a.onNative("activityToken", key: "zzzz9999/kitty-1/2", token: fcm)
    a.onNative("activityToken", key: "qqqq0000/kitty-1/2", token: fcm)
    await settle()
    XCTAssertEqual(Set(client.pushes.map(\.0)), ["activity_register"])
    let bodies = Set(client.pushes.map { JSON.object($0.1) })
    let nine = sessionTag(ChannelKey(Data(repeating: 9, count: 32))!, "zzzz9999/kitty-1/2")
    XCTAssertEqual(
      bodies,
      [
        ["token": .string(fcm), "session": "abcd1234/kitty-1/2", "platform": "android", "ref": "yMPqtkm1TA3-r0AeuNDSHg"],
        ["token": .string(fcm), "session": "zzzz9999/kitty-1/2", "platform": "android", "ref": .string(nine)],
        // No key for that computer: nothing it sends would open.
        ["token": .string(fcm), "session": "qqqq0000/kitty-1/2", "platform": "android"],
      ])

    let before = client.pushes.count
    host.pushPlatform = "ios"
    let token = String(repeating: "ab", count: 40)
    a.onNative("activityToken", key: "abcd1234/kitty-1/2", token: token)
    await settle()
    XCTAssertEqual(client.pushes.count, before + 1)
    XCTAssertEqual(client.pushes.last?.1, ["token": .string(token), "session": "abcd1234/kitty-1/2", "platform": "ios"])
  }

  func testStateKeepsFollowedSessionsCurrent() async throws {
    let host = FakeActivityHost()
    let client = FakeServer()
    let r = remote(client, sessions: [["key": "kitty-1/2", "id": "s2", "title": "Fix it", "cwd": "/x/app", "epoch": "e", "seq": 0, "busy": true]])
    let a = LiveActivities(client, r, host: host)
    await settle()
    try await a.follow("kitty-1/2", title: "Fix it")
    r.handle("state", ["sessions": [["key": "kitty-1/2", "id": "s2", "title": "Fix it", "cwd": "/x/app", "epoch": "e", "seq": 0]]])
    await settle()
    XCTAssertEqual(host.calls.last?.0, "updateActivity", "done now")
    r.handle("state", ["sessions": []])
    await settle()
    XCTAssertEqual(host.calls.last?.0, "endActivity", "gone from the computer: ended")
    XCTAssertFalse(a.following("kitty-1/2"))
  }
}
