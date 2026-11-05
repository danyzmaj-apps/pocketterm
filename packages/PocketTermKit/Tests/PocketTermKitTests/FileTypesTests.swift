import XCTest

@testable import PocketTermKit

final class FileTypesTests: XCTestCase {
  func testVectorByName() {
    let cases = Vectors.cases("fileTypes", "byName")
    XCTAssertEqual(cases.count, 48)
    for v in cases {
      let name = v["name"]!.string!
      XCTAssertEqual(fileExtension(name), v["extension"]?.string, name)
      XCTAssertEqual(fileMime(name), v["mime"]?.string, name)
    }
  }

  func testVectorExtensionOf() {
    let cases = Vectors.cases("fileTypes", "extensionOf")
    XCTAssertEqual(cases.count, 10)
    for v in cases {
      let mime = v["mime"]!.string!
      XCTAssertEqual(mimeExtension(mime), v["extension"]?.string, mime)
    }
  }
}
