#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

/// Desk on a real tmux server of its own (`-S` in a temp folder), never the person's.
final class DeskTests: XCTestCase {
  private let exe = findExecutable("tmux")
  private var dir = ""

  override func setUp() {
    dir = realPathOf(FileManager.default.temporaryDirectoryForTests("ptd"))
  }

  override func tearDown() {
    if let exe { runSync(exe, ["-S", "\(dir)/desk", "kill-server"]) }
    try? FileManager.default.removeItem(atPath: dir)
  }

  private func desk() throws -> (Desk, Terminals) {
    guard exe != nil else { throw XCTSkip("tmux is not installed") }
    let tmux = Tmux(socketDirs: [dir])
    let desk = Desk(tmux: tmux, socket: "desk", socketDir: dir)
    let terms = Terminals(
      home: NSHomeDirectory(), tmux: tmux, desk: desk, recency: { [] }, snapshot: { Procs([]) })
    return (desk, terms)
  }

  private func folder(_ name: String) throws -> String {
    let path = "\(dir)/\(name)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  func testASessionsPaneReachesThePhoneAsItsProjectsWindowUnderTheKeyTmuxGivesIt() async throws {
    let (desk, terms) = try desk()
    let api = try folder("api")
    let web = try folder("web")
    let a = try await desk.create(project: api, kind: "claude", label: "fix login")
    let b = try await desk.create(project: api, cwd: try folder("api/sub"))
    let c = try await desk.create(project: web)

    let sessions = try await desk.sessions()
    XCTAssertEqual(sessions.map(\.name), [a.name, b.name, c.name])
    XCTAssertEqual(sessions.map(\.project), [api, api, web])
    XCTAssertEqual(sessions.map(\.kind), ["claude", "shell", "shell"])
    XCTAssertEqual(sessions[0].label, "fix login")
    XCTAssertEqual(sessions[0].agent, .claude)

    let windows = await terms.windows()
    XCTAssertEqual(Set(windows.map(\.key)), Set([a.key, b.key, c.key]))
    for w in windows {
      let s = sessions.first { $0.key == w.key }!
      XCTAssertEqual(w.via, "PocketTerm Desk")
      XCTAssertEqual(w.osWindow, "desk:\(s.project)")
      XCTAssertEqual(w.tabId, w.key)
    }
  }

  func testACommandRunsInTheSessionsShellWhichStaysOnceItEnds() async throws {
    let (desk, terms) = try desk()
    let p = try folder("p")
    let s = try await desk.create(project: p, kind: "run", command: "echo desk-ran > \(p)/out")
    await until { FileManager.default.fileExists(atPath: "\(p)/out") }
    XCTAssertEqual(try String(contentsOfFile: "\(p)/out", encoding: .utf8), "desk-ran\n")
    let after = try await desk.sessions()
    XCTAssertEqual(after.map(\.name), [s.name])
    // Typed into through the tmux host, as the phone does.
    try await terms.send(s.key, "echo again > \(p)/again", enter: true)
    await until { FileManager.default.fileExists(atPath: "\(p)/again") }
    XCTAssertTrue(FileManager.default.fileExists(atPath: "\(p)/again"))
  }

  func testEndingTheLastSessionLeavesNoServerAndNoSessionsRatherThanAnError() async throws {
    let (desk, _) = try desk()
    let none = try await desk.sessions()
    XCTAssertEqual(none, [])
    let s = try await desk.create(project: try folder("p"))
    try await desk.end(s.name)
    let after = try await desk.sessions()
    XCTAssertEqual(after, [])
    // Already gone: nothing to end.
    try await desk.end(s.name)
  }

  func testRenamingAndMovingASessionShowOnTheNextLook() async throws {
    let (desk, _) = try desk()
    let p = try folder("p")
    let q = try folder("q")
    let s = try await desk.create(project: p)
    try await desk.rename(s.name, to: "server")
    try await desk.move(s.name, to: q)
    var got = try await desk.sessions().single!
    XCTAssertEqual(got.label, "server")
    XCTAssertEqual(got.project, q)
    try await desk.rename(s.name, to: "")
    got = try await desk.sessions().single!
    XCTAssertEqual(got.label, "")
  }

  func testThePhonesNewSessionOpensInDeskInItsProjectWithTheAgentTyped() async throws {
    let (desk, terms) = try desk()
    let p = try folder("proj")
    let opened = try await terms.launch(p, host: desk, agent: .omp)
    XCTAssertEqual(opened.where, "PocketTerm Desk, with proj’s sessions")
    let s = try await desk.sessions().single!
    XCTAssertEqual(s.key, opened.window)
    XCTAssertEqual(s.project, p)
    var screen = ""
    for _ in 0..<100 where !screen.contains("omp") {
      screen = (try? await terms.plainScreen(s.key)) ?? ""
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(screen.contains("omp"), screen)
  }

  func testAFolderThatIsntThereIsSaidSo() async throws {
    let (desk, _) = try desk()
    do {
      try await desk.create(project: "\(dir)/nope")
      XCTFail("no error")
    } catch let e as TerminalException {
      XCTAssertEqual(e.message, "No such folder: \(dir)/nope")
    }
  }

  func testGitStatusReadsTheBranchItsDistanceFromUpstreamAndTheChanges() {
    let g = parseGitStatus("## main...origin/main [ahead 2, behind 13]\n M a.swift\n?? new.txt\nA  b.swift\n")
    XCTAssertEqual(g, DeskGit(branch: "main", changes: 3, ahead: 2, behind: 13))
    XCTAssertEqual(parseGitStatus("## feat/x\n").branch, "feat/x")
    XCTAssertEqual(parseGitStatus("## No commits yet on main\n?? a\n"), DeskGit(branch: "main", changes: 1))
    XCTAssertEqual(parseGitStatus("## HEAD (no branch)\n").branch, "")
  }

  func testListeningPortsAreReadPerProcessWhateverAddressTheyListenOn() {
    let out = "p100\nn*:3000\nn[::1]:3000\np200\nn127.0.0.1:5432\nn[::]:8080\n"
    XCTAssertEqual(parseLsofListening(out), [100: [3000], 200: [5432, 8080]])
  }
}
#endif
