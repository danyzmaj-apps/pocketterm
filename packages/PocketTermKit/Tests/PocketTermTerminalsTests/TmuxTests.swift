#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

private let gone = "That window is gone."

/// Runs `exe` with `args` to its end: its code and stdout.
@discardableResult
func runSync(_ exe: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: exe)
  p.arguments = args
  let out = Pipe()
  let err = Pipe()
  p.standardOutput = out
  p.standardError = err
  p.standardInput = FileHandle.nullDevice
  try! p.run()
  let o = out.fileHandleForReading.readDataToEndOfFile()
  let e = err.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

/// A script at `path` that runs `body` (sh).
func writeScript(_ path: String, _ body: String) {
  FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
}

func until(_ done: () -> Bool) async {
  for _ in 0..<100 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
}

private func assertMessage(
  _ message: String?, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
) async {
  do {
    try await body()
    XCTFail("no error", file: file, line: line)
  } catch let e as TerminalException {
    if let message { XCTAssertEqual(e.message, message, file: file, line: line) }
  } catch {
    XCTFail("\(error)", file: file, line: line)
  }
}

/// Real tmux servers of their own (`-S` in a temp folder, no tmux.conf),
/// never the person's: `Tmux` is given only that folder.
final class TmuxTests: XCTestCase {
  private let exe = findExecutable("tmux")
  private var dir = ""
  private var servers: [String] = []

  override func setUp() {
    dir = realPathOf(FileManager.default.temporaryDirectoryForTests("ptm"))
    servers = []
  }

  override func tearDown() {
    if let exe { for s in servers { runSync(exe, ["-S", s, "kill-server"]) } }
    try? FileManager.default.removeItem(atPath: dir)
  }

  private func realTmux() throws -> String {
    guard let exe else { throw XCTSkip("tmux is not installed") }
    return exe
  }

  /// A server on socket `name` in `dir` (or `at`) with one pane running
  /// `command` in `cwd`; the socket's path.
  @discardableResult
  private func server(_ name: String, _ command: [String], cwd: String? = nil, at: String? = nil) throws -> String {
    let exe = try realTmux()
    let socket = "\(at ?? dir)/\(name)"
    let r = runSync(
      exe, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-x", "120", "-y", "30", "-c", cwd ?? dir] + command)
    XCTAssertEqual(r.code, 0, r.err)
    servers.append(socket)
    return socket
  }

  func testAPaneInAFolderWhoseNameHoldsATabAndALineBreakIsListedWithThatFolder() async throws {
    let weird = "\(dir)/tab\there\nnew line"
    try FileManager.default.createDirectory(atPath: weird, withIntermediateDirectories: false)
    try server("edge", ["sleep", "60"], cwd: weird)
    let panes = try await Tmux(socketDirs: [dir]).windows(Procs([]))
    XCTAssertEqual(panes.map(\.cwd), [realPathOf(weird)])
  }

  func testTextOverThe16KBTmuxTakesInOneCommandArrivesWholeAndInOrder() async throws {
    let text = (0..<3000).map { "é漢👍\"'$x\($0) " }.joined()
    let bytes = text.utf8.count
    XCTAssertGreaterThan(bytes, 40000)
    let out = "\(dir)/out"
    try server("edge", ["/bin/sh", "-c", "stty raw -echo; head -c \(bytes) > \(out)"])
    try await Task.sleep(for: .milliseconds(300))
    let tmux = Tmux(socketDirs: [dir])
    let key = try await tmux.windows(Procs([])).single!.key
    try await tmux.type(key, text)
    await until { ((try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0) >= bytes }
    XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), text)
  }

  func testAKilledServersPanesReadAsGoneItsSocketLeftBehind() async throws {
    let exe = try realTmux()
    let socket = try server("edge", ["sleep", "60"])
    let tmux = Tmux(socketDirs: [dir])
    let key = try await tmux.windows(Procs([])).single!.key
    let pid = Int32(runSync(exe, ["-S", socket, "display", "-p", "#{pid}"]).out.trimmingCharacters(in: .whitespacesAndNewlines))!
    kill(pid, SIGKILL)
    await until { kill(pid, 0) != 0 }
    XCTAssertEqual(fileKind(socket), .socket)
    let after = try await tmux.windows(Procs([]))
    XCTAssertEqual(after, [])
    await assertMessage(gone) { try await tmux.type(key, "x") }
  }

  func testAServerAnAgentNamedOutsideTheFoldersLookedInIsGoneOnceItsSocketIs() async throws {
    let exe = try realTmux()
    let elsewhere = FileManager.default.temporaryDirectoryForTests("ptm")
    defer { try? FileManager.default.removeItem(atPath: elsewhere) }
    let socket = try server("agent", ["sleep", "60"], at: elsewhere)
    let tmux = Tmux(socketDirs: [dir])
    tmux.learn(socket)
    let key = try await tmux.windows(Procs([])).single!.key
    XCTAssertTrue(key.hasPrefix("tmux:agent/"), key)
    runSync(exe, ["-S", socket, "kill-server"])
    try FileManager.default.removeItem(atPath: socket)
    let after = try await tmux.windows(Procs([]))
    XCTAssertEqual(after, [])
    await assertMessage(gone) { try await tmux.type(key, "x") }
  }

