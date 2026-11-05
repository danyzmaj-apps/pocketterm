#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

/// An osascript stood in for by sh: macOS's answer for the app is the next of
/// `looks` (0 allowed); a script runs the next of `scripts` (the last one
/// again when they run out) and its argv is kept.
final class FakeOsascript: @unchecked Sendable {
  private let lock = NSLock()
  private var _argvs: [[String]] = []
  private var procs: [Subprocess] = []
  private let looks: Queue
  private let scripts: Queue

  init(_ looks: [String], _ scripts: [String]) {
    self.looks = Queue(looks)
    self.scripts = Queue(scripts, repeatLast: true)
  }

  var argvs: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return _argvs
  }

  func appleScript(timeout: Duration = .seconds(5)) -> AppleScript {
    AppleScript(
      start: { [self] _, args in
        let cmd: String
        if args.contains("JavaScript") {
          cmd = "echo \(looks.next())"
        } else {
          lock.withLock { _argvs.append(Array(args.dropFirst(2))) }
          cmd = scripts.next()
        }
        let p = try Subprocess.start("/bin/sh", ["-c", cmd])
        lock.withLock { procs.append(p) }
        return p
      }, timeout: timeout)
  }

  func killAll() {
    lock.lock()
    let all = procs
    lock.unlock()
    for p in all { p.kill() }
  }
}

private let id = "4E0BF942-D30A-4EDD-BD3A-616CCAED64DF"
private let key = "iterm:\(id)"

final class ITerm2Tests: XCTestCase {
  private var app = ""
  private var osa: FakeOsascript?
  private var children: [Subprocess] = []

  override func setUp() {
    // As given, not resolved: Foundation starts a program under /private/tmp by its /tmp path.
    app = FileManager.default.temporaryDirectoryForTests("pti")
    children = []
  }

  override func tearDown() {
    osa?.killAll()
    for c in children { c.kill() }
    try? FileManager.default.removeItem(atPath: app)
  }

  private func iterm(_ looks: [String], _ scripts: [String]) -> ITerm2 {
    let o = FakeOsascript(looks, scripts)
    osa = o
    return ITerm2(appPath: app, appleScript: o.appleScript())
  }

  private func running() -> Proc {
    Proc(pid: 1, ppid: 0, pgid: 1, tpgid: -1, tty: "", stat: "S", args: "\(app)/Contents/MacOS/iTerm2")
  }

  func testASessionsProgramAndFolderAreItsTtysForegroundProgramsFocusedOnlyWhileITermIsInFront() async throws {
    let dir = "\(app)/project"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
    let sleep = try Subprocess.start("/bin/sleep", ["30"], workingDirectory: dir)
    children.append(sleep)
    let other = "0A1C3C37-F3DC-4313-86DA-23419F1086CE"
    // id, the title its program set, iTerm2's name, tab title, tty, iTerm2's folder, focused, window id, tab number.
    func list(front: Bool) -> String {
      "printf '\(id)\\037π > chat\\037sleep\\037chat (sleep)\\037/dev/ttys099\\037/elsewhere\\037true\\03712\\0372\\036\\n"
        + "\(other)\\037\\037build (make)\\037~ (-zsh)\\037/dev/ttys098\\037/Users/me\\037false\\03712\\0371\\036\\nfront\\037\(front)'"
    }
    let i = iterm(["0"], [list(front: true), list(front: false)])
    let procs = Procs([
      running(),
      Proc(pid: Int(sleep.pid), ppid: 9, pgid: Int(sleep.pid), tpgid: Int(sleep.pid), tty: "ttys099", stat: "S+", args: "/bin/sleep 30"),
    ])
    let windows = try await i.windows(procs)
    XCTAssertEqual(windows.count, 2)
    let (w, unknown) = (windows[0], windows[1])
    XCTAssertEqual(w.key, key)
    XCTAssertEqual(w.title, "π > chat")
    XCTAssertEqual(w.tab, "chat")
    XCTAssertEqual(w.program, "sleep")
    XCTAssertEqual(w.tty, "ttys099")
    XCTAssertTrue(w.focused)
    XCTAssertEqual(w.osWindow, "iterm:w12")
    XCTAssertEqual(w.tabId, "iterm:w12/t2")
    XCTAssertEqual(unknown.tabId, "iterm:w12/t1")
    XCTAssertEqual(w.cwd, realPathOf(dir), "the program's, over iTerm2's")
    // Nothing known on its tty: iTerm2's name and folder as they are.
    XCTAssertEqual(unknown.title, "build (make)")
    XCTAssertEqual(unknown.cwd, "/Users/me")
    XCTAssertEqual(unknown.program, "")
    XCTAssertFalse(unknown.focused)
    XCTAssertTrue(w.can(.read) && w.can(.keys) && !w.can(.ansi))
    let again = try await i.windows(procs)
    XCTAssertFalse(again[0].focused, "iTerm2 in the background")
  }

