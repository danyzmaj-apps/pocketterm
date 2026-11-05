#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

@testable import PocketTermDesktop

final class PromptFilesTests: XCTestCase {
  private var dir = ""
  private var files: PromptFiles!

  override func setUp() {
    super.setUp()
    dir = hubTempDir("pocketterm_prompt_files")
    files = PromptFiles(Paths.join(dir, "pocketterm-files"))
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: dir)
    super.tearDown()
  }

  private func file(_ name: String, _ text: String, mime: String = "") -> PromptFile {
    PromptFile(name: name, mime: mime, bytes: Data(text.utf8))
  }

  private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<missing>" }

  func testFilesLandUnderTheirOwnNamesInAFolderOfTheirOwnPerPromptNothingOverwritten() async throws {
    let first = try await files.save([file("notes.txt", "one"), file("notes.txt", "two"), file("notes.txt", "three")])
    XCTAssertEqual(first.map(Paths.basename), ["notes.txt", "notes (2).txt", "notes (3).txt"])
    XCTAssertEqual(first.map(read), ["one", "two", "three"])
    XCTAssertEqual(Set(first.map(Paths.dirname)).count, 1)
    XCTAssertTrue(Paths.isWithin(files.dir, first[0]))

    let second = try await files.save([file("notes.txt", "later")])
    XCTAssertEqual(Paths.basename(second[0]), "notes.txt")
    XCTAssertNotEqual(Paths.dirname(second[0]), Paths.dirname(first[0]), "another prompt's folder")
    XCTAssertEqual(read(first[0]), "one")
  }

  func testTheFolderIsPrivateToThisUser() async throws {
    _ = try await files.save([file("a.txt", "a")])
    let mode = try FileManager.default.attributesOfItem(atPath: files.dir)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o700)
  }

  func testANameThatTriesToLeaveItsFolderStaysInIt() async throws {
    let saved = try await files.save([
      file("../../.ssh/authorized_keys", "a"), file(#"..\..\Windows\evil.bat"#, "b"), file("..", "c"),
      file("/etc/passwd", "d"), file("a\u{0000}b\nc.txt", "e"),
    ])
    for path in saved {
      XCTAssertTrue(Paths.isWithin(files.dir, path), path)
      XCTAssertEqual(Paths.dirname(Paths.dirname(path)), files.dir, path)
    }
    XCTAssertEqual(saved.map(Paths.basename), ["authorized_keys", "evil.bat", "file", "passwd", "abc.txt"])
  }

  func testSafeNamesNoCharactersWindowsRefusesNoDeviceNamesNoTrailingDotsOrSpacesLengthCapped() {
    XCTAssertEqual(safeFileName(#"re: "plan" <v2>?.md"#), "re plan v2.md")
    XCTAssertEqual(safeFileName("CON.txt"), "_CON.txt")
    XCTAssertEqual(safeFileName("report. . "), "report")
    XCTAssertEqual(safeFileName("..."), "file")
    XCTAssertEqual(safeFileName(".env"), ".env", "a hidden file keeps its name")
    XCTAssertEqual(safeFileName("scan", mime: "application/pdf"), "scan.pdf")
    XCTAssertEqual(safeFileName("scan", mime: "application/x-unknown"), "scan")
    let long = safeFileName(String(repeating: "a", count: 300) + ".pdf")
    XCTAssertEqual(long.utf16.count, 120)
    XCTAssertTrue(long.hasSuffix(".pdf"))
  }

  func testEveryNameWindowsOpensAsADeviceGetsAPrefixHoweverItIsWritten() {
    for name in [#"conin$"#, #"CONOUT$.txt"#, "COM¹.log", "lpt³", "CON .txt", "nul.tar.gz", "Aux"] {
      XCTAssertEqual(safeFileName(name), "_\(name)", name)
    }
    for name in ["console.txt", "com10.txt", "conin.txt", "lpt.md"] {
      XCTAssertEqual(safeFileName(name), name, name)
    }
  }

  func testAPromptNamesItsFilesAsOmpAndClaudeCodeTakeThemAtTheComputer() {
    XCTAssertEqual(
      withMentions("look at these", ["/tmp/pt/a1/notes.txt", "/tmp/pt/a1/my notes.txt"]),
      "look at these\n\n@/tmp/pt/a1/notes.txt @\"/tmp/pt/a1/my notes.txt\"")
    XCTAssertEqual(withMentions("  ", ["/tmp/pt/a1/x.pdf"]), "@/tmp/pt/a1/x.pdf")
    XCTAssertEqual(withMentions("just words", []), "just words")
    // A trailing dot or comma would be taken for punctuation; Windows paths have : and \.
    XCTAssertEqual(fileMention("/tmp/pt/a1/v1."), "@\"/tmp/pt/a1/v1.\"")
    XCTAssertEqual(
      fileMention(#"C:\Users\me\AppData\Local\Temp\pocketterm-files\a1\x.pdf"#),
      #"@"C:\Users\me\AppData\Local\Temp\pocketterm-files\a1\x.pdf""#)
    XCTAssertEqual(fileMention("/tmp/pt/a1/it's.txt"), "@\"/tmp/pt/a1/it's.txt\"")
    XCTAssertEqual(fileMention("/tmp/pt/é.txt"), "@\"/tmp/pt/é.txt\"", "Dart's \\w is ASCII")
  }

  func testFoldersOlderThanADayGoNewerOnesStay() async throws {
    let old = Paths.dirname(try await files.save([file("old.txt", "x")])[0])
    let fresh = Paths.dirname(try await files.save([file("new.txt", "y")])[0])
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: old)

    await files.prune()
    XCTAssertFalse(FileManager.default.fileExists(atPath: old))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
  }
}
#endif
