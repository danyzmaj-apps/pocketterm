import XCTest

@testable import PocketTerm

final class WindowRouteTests: XCTestCase {
  // Settings is the window only once this computer is signed in and its checklist is done or skipped.
  @MainActor func testSettingsOnlyWhenSignedInAndReady() {
    XCTAssertEqual(WindowRoute.of(backend: false, signedIn: false, getReadyDone: true), .setup)
    XCTAssertEqual(WindowRoute.of(backend: true, signedIn: false, getReadyDone: true), .setup)
    XCTAssertEqual(WindowRoute.of(backend: true, signedIn: true, getReadyDone: false), .setup)
    XCTAssertEqual(WindowRoute.of(backend: true, signedIn: true, getReadyDone: true), .settings)
  }
}