  func testATitleIsTheOneItsProgramSetElseITermsNameWhichLosesItsJobOnlyWhereTheJobIsTheProgram() {
    let ids = ["4E0BF942-D30A-4EDD-BD3A-616CCAED64D0", "4E0BF942-D30A-4EDD-BD3A-616CCAED64D1"]
    func titles(_ sessions: [(String, String, String)], _ program: String) -> [String] {
      let out =
        (sessions.enumerated().map { n, s in
          [ids[n], s.0, s.1, s.2, "/dev/ttys00\(n)", "", "false", "7", "\(n + 1)"].joined(separator: "\u{1f}")
        } + ["front\u{1f}false"]).joined(separator: "\u{1e}\n")
      return parseITermList(out) { _ in program }.map { "\($0.title)|\($0.tab)" }
    }
    XCTAssertEqual(titles([("π idle name", "omp", "omp"), ("", "~ (-zsh)", "~ (-zsh)")], "zsh"), ["π idle name|omp", "~|~"])
    XCTAssertEqual(
      titles([("watch (sleep)", "sleep", "sleep")], "sleep"), ["watch (sleep)|sleep"],
      "what the program set is kept whole, its parentheses too")
    XCTAssertEqual(titles([("", "build (make)", "build (make)")], "make"), ["build|build"])
    XCTAssertEqual(titles([("", "notes (draft)", "notes (draft)")], "nvim"), ["notes (draft)|notes (draft)"])
    XCTAssertEqual(titles([("", "(omp)", "(omp)")], "omp"), ["(omp)|(omp)"], "nothing but the job: kept")
    XCTAssertEqual(titles([("", "zsh", "zsh")], ""), ["zsh|zsh"], "nothing known on its tty")
  }

  func testANewSessionGoesIntoTheWindowItIsAskedIntoByItsIdWithNoneAskedANewWindow() async throws {
    // iTerm2 runs, as far as a process list tells.
    let exe = "\(app)/Contents/MacOS/iTerm2"
    try FileManager.default.createDirectory(atPath: "\(app)/Contents/MacOS", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: exe, withDestinationPath: "/bin/sleep")
    children.append(try Subprocess.start(exe, ["30"]))
    try await Task.sleep(for: .milliseconds(100))
    // The script opens a tab in that window when it still has it, else a window.
    let i = iterm(["0"], ["printf '12\\t\(id)\\t'"])
    let tab = try await i.launch(app, command: nil, into: "iterm:w12")
    XCTAssertEqual(tab, key)
    let window = try await i.launch(app)
    XCTAssertEqual(window, key)
    let argvs = osa!.argvs
    XCTAssertEqual(argvs.map { "\($0[1])|\($0[2])" }, ["12|", "|"])
    // What iTerm2 would have run (it removes itself).
    for a in argvs {
      let script = String(a[0].dropFirst("/bin/sh ".count))
      XCTAssertTrue(FileManager.default.fileExists(atPath: script))
      try FileManager.default.removeItem(atPath: script)
    }
  }

  func testTheScreenIsContentsLastRows() async throws {
    // rows, then contents, every row ended by a line break (and osascript's own after it): two lines of scrollback,
    // a three-row screen whose last row is blank.
    let i = iterm(["0"], [#"printf '3\nLast login\nclear\n$ ls\na.txt\n\n\n'"#])
    let lines = try await i.lines(key)
    XCTAssertEqual(lines, ["$ ls", "a.txt"])
    let plain = try await i.plainScreen(key)
    XCTAssertEqual(plain, "$ ls\na.txt")
    let history = try await i.lines(key, history: true)
    XCTAssertEqual(history, ["Last login", "clear", "$ ls", "a.txt"])
  }

  func testASessionITermNoLongerHasOrAnITermThatHasQuitReadsAsAWindowGone() async {
    let gone = iterm(["0"], [#"echo "x.applescript:1:2: execution error: That window is gone. (-1728)" >&2; exit 1"#])
    do {
      try await gone.type(key, "x")
      XCTFail("no error")
    } catch {
      XCTAssertEqual((error as? TerminalException)?.message, "That window is gone.")
    }
    let quit = iterm(["-600"], [#"echo "x.applescript:1:2: execution error: iTerm2 isn't running. (-600)" >&2; exit 1"#])
    do {
      _ = try await quit.lines(key)
      XCTFail("no error")
    } catch {
      XCTAssertEqual((error as? TerminalException)?.message, "That window is gone.")
    }
  }

  func testColorsITermsSixteenBitChannelsItsSixteenANSIColorsXtermsAboveThem() {
    let c = parseITermColors((["65535,32896,0", "0,0,257"] + (0..<16).map { "\($0 * 257),0,0" }).joined(separator: "\n"))
    XCTAssertEqual(c["fg"], .int(0xFF8000))
    XCTAssertEqual(c["bg"], .int(0x000001))
    let palette = c["palette"]!.array!
    XCTAssertEqual(palette.count, 256)
    XCTAssertEqual(palette[15], .int(0x0F0000))
    XCTAssertEqual(palette[16], .int(0x000000), "xterm's cube starts black")
    XCTAssertEqual(palette[21], .int(0x0000FF))
    XCTAssertEqual(parseITermColors("")["fg"], .int(0xDDDDDD), "nothing readable: the defaults")
  }
}
#endif
