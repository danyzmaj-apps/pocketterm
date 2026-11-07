import Foundation
import XCTest

@testable import PocketTermKit

final class BackendVectorTests: XCTestCase {
  func testParse() {
    let cases = Vectors.cases("links", "parse")
    XCTAssertFalse(cases.isEmpty)
    for c in cases {
      let note = c["note"]!.string!
      // Every case left is a PocketTerm server's: its `kind` says so.
      XCTAssertEqual(c["kind"]?.string ?? "pocketterm", "pocketterm", note)
      let r = Backend.parse(c["input"]!.string!)
      XCTAssertEqual(r.error, c["error"]?.string, note)
      if let b = c["backend"]?.object {
        let backend = try! XCTUnwrap(r.backend, note)
        XCTAssertEqual(backend.url, b["url"]?.string, note)
        XCTAssertEqual(backend.api, b["api"]?.string, note)
        XCTAssertEqual(backend.host, b["host"]?.string, note)
        XCTAssertEqual(backend.onTailnet, b["onTailnet"]?.bool, note)
        XCTAssertEqual(backend.unreachable, b["unreachable"]?.string, note)
      } else {
        XCTAssertNil(r.backend, note)
      }
    }
  }

  func backend(_ j: JSON) -> Backend {
    Backend(url: j["url"]!.string!)
  }

  func testBuild() {
    for c in Vectors.cases("links", "build") {
      let b = backend(c["backend"]!)
      let link: URL
      switch c["fn"]!.string! {
      case "link": link = b.link
      case "linkWithSetup": link = b.linkWithSetup(c["setup"]!.string!)
      case "linkWithCode":
        let computer = c["computer"]?.object.map {
          ComputerKey(desktop: $0["desktop"]!.string!, key: ChannelKey(Vectors.hex($0["keyHex"]!.string!))!)
        }
        link = b.linkWithCode(c["code"]!.string!, computer: computer)
      default: return XCTFail("unknown fn")
      }
      XCTAssertEqual(link.absoluteString, c["link"]?.string, c["note"]!.string!)
    }
  }

  func testRead() {
    for c in Vectors.cases("links", "read") {
      let note = c["note"]!.string!
      let link = c["link"]!.string!
      let b = Backend.fromLink(link)
      if let want = c["backend"], !want.isNull {
        XCTAssertEqual(b, backend(want), note)
      } else {
        XCTAssertNil(b, note)
      }
      XCTAssertEqual(Backend.pairingCode(link), c["pairingCode"]?.string, note)
      XCTAssertEqual(Backend.setupToken(link), c["setupToken"]?.string, note)
      let key = Backend.computerKey(link)
      if let want = c["computerKey"]?.object {
        XCTAssertEqual(key?.desktop, want["desktop"]?.string, note)
        XCTAssertEqual(key?.key.bytes.hexString, want["keyHex"]?.string, note)
      } else {
        XCTAssertNil(key, note)
      }
      // As a URL too, where Foundation takes it as one.
      if let url = URL(string: link) { XCTAssertEqual(Backend.fromLink(url), b, note) }
    }
  }

  func testClockWarning() {
    for c in Vectors.cases("links", "clockWarning") {
      let offset = c["offsetSeconds"]?.number
      XCTAssertEqual(Backend.clockWarning(offset), c["warning"]?.string, c["note"]!.string!)
    }
  }

  func testConstants() {
    let c = Vectors.section("links")["constants"]!
    XCTAssertEqual(c["protocol"]?.int, Backend.protocol)
    XCTAssertEqual(c["minServer"]?.string, Backend.minServer)
    XCTAssertEqual(c["clockToleranceSeconds"]?.number, Backend.clockTolerance)
  }
}

/// backend_test.dart.
final class BackendTests: XCTestCase {
  func testSupabaseLinksAreNone() {
    // What a Supabase project's computer showed before: this app no longer speaks it.
    for link in [
      "pocketterm://setup?kind=supabase&url=https%3A%2F%2Fabcdefghijklmnop.supabase.co",
      "pocketterm://setup?kind=supabase&url=https%3A%2F%2Fabcdefghijklmnop.supabase.co&code=ABCD-1234",
    ] {
      XCTAssertNil(Backend.fromLink(link), link)
      XCTAssertNil(Backend.pairingCode(link), link)
    }
  }

  func testOlderThan() {
    XCTAssertTrue(Backend.olderThan("0.0.9", "0.1.0"))
    XCTAssertFalse(Backend.olderThan("0.10.0", "0.1.0"))
    XCTAssertFalse(Backend.olderThan("0.1.0-beta", "0.1.0"))
    XCTAssertFalse(Backend.olderThan("0.1.0", "0.1.0"))
  }