  /// `$TMUX_TMPDIR`'s server and a `default` left behind in `/private/tmp`:
  /// the live one, looked in first, is the one listed and typed into.
  func testASocketLeftBehindLaterUnderTheSameNameDoesntHideTheLiveServer() async throws {
    let exe = try realTmux()
    let later = realPathOf(FileManager.default.temporaryDirectoryForTests("ptm"))
    defer { try? FileManager.default.removeItem(atPath: later) }
    let left = try server("default", ["sleep", "60"], at: later)
    let pid = Int32(runSync(exe, ["-S", left, "display", "-p", "#{pid}"]).out.trimmingCharacters(in: .whitespacesAndNewlines))!
    kill(pid, SIGKILL)
    await until { kill(pid, 0) != 0 }
    XCTAssertEqual(fileKind(left), .socket)
    try server("default", ["sleep", "60"], cwd: dir)
    let tmux = Tmux(socketDirs: [dir, later])
    let panes = try await tmux.windows(Procs([]))
    XCTAssertEqual(panes.map(\.cwd), [dir])
    try await tmux.type(panes.single!.key, "x")
  }

  /// tmux as an app started from Finder or the Dock runs it: without the
  /// LANG and LC_ALL of the terminal these tests run in (LC_CTYPE only as
  /// PocketTerm hands it over), its default server in `dir`.
  private func noLocaleTmux() throws -> String {
    let exe = try realTmux()
    let wrapper = "\(dir)/tmux-no-locale"
    writeScript(wrapper, "export TMUX_TMPDIR=\(dir)\nunset LANG LC_ALL\nexec \(exe) \"$@\"")
    return wrapper
  }

  func testWithNoLocaleAPaneInAFolderNamedInOtherLettersIsListedWithThatFolder() async throws {
    let named = "\(dir)/Projekt čćž 日本"
    try FileManager.default.createDirectory(atPath: named, withIntermediateDirectories: false)
    try server("edge", ["sleep", "60"], cwd: named)
    let panes = try await Tmux(executable: noLocaleTmux(), socketDirs: [dir], env: [:]).windows(Procs([]))
    XCTAssertEqual(panes.map(\.cwd), [realPathOf(named)])
  }

  func testWithNoLocaleTheShellsOfAServerItStartsHaveAUtf8Locale() async throws {
    let out = "\(dir)/locale"
    let wrapper = try noLocaleTmux()
    let tmux = Tmux(executable: wrapper, socketDirs: [dir], env: [:])
    _ = try await tmux.launch(dir, command: ["/bin/sh", "-c", "locale > \(out); sleep 60"], into: nil)
    servers.append(runSync(wrapper, ["display", "-p", "#{socket_path}"]).out.trimmingCharacters(in: .whitespacesAndNewlines))
    await until { ((try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0) > 0 }
    XCTAssertTrue((try String(contentsOfFile: out, encoding: .utf8)).contains(#"LC_CTYPE="UTF-8""#))
  }

  // ------------------------------------------------------------ a tmux that misbehaves

  private var fakeServer: UnixServer?

  /// A tmux that runs `script`, and a socket for it to be asked on.
  private func fake(_ script: String, timeout: Duration = .seconds(5)) throws -> Tmux {
    let exe = "\(dir)/tmux"
    writeScript(exe, script)
    fakeServer = try UnixServer("\(dir)/fake") { close($0) }
    addTeardownBlock { [fakeServer] in fakeServer?.stop() }
    return Tmux(executable: exe, socketDirs: [dir], timeout: timeout)
  }

  func testOutputThatIsntUtf8ReadsWithReplacementCharactersInsteadOfFailing() async throws {
    let tmux = try fake(#"printf 'a\377\376b'"#)
    let screen = try await tmux.plainScreen("tmux:fake/0")
    XCTAssertEqual(screen, "a\u{FFFD}\u{FFFD}b")
  }

  func testATmuxThatNeverAnswersIsKilledNotLeftBehind() async throws {
    let pidFile = "\(dir)/pid"
    let tmux = try fake("echo $$ > \(pidFile); exec sleep 30", timeout: .seconds(2))
    await assertMessage("tmux did not answer.") { try await tmux.type("tmux:fake/0", "x") }
    // Under load the shell may not have started yet; then nothing runs anyway.
    guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
    await until { kill(pid, 0) != 0 }
    XCTAssertNotEqual(kill(pid, 0), 0, "tmux \(pid) still runs")
  }
}
#endif
