#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

/// `wezterm cli list --format json` of WezTerm 20240203 on a Mac, its pane in
/// `sp ace'q 漢字 100%` (a `%` the shell's report left unescaped).
private let list = #"""
  [{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"bash\u0007\u001b[31mx","tab_title":"",
  "cwd":"file:///private/tmp/ptw/sp%20ace'q%20%E6%BC%A2%E5%AD%97%20100%","is_active":true,"tty_name":"/dev/ttys014"}]
  """#

final class WezTermTests: XCTestCase {
  private var dir = ""

  override func setUp() { dir = realPathOf(FileManager.default.temporaryDirectoryForTests("ptw")) }
  override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

  /// A WezTerm whose `wezterm` runs `script` (each run's last argument
  /// appended to `log`, RS after it), and a GUI socket for pid 1.
  private func fake(_ script: String) -> WezTerm {
    let exe = "\(dir)/wezterm"
    writeScript(exe, "for a; do last=\"$a\"; done\nprintf '%s\\036' \"$last\" >> \(dir)/log\n\(script)")
    FileManager.default.createFile(atPath: "\(dir)/gui-sock-1", contents: Data())
    return WezTerm(executable: exe, socketDir: dir)
  }

  private func runs() -> [String] {
    guard let log = try? String(contentsOfFile: "\(dir)/log", encoding: .utf8) else { return [] }
    return Array(log.components(separatedBy: "\u{1e}").dropLast())
  }

  private func says(
    _ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("no error", file: file, line: line)
    } catch let e as TerminalException {
      XCTAssertEqual(e.message, message, file: file, line: line)
    } catch {
      XCTFail("\(error)", file: file, line: line)
    }
  }

  func testAPaneWezTermNoLongerHasReadsAsGone() async {
    let w = fake(
      #"echo '03:33:56.758  ERROR  wezterm > unexpected response Ok(ErrorResponse(ErrorResponse { reason: "Error: no such pane 99" })); terminating' >&2; exit 1"#
    )
    await says("That window is gone.") { try await w.type("wezterm:1/99", "x") }
    await says("That window is gone.") { try await w.close("wezterm:1/99") }
  }

  func testAGUIThatQuitAndLeftItsSocketSaysWezTermIsNotRunning() async {
    let w = fake(
      #"echo '03:18:43.546  ERROR  wezterm > failed to connect to Socket("/x/gui-sock-1"): connecting to /x/gui-sock-1; terminating' >&2; exit 1"#
    )
    await says("WezTerm isn't running.") { _ = try await w.plainScreen("wezterm:1/0") }
  }

  func testAnotherErrorSaysWhatTheGUIGaveAsItsReason() async {
    let w = fake(
      #"echo '03:33:56.823  ERROR  wezterm > unexpected response Ok(ErrorResponse(ErrorResponse { reason: "Error: window_id 99 not found on this server" })); terminating' >&2; exit 1"#
    )
    await says("WezTerm: window_id 99 not found on this server") { _ = try await w.plainScreen("wezterm:1/0") }
  }

  func testACommandTooNewForThisWezTermSaysItIsTooOld() async {
    let w = fake(#"echo "error: unrecognized subcommand 'kill-pane'" >&2; exit 2"#)
    await says(WezTerm.tooOld) { try await w.close("wezterm:1/0") }
    await says(WezTerm.tooOld) { try await w.close("wezterm:1/0") }
    XCTAssertEqual(runs().count, 2)
  }

  func testOutputThatIsntUtf8ReadsWithReplacementCharacters() async throws {
    let w = fake(#"printf 'a\377b'"#)
    let screen = try await w.plainScreen("wezterm:1/0")
    XCTAssertEqual(screen, "a\u{FFFD}b")
  }

  func testLongTextGoesInPiecesACommandLineTakesInOrder() async throws {
    let w = fake("exit 0")
    let text = (0..<3000).map { "é漢👍\"'$x\($0) " }.joined()
    try await w.type("wezterm:1/0", text)
    let sent = runs()
    XCTAssertGreaterThan(sent.count, 1)
    for s in sent { XCTAssertLessThanOrEqual(s.utf8.count, WezTerm.typeBytes) }
    XCTAssertEqual(sent.joined(), text)
  }

  func testAFolderInThePaneListPercentEscapesDecodedABarePercentKeptATitleWithoutEscapes() {
    let panes = parseWezTermList("1", list)
    XCTAssertEqual(panes.count, 1)
    let w = panes[0]
    XCTAssertEqual(w.cwd, "/private/tmp/ptw/sp ace'q 漢字 100%")
    XCTAssertEqual(w.title, "bashx")
    XCTAssertEqual(w.osWindow, "wezterm:1/w0")
    XCTAssertEqual(w.tabId, "wezterm:1/t0")
  }

  func testWeztermReleaseTheDateOfAReleaseOrNightlyNilWhenItTellsNone() {
    XCTAssertEqual(weztermRelease("wezterm 20240203-110809-5046fc22"), 20_240_203)
    XCTAssertNil(weztermRelease("wezterm 0.0.0"))
  }

  // ------------------------------------------------------------ a new session

  /// A WezTerm (GUI pid 1) with windows 0 and 3 whose `spawn` makes pane 9
  /// and writes its arguments to `spawned`.
  private func two() -> WezTerm {
    fake(
      // Its arguments: cli --no-auto-start <command> ...
      "case \"$1 $3\" in\n"
        + "\"cli list\") echo '[{\"window_id\":0,\"tab_id\":0,\"pane_id\":0},{\"window_id\":3,\"tab_id\":4,\"pane_id\":5}]';;\n"
        + "\"cli spawn\") shift 3; echo \"$*\" > \(dir)/spawned; echo 9;;\n"
        + "esac")
  }

  private func spawned() -> String {
    ((try? String(contentsOfFile: "\(dir)/spawned", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func testAskedIntoAWindowATabInIt() async throws {
    let key = try await two().launch(dir, command: nil, into: "wezterm:1/w3")
    XCTAssertEqual(key, "wezterm:1/9")
    XCTAssertEqual(spawned(), "--window-id 3 --cwd \(dir)")
  }

  func testAskedIntoAWindowThatIsGoneOrOfAGUIThatIsANewWindow() async throws {
    for into in ["wezterm:1/w7", "wezterm:2/w3"] {
      let key = try await two().launch(dir, command: nil, into: into)
      XCTAssertEqual(key, "wezterm:1/9")
      XCTAssertEqual(spawned(), "--new-window --cwd \(dir)")
    }
  }

  func testAskedIntoNoWindowANewWindowEvenWithWindowsOpen() async throws {
    let key = try await two().launch(dir, command: ["omp"], into: nil)
    XCTAssertEqual(key, "wezterm:1/9")
    XCTAssertEqual(spawned(), "--new-window --cwd \(dir) -- omp")
  }
}
#endif
