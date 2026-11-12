import XCTest

@testable import PocketTermKit

final class ErrorReportsTests: XCTestCase {
  func testUrlsKeepOnlyTheirScheme() {
    XCTAssertEqual(
      scrubErrorReport("connect to wss://mac.tail1234.ts.net:8443/live?k=abc failed"),
      "connect to wss://<redacted> failed")
    XCTAssertEqual(
      scrubErrorReport("GET \"https://192.168.1.4:7777/api\" -> 500"), "GET \"https://<redacted>\" -> 500")
  }

  func testAddressesHostsAndEmails() {
    XCTAssertEqual(scrubErrorReport("refused by 10.0.0.12 port 22"), "refused by <ip> port 22")
    XCTAssertEqual(scrubErrorReport("no route to fe80::1%en0"), "no route to <ip>%en0")
    XCTAssertEqual(scrubErrorReport("bind [::1]:8080"), "bind [<ip>]:8080")
    XCTAssertEqual(scrubErrorReport("peer 2001:db8:85a3:0:0:8a2e:370:7334 gone"), "peer <ip> gone")
    XCTAssertEqual(scrubErrorReport("mapped ::ffff:1.2.3.4"), "mapped <ip>")
    XCTAssertEqual(scrubErrorReport("lookup danijels-mbp.tail-ab12.ts.net"), "lookup <host>")
    XCTAssertEqual(scrubErrorReport("Bonjour Studio-Mac.local and nas.lan"), "Bonjour <host> and <host>")
    XCTAssertEqual(scrubErrorReport("signed in as dan.l+pt@example.com"), "signed in as <email>")
  }

  func testWhatIdentifiesNobodyStays() {
    let text = "Swift.DecodingError at 12:34:56: keyNotFound(\"port\") in Backend::decode, code -1001"
    XCTAssertEqual(scrubErrorReport(text), text)
  }

  func testHomeFolderBecomesTilde() {
    XCTAssertEqual(
      scrubErrorReport("can't read /Users/dan/.pocketterm/key and /Users/daniel/x", home: "/Users/dan"),
      "can't read ~/.pocketterm/key and /Users/daniel/x")
    XCTAssertEqual(scrubErrorReport("cwd /Users/dan", home: "/Users/dan"), "cwd ~")
    // A root "home" (a daemon's) would turn every path into ~.
    XCTAssertEqual(scrubErrorReport("/etc/hosts", home: "/"), "/etc/hosts")
  }

  func testCutToTheLimitAfterScrubbing() {
    let long = String(repeating: "x", count: 500)
    XCTAssertEqual(scrubErrorReport(long).count, errorReportLimit)
    // The address is replaced before the cut, so no half of it survives at the end.
    let tail = String(repeating: "y", count: 295) + " 10.0.0.1"
    XCTAssertEqual(scrubErrorReport(tail), String(repeating: "y", count: 295) + " <ip>")
  }
}