  /// A server on a free port that answers every request with [reply].
  func answering(_ reply: @escaping @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Reply) throws -> Backend {
    let server = try TestHTTPServer(reply)
    addTeardownBlock { server.stop() }
    return Backend(url: server.url)
  }

  func testCheckNamesWhatAnswers() async throws {
    let html = try answering { _ in .http(status: 200, headers: ["content-type": "text/html"], body: "<html>hello</html>") }
    let problem = await html.check()
    XCTAssertTrue(problem?.contains("No PocketTerm server") == true, problem ?? "nil")

    let ok = try answering { _ in .http(status: 200, body: #"{"pocketterm":1,"version":"0.1.7"}"#) }
    let fine = await ok.check()
    XCTAssertNil(fine)

    let missing = try answering { _ in .http(status: 404) }
    let none = await missing.check()
    XCTAssertEqual(none, "No PocketTerm server answers at this URL.")
  }

  func testDroppedMidAnswerIsAMessage() async throws {
    let half = try answering { _ in .raw("HTTP/1.1 200") }
    let problem = await half.check()
    XCTAssertTrue(problem?.contains("Couldn't reach") == true, problem ?? "nil")
  }

  func testStalledBodyTimesOut() async throws {
    let stall = try answering { _ in .stall("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{\"pocketterm\":") }
    let health = await stall.health(wait: 0.5)
    XCTAssertTrue(health.error?.contains("took too long to answer") == true, health.error ?? "nil")
  }

  func testClockOffIsTold() async throws {
    let time = DartDate.utcIso8601(Date().addingTimeInterval(600))
    let ahead = try answering { _ in
      .http(status: 200, body: #"{"pocketterm":1,"version":"0.1.0","time":"\#(time)"}"#)
    }
    let skewed = await ahead.health()
    XCTAssertNil(skewed.error)
    XCTAssertEqual(skewed.clockOffset ?? 0, 600, accuracy: 5)
    XCTAssertTrue(Backend.clockWarning(skewed.clockOffset)?.contains("10 minutes behind") == true)
    XCTAssertTrue(Backend.clockWarning(-180)?.contains("ahead of") == true)
    XCTAssertNil(Backend.clockWarning(90))
  }

  func testVersions() async throws {
    let old = try answering { _ in .http(status: 200, body: #"{"pocketterm":1,"version":"0.0.9"}"#) }
    let o = await old.check()
    XCTAssertTrue(o?.contains("Update PocketTerm on the computer that runs it") == true, o ?? "nil")
    let newer = try answering { _ in .http(status: 200, body: #"{"pocketterm":2}"#) }
    let n = await newer.check()
    XCTAssertTrue(n?.contains("newer than this app") == true, n ?? "nil")
  }

  func testCloudflareAndRedirectLoop() async throws {
    let cloudflare = try answering { _ in .http(status: 521, headers: ["cf-ray": "8a1b2c3d4e5f-FRA"]) }
    let c = await cloudflare.check()
    XCTAssertTrue(c?.contains("Cloudflare") == true, c ?? "nil")

    let loop = try TestHTTPServer { _ in .http(status: 301, headers: ["location": "/v1/health"]) }
    addTeardownBlock { loop.stop() }
    let l = await Backend(url: loop.url).check()
    XCTAssertTrue(l?.contains("redirecting") == true, l ?? "nil")

    let down = try answering { _ in .http(status: 502) }
    let d = await down.check()
    XCTAssertTrue(d?.contains("doesn't (502)") == true, d ?? "nil")
  }

  func testUnreachable() async {
    // Nothing listens on port 9 here.
    let problem = await Backend(url: "http://127.0.0.1:9").check()
    XCTAssertTrue(problem?.contains("Couldn't reach 127.0.0.1") == true, problem ?? "nil")
  }

  func testKeptInPreferences() {
    let prefs = MemoryPreferenceStore()
    let store = PreferencesBackendStore(prefs)
    let backend = Backend(url: "https://pt.example.com")
    XCTAssertNil(Backend.load(from: store))
    backend.save(to: store)
    XCTAssertEqual(Backend.load(from: store), backend)
    XCTAssertFalse(prefs.contains("backend_kind"))
    Backend.clear(in: store)
    XCTAssertNil(Backend.load(from: store))

    prefs.setString("backend_url", "https://abcdefghijklmnop.supabase.co")
    prefs.setString("backend_kind", "supabase")
    XCTAssertNil(Backend.load(from: store), "a Supabase project")
    backend.save(to: store)
    XCTAssertEqual(Backend.load(from: store), backend, "a server after a Supabase project is no project")

    prefs.setString("backend_url", "https://abc.supabase.co")
    prefs.setString("backend_key", "sb_x")
    XCTAssertNil(Backend.load(from: store), "a Supabase project from an app before")
  }
}
