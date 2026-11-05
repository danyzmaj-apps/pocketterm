import XCTest

@testable import PocketTermKit

final class SpeechTests: XCTestCase {
  func testAutoTriesThePhoneLanguagesItKnowsInOrderThenEnglish() {
    let en = SpeechLanguage.english
    let hr = SpeechLanguage.croatian
    XCTAssertEqual(SpeechLanguage.byLocales(["hr-HR", "en-US"]), [hr, en])
    XCTAssertEqual(SpeechLanguage.byLocales(["en_GB", "hr"]), [en, hr])
    XCTAssertEqual(SpeechLanguage.byLocales(["de", "hr"]), [hr, en])
    XCTAssertEqual(SpeechLanguage.byLocales(["de", "sl"]), [en])
    XCTAssertEqual(SpeechLanguage.byLocales([]), [en])
    XCTAssertEqual(SpeechLanguage.byLocales(["hr", "hr-HR"]), [hr, en])
  }

  func testChecks() {
    XCTAssertTrue(SpeechCheck(.ready).ready)
    XCTAssertTrue(SpeechCheck(.unavailable).unsupported)
    XCTAssertTrue(SpeechCheck(.noLanguage).unsupported)
    XCTAssertFalse(SpeechCheck(.noLanguage, fix: .download).unsupported)
    XCTAssertEqual(SpeechCheck(json: ["status": "denied", "fix": "appSettings"]), SpeechCheck(.denied, fix: .appSettings))
    XCTAssertEqual(SpeechCheck(json: ["status": "nope", "fix": "nope"]), SpeechCheck(.unavailable))
  }

  func testEventsAsTheRecognizersReportThem() {
    XCTAssertEqual(SpeechEvent(json: ["type": "heard", "text": "hi"]), .heard("hi"))
    XCTAssertEqual(SpeechEvent(json: ["type": "heard"]), .heard(""))
    XCTAssertEqual(SpeechEvent(json: ["type": "level", "level": 2]), .level(1))
    XCTAssertEqual(SpeechEvent(json: ["type": "level", "level": 0.25]), .level(0.25))
    XCTAssertEqual(
      SpeechEvent(json: ["type": "ended", "why": "error", "message": "no", "status": "noLanguage"]),
      .ended(SpeechEnded(.error, message: "no", status: .noLanguage)))
    XCTAssertEqual(SpeechEvent(json: ["type": "ended", "why": "stopped"]), .ended(SpeechEnded(.stopped)))
    XCTAssertEqual(SpeechEvent(json: [:]), .ended(SpeechEnded(.error)))
  }
}
