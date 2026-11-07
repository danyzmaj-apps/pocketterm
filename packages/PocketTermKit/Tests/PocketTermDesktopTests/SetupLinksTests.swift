#if os(macOS)
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

/// The link pasted on Join another computer's PocketTerm….
final class SetupLinksTests: XCTestCase {
  let mac = Backend(url: "https://my-mac.tail1234.ts.net")

  func testAnotherComputersTailscaleLinkSignsIn() {
    XCTAssertNil(setupLinkProblem(mac.linkWithSetup("s3cret").absoluteString))
    XCTAssertNil(setupLinkProblem("  \(mac.linkWithSetup("s3cret").absoluteString)  "))
  }

  func testOnlyATailscaleServerInReleaseBuilds() {
    let notTailscale = "This link isn't for a PocketTerm on Tailscale."
    for link in [
      Backend(url: "https://pt.example.com").linkWithSetup("s3cret").absoluteString,
      Backend(url: "http://127.0.0.1:47900").linkWithSetup("s3cret").absoluteString,
      Backend(url: "https://ts.net").linkWithSetup("s3cret").absoluteString,
      Backend(url: "https://tail1234.ts.net").linkWithSetup("s3cret").absoluteString,
      Backend(url: "https://my-mac.tail1234.ts.net:8443").linkWithSetup("s3cret").absoluteString,
      "pocketterm://setup?kind=supabase&url=https%3A%2F%2Fabcdefghijklmnop.supabase.co&setup=s3cret",
      "pocketterm://setup?url=nope&setup=s3cret",
    ] {
      XCTAssertEqual(setupLinkProblem(link), notTailscale, link)
    }
  }

  func testTestBuildsTakeAnyServer() {
    XCTAssertNil(setupLinkProblem(Backend(url: "http://127.0.0.1:47900").linkWithSetup("s").absoluteString, anyServer: true))
    XCTAssertNil(setupLinkProblem(Backend(url: "https://pt.example.com").linkWithSetup("s").absoluteString, anyServer: true))
    XCTAssertTrue(
      setupLinkProblem("pocketterm://setup?url=nope&setup=s3cret", anyServer: true)?
        .hasPrefix("The server address in that link doesn’t work.") == true)
  }

  func testAPhonesLinkOrOneWithoutATokenSaysWhatToDo() throws {
    XCTAssertTrue(try XCTUnwrap(setupLinkProblem(mac.linkWithCode("K7QM-3XRT").absoluteString)).contains("phone"))
    XCTAssertTrue(try XCTUnwrap(setupLinkProblem(mac.link.absoluteString)).contains("no setup token"))
    XCTAssertTrue(try XCTUnwrap(setupLinkProblem("https://pt.example.com")).hasPrefix("That isn’t a setup link."))
  }
}
#endif
