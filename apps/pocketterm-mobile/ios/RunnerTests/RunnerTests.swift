import XCTest

@testable import Runner

final class RunnerTests: XCTestCase {
  /// The tags pocketterm_core's e2e_test pins for the computer's side: a push names its computer only by this, and
  /// the iPhone must pick the same key the computer sealed with.
  func testPushTagPicksTheKeyOfTheComputerThatSealedIt() {
    let seven = Data(repeating: 7, count: 32)
    let nine = Data(repeating: 9, count: 32)
    XCTAssertEqual(PocketTermShared.pushTag(seven), "RJM0r7AxRLM")
    XCTAssertEqual(PocketTermShared.pushTag(nine), "xx8kW7GbrvA")
    let keys = ["abcd1234": seven, "zzzz9999": nine]
    XCTAssertEqual(PocketTermShared.computer(tagged: "xx8kW7GbrvA", in: keys)?.desktop, "zzzz9999")
    XCTAssertEqual(PocketTermShared.computer(tagged: "RJM0r7AxRLM", in: keys)?.key, seven)
    XCTAssertNil(PocketTermShared.computer(tagged: "RJM0r7AxRLM", in: ["zzzz9999": nine]), "a computer never scanned")
  }

  /// A Live Activity's pushes carry only its state; which session a tap opens comes from what the phone set when it
  /// started the activity.
  func testLiveActivityTapOpensTheSessionThePhoneSetLocally() throws {
    let activity = SessionActivity(key: "abcd1234/kitty-1/2", title: "Fix it", project: "app")
    let link = try XCTUnwrap(URLComponents(url: activity.link, resolvingAgainstBaseURL: false))
    XCTAssertEqual(link.scheme, "pocketterm")
    XCTAssertEqual(link.host, "session")
    XCTAssertEqual(link.queryItems, [URLQueryItem(name: "key", value: "abcd1234/kitty-1/2")])

    let pushed = try JSONEncoder().encode(
      SessionActivity.ContentState(state: .needs, since: 1_700_000_000, kind: .approval))
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: pushed) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), ["state", "since", "kind"], "no session key or computer id in what a push sets")
  }
}
