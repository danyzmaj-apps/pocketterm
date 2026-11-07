import XCTest

@testable import PocketTerm

/// What the scanner takes from a code (the camera's, or a pasted one in E2E builds): the Dart scan_test.dart.
nonisolated final class SetupTests: XCTestCase {
  private let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
  private var signIn: String { "pocketterm://setup?url=http://127.0.0.1:8787&code=K7QM-3XRT&d=abcd1234&k=\(key)" }

  func testAPastedSignInCodeComesBackAsAScannedOne() {
    XCTAssertEqual(ScannedCode.read(["  \(signIn) "], signedIn: false), .link(URL(string: signIn)!))
  }

  func testACodeIsHeldToWhatThisPhoneNeedsNoSignInNoKeyNotOurs() {
    XCTAssertEqual(
      ScannedCode.read(["pocketterm://setup?url=http://127.0.0.1:8787"], signedIn: false),
      .problem(ScannedCode.noSignIn))
    XCTAssertTrue(ScannedCode.noSignIn.hasPrefix("That code has no sign-in in it"))
    XCTAssertEqual(ScannedCode.read(["https://example.com"], signedIn: false), .problem(ScannedCode.notOurs))
    XCTAssertTrue(ScannedCode.notOurs.hasPrefix("That's not a PocketTerm code"))

    // A signed-in phone adding a computer needs that computer's key, not a sign-in.
    XCTAssertEqual(
      ScannedCode.read(["pocketterm://setup?url=http://127.0.0.1:8787&code=K7QM-3XRT"], signedIn: true),
      .problem(ScannedCode.noKey))
    XCTAssertTrue(ScannedCode.noKey.hasPrefix("That code has no key for a computer"))
    XCTAssertEqual(ScannedCode.read([signIn], signedIn: true), .link(URL(string: signIn)!))
  }

  func testASetupCodeCarryingAKeyIsNotAPocketTermCode() {
    XCTAssertEqual(
      ScannedCode.read(
        ["pocketterm://setup?url=https://abcd.example.com&key=pk_x&code=K7QM"], signedIn: false),
      .problem(ScannedCode.notOurs))
  }

  func testTheFirstUsableCodeOfSeveralWinsAndAPocketTermProblemOutranksAStrangeCode() {
    // The camera may see several codes at once.
    XCTAssertEqual(
      ScannedCode.read([nil, "WIFI:S:home;;", signIn], signedIn: false), .link(URL(string: signIn)!))
    XCTAssertEqual(
      ScannedCode.read(["pocketterm://setup?url=http://127.0.0.1:8787", "https://example.com"], signedIn: false),
      .problem(ScannedCode.noSignIn))
    XCTAssertEqual(ScannedCode.read([], signedIn: false), .problem(ScannedCode.notOurs))
  }
}
