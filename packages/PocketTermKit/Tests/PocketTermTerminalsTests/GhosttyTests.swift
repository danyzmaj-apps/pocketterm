#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

private let key = "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074"
private let uuid = String(key.dropFirst("ghostty:".count))

final class GhosttyTests: XCTestCase {
  private var app = ""
  private var osa: FakeOsascript?
  private var children: [Subprocess] = []

  override func setUp() {
    app = realPathOf(FileManager.default.temporaryDirectoryForTests("ptg"))
    children = []
  }

  override func tearDown() {
    osa?.killAll()
    for c in children { c.kill() }
    try? FileManager.default.removeItem(atPath: app)
  }

  private func ghostty(_ looks: [String], _ scripts: [String]) -> Ghostty {
    let o = FakeOsascript(looks, scripts)
    osa = o
    return Ghostty(appPath: app, appleScript: o.appleScript())
  }

  private var running: Proc {
    Proc(pid: 1, ppid: 0, pgid: 1, tpgid: -1, tty: "", stat: "S", args: "\(app)/Contents/MacOS/ghostty")
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

  func testAnAgentInASymlinkedFolderFindsTheGhosttyWindowWhoseShellNamesTheLinksPath() async throws {
    let real = "\(app)/real"
    try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(atPath: "\(app)/link", withDestinationPath: real)
    let g = ghostty(["0"], ["printf '\(uuid)\\037omp\\037\(app)/link\\037t\\037true\\037W1\\037T1\\036\\nfront\\037true'"])
    let found = await g.byFolder(realPathOf(real), Procs([running]))
    XCTAssertEqual(found, key)
  }

  func testAnAgentWhoseGhosttyWindowTellsNoFolderTheOneTitledForItsSession() async {
    let other = "ghostty:0B9E2E2E-67BF-48C7-8D0A-83F3FA5B8074"
    let shell = "ghostty:1C9E2E2E-67BF-48C7-8D0A-83F3FA5B8074"
    let records = [
      "\(uuid)\\037π > endme\\037\\037t\\037true\\037W1\\037T1",
      "\(other.dropFirst(8))\\037π > chat\\037\\037t\\037false\\037W1\\037T2",
      "\(shell.dropFirst(8))\\037zsh\\037/somewhere/else\\037t\\037false\\037W2\\037T3",
    ]
    let g = ghostty(["0"], ["printf '\(records.joined(separator: "\\036\\n"))\\036\\nfront\\037true'"])
    let procs = Procs([running])
    let found = await g.byFolder("/p/endme", procs, tty: "/dev/ttys040")
    XCTAssertEqual(found, key)
    let taken = await g.byFolder("/p/endme", procs, claimed: [key])
    XCTAssertNil(taken, "its window is taken")
    let none = await g.byFolder("/p/nothere", procs)
    XCTAssertNil(none, "no window titled for it")
  }

  func testAWindowGhosttyTellsNoFolderForHasItsProgramsWhereItsTtyIsKnown() async throws {
    let dir = "\(app)/project"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
    let sleep = try Subprocess.start("/bin/sleep", ["30"], workingDirectory: dir)
    children.append(sleep)
    let g = ghostty(["0", "0"], ["printf '\(uuid)\\037omp\\037\\037t\\037true\\037W1\\037T1\\036\\nfront\\037true'"])
    let procs = Procs([
      running,
      Proc(pid: Int(sleep.pid), ppid: 9, pgid: Int(sleep.pid), tpgid: Int(sleep.pid), tty: "ttys099", stat: "S+", args: "/bin/sleep 30"),
    ])
    let before = try await g.windows(procs)
    XCTAssertEqual(before.single?.cwd, "", "tty unknown")
    g.learn(key, "/dev/ttys099")
    let w = try await g.windows(procs).single!
    XCTAssertEqual(w.cwd, realPathOf(dir))
    XCTAssertEqual(w.program, "sleep")
    XCTAssertEqual(w.osWindow, "ghostty:wW1", "kept when its tty is known")
    XCTAssertEqual(w.tabId, "ghostty:tT1")
  }

  func testLongTextGoesInPiecesOfWhatACommandLineTakesAScriptEachInOrder() async throws {
    let g = ghostty(["0"], ["exit 0"])
    let text = (0..<9000).map { "é漢\"\\\u{1b}\($0)" }.joined()
    try await g.type(key, text)
    let argvs = osa!.argvs
    XCTAssertGreaterThan(argvs.count, 1)
    for argv in argvs {
      XCTAssertEqual(argv.first, uuid)
      XCTAssertLessThan(argv[1].utf16.count, 200_000)
    }
    XCTAssertEqual(argvs.map { String($0[1].dropFirst("text:".count)) }.joined(), ghosttyText(text))
  }

  func testANewSessionGoesIntoTheWindowItIsAskedIntoByItsIdWithNoneAskedANewWindow() async throws {
    // The script opens a tab in that window when it still has it, else a window.
    // Each launch looks for its new terminal's tty for five seconds: this fake has none.
    let g = ghostty(["0"], ["printf \(uuid)"])
    let tab = try await g.launch(app, command: nil, into: "ghostty:wW1")
    XCTAssertEqual(tab, key)
    let window = try await g.launch(app)
    XCTAssertEqual(window, key)
    XCTAssertEqual(osa!.argvs.map { "\($0[0])|\($0[2])" }, ["\(app)|W1", "\(app)|"])
  }

  func testAGhosttyThatHasQuitItsWindowsReadAsGone() async {
    let g = ghostty(["-600"], [#"echo "x.applescript:82:106: execution error: Ghostty isn't running. (-600)" >&2; exit 1"#])
    await says("That window is gone.") { try await g.type(key, "x") }
  }

  func testAutomationTurnedOffWhileInUseRefusedThenNothingMoreGoesToGhosttyAndSettingsOffersTheFix() async throws {
    let g = ghostty(
      ["0", "-1743"], [#"echo "execution error: Not authorized to send Apple events to Ghostty. (-1743)" >&2; exit 1"#])
    do {
      try await g.type(key, "x")
      XCTFail("no error")
    } catch {
      XCTAssertTrue(error is AutomationDenied, "\(error)")
    }
    XCTAssertEqual(osa!.argvs.count, 1)
    let status = try await g.status(Procs([running]))
    XCTAssertEqual(status.state, .setup)
    XCTAssertEqual(status.fix, .automation)
    XCTAssertEqual(osa!.argvs.count, 1, "refused before the script ran")
  }

  // ------------------------------------------------------------ ghostty_surface_test.dart

  private func p(_ pid: Int, _ ppid: Int, _ tty: String, _ args: String) -> Proc {
    Proc(pid: pid, ppid: ppid, pgid: pid, tpgid: pid, tty: tty, stat: "Ss", args: args)
  }

  private var base: [Proc] {
    [
      p(100, 1, "", "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
      p(200, 1, "", "/Applications/kitty.app/Contents/MacOS/kitty"),
    ]
  }

  func testGhosttysDoubleForkedSurfacesCountLoginOrALoginCommandWhoseParentIsGone() {
    let procs = Procs(
      base + [
        p(301, 300, "ttys014", "/usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l /bin/zsh"),
        p(302, 301, "ttys014", "-zsh"),
        p(311, 310, "ttys015", "-/bin/sleep 79"),
        p(321, 100, "ttys016", "/usr/bin/login -flp me"),
      ])
    XCTAssertEqual(ghosttySurfaceTtys(procs, 100), ["ttys014", "ttys015", "ttys016"])
  }

  func testAnotherTerminalsShellsAndOrphansThatArentASurfaceRootStayOut() {
    let procs = Procs(
      base + [
        // kitty's shell: its parent is there.
        p(401, 200, "ttys020", "-zsh"),
        // An orphan that isn't a login or a login command (nohup'd job).
        p(411, 410, "ttys021", "python3 server.py"),
        // Reparented to launchd.
        p(421, 1, "ttys022", "-zsh"),
      ])
    XCTAssertEqual(ghosttySurfaceTtys(procs, 100), [])
    XCTAssertEqual(ghosttySurfaceTtys(procs, nil), [])
  }

  private var launchProcs: Procs {
    Procs(base + [p(501, 500, "ttys030", "-zsh"), p(502, 501, "ttys030", "omp"), p(511, 510, "ttys031", "-zsh")])
  }

  private func folders() throws -> (tmp: String, mine: String, other: String) {
    let tmp = FileManager.default.temporaryDirectoryForTests("ghostty-launch")
    try FileManager.default.createDirectory(atPath: "\(tmp)/mine", withIntermediateDirectories: false)
    try FileManager.default.createDirectory(atPath: "\(tmp)/other", withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
    return (tmp, realPathOf("\(tmp)/mine"), realPathOf("\(tmp)/other"))
  }

  func testAnotherWindowStartingAtTheSameTimeTheOneInItsFolder() throws {
    let (tmp, mine, other) = try folders()
    let cwds = [501: other, 502: other, 511: mine]
    // Asked by the path it was given (/tmp is /private/tmp on a Mac).
    XCTAssertEqual(ghosttyNewTty(["ttys030", "ttys031"], launchProcs, cwds, "\(tmp)/mine"), "ttys031")
    XCTAssertEqual(ghosttyNewTty(["ttys030", "ttys031"], launchProcs, cwds, other), "ttys030")
  }

  func testTheOtherWindowsTerminalComingUpFirstIsntTakenForThisOne() throws {
    let (_, mine, other) = try folders()
    XCTAssertNil(ghosttyNewTty(["ttys030"], launchProcs, [501: other, 502: other], mine))
  }

  func testTwoInTheSameFolderAreNotToldApartWithNoFoldersKnownOnlyOneNewCounts() throws {
    let (_, mine, _) = try folders()
    XCTAssertNil(ghosttyNewTty(["ttys030", "ttys031"], launchProcs, [501: mine, 511: mine], mine))
    XCTAssertEqual(ghosttyNewTty(["ttys031"], launchProcs, [:], mine), "ttys031")
    XCTAssertNil(ghosttyNewTty(["ttys030", "ttys031"], launchProcs, [:], mine))
  }
}
#endif
