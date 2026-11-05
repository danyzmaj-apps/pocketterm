import Foundation
import XCTest

@testable import PocketTermKit

@MainActor
final class DesktopsTests: XCTestCase {
  let client = FakeServer()

  func row(_ id: String, _ ago: TimeInterval, platform: String = "macos") -> JSONObject {
    [
      "id": .string(id), "name": .string("Computer \(id)"), "platform": .string(platform),
      "seen_at": .string(DartDate.utcIso8601(Date().addingTimeInterval(-ago))),
    ]
  }

  func testVectors() {
    let s = Vectors.section("desktops")
    XCTAssertEqual(s["onlineWithinSeconds"]?.number, Desktop.onlineWithin)
    XCTAssertEqual(s["keepForDays"]?.number, Desktops.keepFor / 86400)
    let cases = Vectors.cases("desktops")
    XCTAssertFalse(cases.isEmpty)
    for c in cases {
      let d = Desktop(json: c["input"]!.object!)
      XCTAssertEqual(d.map { JSON.object($0.toJson()) }, c["output"], c["note"]!.string!)
      XCTAssertEqual(d?.windows, c["windows"]?.bool, c["note"]!.string!)
    }
  }

  func testLastShownStays() {
    var changes: [String?] = []
    let d = Desktops(client, saved: "bbbbbbbb", onChanged: { _, id in changes.append(id) })
    d.apply([row("aaaaaaaa", 0), row("bbbbbbbb", 7200)])
    XCTAssertEqual(d.selected?.id, "bbbbbbbb")
    XCTAssertEqual(changes, ["bbbbbbbb"])
  }

  func testNewestWhenLastGoneAndKept() {
    let d = Desktops(client, saved: "gone0000")
    d.apply([row("aaaaaaaa", 0), row("bbbbbbbb", 60)])
    XCTAssertEqual(d.selected?.id, "aaaaaaaa")
    d.apply([row("bbbbbbbb", 0), row("aaaaaaaa", 60)])
    XCTAssertEqual(d.selected?.id, "aaaaaaaa")
  }

  func testNoneAndOld() {
    let d = Desktops(client)
    d.apply([])
    XCTAssertNil(d.selected)
    d.apply([row("aaaaaaaa", 31 * 86400)])
    XCTAssertTrue(d.all.isEmpty)
    XCTAssertNil(d.selected)
  }

  func testPicksListedOnly() {
    var changes: [String?] = []
    let d = Desktops(client, onChanged: { _, id in changes.append(id) })
    d.apply([row("aaaaaaaa", 0), row("bbbbbbbb", 0, platform: "windows")])
    d.select("bbbbbbbb")
    d.select("cccccccc")
    XCTAssertEqual(d.selected?.id, "bbbbbbbb")
    XCTAssertEqual(d.selected?.windows, true)
    XCTAssertEqual(changes, ["aaaaaaaa", "bbbbbbbb"])
  }

  func testShowOnceListed() {
    let d = Desktops(client)
    d.apply([row("aaaaaaaa", 0)])
    d.show("bbbbbbbb")
    XCTAssertEqual(d.selected?.id, "aaaaaaaa", "not listed yet")
    d.apply([row("cccccccc", 0), row("bbbbbbbb", 60)])
    XCTAssertEqual(d.selected?.id, "bbbbbbbb")
    d.apply([row("aaaaaaaa", 0), row("bbbbbbbb", 60)])
    XCTAssertEqual(d.selected?.id, "bbbbbbbb", "asked for once, then kept like any choice")
    d.show("aaaaaaaa")
    XCTAssertEqual(d.selected?.id, "aaaaaaaa")
  }

  func testCachedAndOnline() {
    let cached = Desktop(json: row("bbbbbbbb", 300))!
    let d = Desktops(client, cached: [cached], saved: "bbbbbbbb")
    XCTAssertFalse(d.loaded)
    XCTAssertEqual(d.selected, cached)
    XCTAssertEqual(Desktop(json: cached.toJson()), cached)
    XCTAssertTrue(Desktop(json: row("aaaaaaaa", 140))!.online)
    XCTAssertFalse(Desktop(json: row("aaaaaaaa", 160))!.online)
  }

  func testFailureKeepsListAndSaysWhy() async {
    let cached = Desktop(json: row("bbbbbbbb", 300))!
    let d = Desktops(client, cached: [cached], saved: "bbbbbbbb")
    var told = 0
    let sub = d.objectWillChange.sink { told += 1 }
    defer { sub.cancel() }
    client.desktopsAnswer = .failure(ServerException(0, "offline", client.backend.unreachable))
    await d.refresh()
    XCTAssertEqual(d.error, client.backend.unreachable)
    XCTAssertEqual(d.selected, cached)
    XCTAssertEqual(told, 1)
    await d.refresh()
    XCTAssertEqual(told, 1, "the same problem again is no news")
    d.apply([row("aaaaaaaa", 0)])
    XCTAssertNil(d.error)
  }

  func testListAfterDisposeIsDropped() async {
    var kept: [[Desktop]] = []
    client.desktopsAnswer = .success([row("aaaaaaaa", 0)])
    let d = Desktops(client, onChanged: { all, _ in kept.append(all) })
    d.dispose()
    await d.refresh()
    XCTAssertTrue(kept.isEmpty)
  }

  func testOfflineAnswerIsTheBackends() async {
    let tailnet = Backend(url: "https://my-mac.tail1234.ts.net")
    XCTAssertTrue(tailnet.onTailnet)
    XCTAssertTrue(tailnet.unreachable.contains("open Tailscale on this device"))
    XCTAssertFalse(Backend(url: "https://pocketterm.example.com").unreachable.contains("Tailscale"))
    let closed = PocketTermServerClient(Backend(url: "http://127.0.0.1:9"), tokens: MemoryDeviceTokens())
    do {
      _ = try await closed.redeemCode("K7QM", label: "iPhone", platform: "ios")
      XCTFail("signed in to nothing")
    } catch let e as ServerException {
      XCTAssertEqual(e.message, closed.backend.unreachable)
    } catch {
      XCTFail("\(error)")
    }
  }
}
