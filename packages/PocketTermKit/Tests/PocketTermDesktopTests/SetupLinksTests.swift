#if os(macOS)
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

/// supabase_setup_test.dart's 'a pasted setup link'.
final class SetupLinksTests: XCTestCase {
  func testASupabaseProjectsLinkIsAComputersItsPhoneLinkAndUnknownKindsSayWhatToDo() throws {
    let project = Backend(url: "https://abcdefghijklmnopqrst.supabase.co", kind: .supabase)
    XCTAssertNil(setupLinkProblem(project.linkWithSetup("s3cret").absoluteString))
    XCTAssertTrue(
      try XCTUnwrap(setupLinkProblem(project.linkWithCode("K7QM-3XRT").absoluteString)).contains("Add a computer…"))
    XCTAssertTrue(
      try XCTUnwrap(setupLinkProblem("pocketterm://setup?kind=mars&url=https%3A%2F%2Fpt.example.com&setup=s3cret"))
        .contains("Update PocketTerm"))
    XCTAssertTrue(
      try XCTUnwrap(setupLinkProblem("pocketterm://setup?kind=supabase&url=nope&setup=s3cret"))
        .hasPrefix("The server address in that link doesn’t work."))
    // A PocketTerm server's link still works, and its phone link still names the server's command.
    XCTAssertNil(setupLinkProblem(Backend(url: "https://pt.example.com").linkWithSetup("s3cret").absoluteString))
    XCTAssertTrue(
      try XCTUnwrap(setupLinkProblem("pocketterm://setup?url=https%3A%2F%2Fpt.example.com&code=K7QM-3XRT"))
        .contains("pocketterm-server setup-link"))
  }

  func testWhatIsntASetupLinkSaysSo() {
    XCTAssertEqual(
      setupLinkProblem("https://pt.example.com"),
      "That isn’t a setup link. It starts with pocketterm://setup?url= : copy the whole line setup-link printed.")
    XCTAssertEqual(
      setupLinkProblem("  pocketterm://setup?url=https%3A%2F%2Fpt.example.com  "),
      "That link has no setup token: copy the whole line setup-link printed.")
  }
}
#endif
