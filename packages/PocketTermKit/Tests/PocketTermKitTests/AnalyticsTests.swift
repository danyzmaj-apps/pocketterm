import XCTest

@testable import PocketTermKit

/// Usage statistics: off by default, only allowed names and values, nothing without a website id or once off.
@MainActor
final class AnalyticsTests: XCTestCase {
  private var sent: [[String: Any]] = []
  private var status: Int? = 200

  private let device = AnalyticsDevice(
    platform: "ios", hostname: "ios.pocketterm.app.danyzmaj.com",
    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) PocketTerm/1.0.0", screen: "402x874",
    language: "en-US", appVersion: "1.0.0")

  private func analytics(_ prefs: PreferenceStore = MemoryPreferenceStore(), websiteId: String = "site") -> Analytics {
    let device = device
    return Analytics(
      target: .of(websiteId), device: { device }, prefs: prefs,
      post: { [unowned self] url, ua, body in
        XCTAssertEqual(url.absoluteString, "https://umami.danyzmaj.com/api/send")
        XCTAssertEqual(ua, device.userAgent)
        sent.append(try! JSONSerialization.jsonObject(with: body) as! [String: Any])
        return status
      })
  }

  private func payload(_ i: Int) -> [String: Any] { sent[i]["payload"] as! [String: Any] }
  private func data(_ i: Int) -> [String: Any] { payload(i)["data"] as! [String: Any] }

  func testOffByDefaultAndRecordsNothing() async {
    let a = analytics()
    a.screen("home")
    a.event("demo_opened")
    await a.idle()
    XCTAssertFalse(a.enabled)
    XCTAssertTrue(sent.isEmpty)
  }

  func testNoWebsiteIdRecordsNothingEvenWhenOn() async {
    let prefs = MemoryPreferenceStore()
    let a = analytics(prefs, websiteId: " ")
    a.setEnabled(true)
    a.screen("home")
    a.event("demo_opened")
    await a.idle()
    XCTAssertTrue(sent.isEmpty)
    XCTAssertNil(prefs.string(Analytics.installIdKey))
  }

  func testOnlyAllowedEventsKeysAndValuesLeave() async {
    let a = analytics()
    a.setEnabled(true)
    a.screen("session")
    a.event("pairing_failed", ["method": .string("scan"), "code": .string("code_used"), "host": .string("mac.ts.net")])
    a.event("pairing_failed", ["method": .string("camera"), "code": .string("Sign-in failed: http://10.0.0.1")])
    a.event("prompt_sent", ["mode": .string("steer"), "attachments": .bool(true), "text": .string("rm -rf ~")])
    a.event("prompt_sent", ["attachments": .string("yes")])
    a.event("typed_command", ["text": .string("ls")])
    a.screen("/session/abc123")
    await a.idle()
    XCTAssertEqual(sent.count, 5)

    XCTAssertEqual(sent[0]["type"] as? String, "event")
    XCTAssertEqual(payload(0)["website"] as? String, "site")
    XCTAssertEqual(payload(0)["hostname"] as? String, "ios.pocketterm.app.danyzmaj.com")
    XCTAssertEqual(payload(0)["url"] as? String, "/session")
    XCTAssertNil(payload(0)["name"])

    XCTAssertEqual(Set(data(1).keys), ["platform", "app_version", "method", "code"])
    XCTAssertEqual(data(1)["code"] as? String, "code_used")
    XCTAssertEqual(data(1)["platform"] as? String, "ios")
    XCTAssertEqual(payload(1)["url"] as? String, "/session", "an event names the screen it happened on")
    XCTAssertEqual(Set(data(2).keys), ["platform", "app_version"], "unknown values go")
    XCTAssertEqual(data(3)["attachments"] as? Bool, true)
    XCTAssertEqual(data(3)["mode"] as? String, "steer")
    XCTAssertEqual(Set(data(4).keys), ["platform", "app_version"], "a boolean property takes no string")
  }

  func testOneRandomInstallIdUntilOffThenANewOne() async {
    let prefs = MemoryPreferenceStore()
    let a = analytics(prefs)
    a.setEnabled(true)
    a.event("demo_opened")
    a.event("demo_opened")
    await a.idle()
    let first = payload(0)["id"] as! String
    XCTAssertEqual(payload(1)["id"] as? String, first)
    XCTAssertNotNil(UUID(uuidString: first))

    a.setEnabled(false)
    XCTAssertNil(prefs.string(Analytics.installIdKey))
    a.setEnabled(true)
    a.event("demo_opened")
    await a.idle()
    XCTAssertNotEqual(payload(2)["id"] as? String, first)
  }

  func testOffDropsWhatWaitsAndSendsNothingMore() async {
    let a = analytics()
    a.setEnabled(true)
    status = 503
    a.event("demo_opened")
    await a.idle()
    a.event("notifications_set", ["on": .bool(true)])
    await a.idle()
    XCTAssertEqual(sent.count, 1, "after a failure it waits before trying again")
    XCTAssertEqual(a.queued, 2)

    a.setEnabled(false)
    XCTAssertEqual(a.queued, 0)
    status = 200
    a.flush()
    a.event("demo_opened")
    a.screen("home")
    await a.idle()
    XCTAssertEqual(sent.count, 1)
  }

  func testQueueKeepsTheNewestAndGoesOutOnFlush() async {
    let a = analytics()
    a.setEnabled(true)
    status = nil
    for _ in 0..<(Analytics.maxQueue + 20) { a.event("session_opened", ["view": .string("screen")]) }
    await a.idle()
    XCTAssertEqual(a.queued, Analytics.maxQueue)
    status = 200
    a.flush()
    await a.idle()
    XCTAssertEqual(a.queued, 0)
  }

  func testRefusedRequestIsDroppedNotRetried() async {
    let a = analytics()
    a.setEnabled(true)
    status = 400
    a.event("demo_opened")
    await a.idle()
    XCTAssertEqual(a.queued, 0)
    XCTAssertEqual(sent.count, 1)
  }

  func testTransportNamesOnlyTheKindOfAddress() {
    XCTAssertEqual(AnalyticsEvents.transport("studio.tail1234.ts.net"), "tailnet")
    XCTAssertEqual(AnalyticsEvents.transport("127.0.0.1"), "local")
    XCTAssertEqual(AnalyticsEvents.transport("pocketterm.example.com"), "other")
  }
}
