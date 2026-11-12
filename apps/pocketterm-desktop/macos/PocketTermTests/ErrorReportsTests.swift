import Sentry
import XCTest

@testable import PocketTerm

final class ErrorReportsTests: XCTestCase {
  // What leaves the Mac: scrubbed texts, no person, machine name or home path; the exception's type and frames stay.
  func testEventLeavesWithoutWhoOrWhere() {
    let event = Event(level: .error)
    event.message = SentryMessage(formatted: "relay wss://dan-mbp.tail1.ts.net failed for dan@example.com")
    let exception = Exception(value: "can't open /Users/dan/.pocketterm/data from 100.64.0.7", type: "POSIXError")
    let frame = Frame()
    frame.package = "/Users/dan/Downloads/PocketTerm.app/Contents/MacOS/PocketTerm"
    frame.function = "BuiltInServer.start()"
    exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
    event.exceptions = [exception]
    let image = DebugMeta()
    image.codeFile = frame.package
    event.debugMeta = [image]
    event.serverName = "dan-mbp"
    event.user = User(userId: "dan")
    event.extra = ["cwd": "/Users/dan/code"]
    event.context = ["device": ["name": "Dan's MacBook Pro", "model": "Mac15,3"]]

    let sent = ErrorReports.scrub(event, home: "/Users/dan")

    XCTAssertEqual(sent.message?.formatted, "relay wss://<redacted> failed for <email>")
    XCTAssertEqual(sent.exceptions?.first?.value, "can't open ~/.pocketterm/data from <ip>")
    XCTAssertEqual(sent.exceptions?.first?.type, "POSIXError")
    XCTAssertEqual(sent.exceptions?.first?.stacktrace?.frames.first?.function, "BuiltInServer.start()")
    XCTAssertEqual(
      sent.exceptions?.first?.stacktrace?.frames.first?.package, "~/Downloads/PocketTerm.app/Contents/MacOS/PocketTerm")
    XCTAssertEqual(sent.debugMeta?.first?.codeFile, "~/Downloads/PocketTerm.app/Contents/MacOS/PocketTerm")
    XCTAssertNil(sent.serverName)
    XCTAssertNil(sent.user)
    XCTAssertNil(sent.extra)
    XCTAssertNil(sent.context?["device"]?["name"])
    XCTAssertEqual(sent.context?["device"]?["model"] as? String, "Mac15,3")
  }
}
