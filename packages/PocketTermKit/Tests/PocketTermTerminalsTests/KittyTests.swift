#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

/// A unix socket listening at `path`, each connection served by `serve` on a thread of its own.
final class UnixServer: @unchecked Sendable {
  let path: String
  private let fd: Int32

  init(_ path: String, serve: @escaping @Sendable (Int32) -> Void) throws {
    signal(SIGPIPE, SIG_IGN)
    self.path = path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    self.fd = fd
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let name = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      for (i, b) in name.enumerated() { buf[i] = b }
      buf[name.count] = 0
    }
    let r = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard r == 0, listen(fd, 16) == 0 else { throw TerminalException("bind \(path): \(errno)") }
    Thread.detachNewThread {
      while true {
        let c = accept(fd, nil, nil)
        if c < 0 { return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { serve(c) }
      }
    }
  }

  func stop() {
    shutdown(fd, SHUT_RDWR)
    close(fd)
  }

  static func send(_ c: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    var sent = 0
    while sent < bytes.count {
      let n = bytes[sent...].withUnsafeBytes { Darwin.send(c, $0.baseAddress, $0.count, 0) }
      if n <= 0 { return }
      sent += n
    }
  }
}

/// A kitty listening on a unix socket: records each command and answers
/// with what `answer` returns, written in the given pieces (nil: never).
final class FakeKitty: @unchecked Sendable {
  let dir: String
  private var server: UnixServer!
  private let lock = NSLock()
  private var _requests: [JSONObject] = []
  private var _answer: @Sendable (JSONObject) -> [String]? = { _ in [FakeKitty.ok()] }

  static let prefix = "\u{1b}P@kitty-cmd"

  init() throws {
    // Short path: unix socket paths are limited to ~104 bytes on macOS.
    dir = realPathOf(FileManager.default.temporaryDirectoryForTests("kt"))
    server = try UnixServer("\(dir)/kitty-test") { [unowned self] c in self.serve(c) }
  }

  var requests: [JSONObject] {
    lock.lock()
    defer { lock.unlock() }
    return _requests
  }

  func clearRequests() {
    lock.lock()
    _requests = []
    lock.unlock()
  }

  var answer: @Sendable (JSONObject) -> [String]? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _answer
    }
    set {
      lock.lock()
      _answer = newValue
      lock.unlock()
    }
  }

  static func ok(_ data: JSON? = nil) -> String {
    var reply: JSONObject = ["ok": true]
    if let data { reply["data"] = data }
    return frame(reply)
  }

  static func frame(_ reply: JSONObject) -> String { "\(prefix)\(JSON.object(reply).encoded())\u{1b}\\" }

  func kitty(timeout: Duration = .seconds(5)) -> Kitty {
    Kitty(socketDir: dir, timeout: timeout, restoreFront: false)
  }

  private func serve(_ c: Int32) {
    defer { close(c) }
    var buf: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = chunk.withUnsafeMutableBytes { recv(c, $0.baseAddress, $0.count, 0) }
      if n <= 0 { return }
      buf += chunk[..<n]
      // Bytes until the end: a character may span two reads.
      guard buf.count >= 2, buf[buf.count - 2] == 0x1b, buf.last == 0x5c else { continue }
      let text = String(decoding: buf.dropLast(2), as: UTF8.self)
      guard text.hasPrefix(Self.prefix), let request = JSON.tryParse(String(text.dropFirst(Self.prefix.count)))?.object
      else { return }
      lock.lock()
      _requests.append(request)
      let answer = _answer
      lock.unlock()
      guard let pieces = answer(request) else {
        // Never answers: holds on until the client gives up.
        while chunk.withUnsafeMutableBytes({ recv(c, $0.baseAddress, $0.count, 0) }) > 0 {}
        return
      }
      for p in pieces {
        UnixServer.send(c, p)
        usleep(5000)
      }
      return
    }
  }

  func stop() {
    server.stop()
    try? FileManager.default.removeItem(atPath: dir)
  }
}

extension FileManager {
  /// A new folder under /tmp named `<prefix>XXXXXX`.
  func temporaryDirectoryForTests(_ prefix: String) -> String {
    var template = Array("/tmp/\(prefix)XXXXXX".utf8CString)
    guard let p = mkdtemp(&template) else { fatalError("mkdtemp") }
    return String(cString: p)
  }
}

func realPathOf(_ path: String) -> String {
  guard let r = realpath(path, nil) else { return path }
  defer { free(r) }
  return String(cString: r)
}

final class KittyTests: XCTestCase {
  private var fake: FakeKitty!

  override func setUp() async throws { fake = try FakeKitty() }
  override func tearDown() async throws { fake.stop() }

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

  func testFramesEachCommandAsKittyCmdJSONWithVersionAndPayload() async throws {
    try await fake.kitty().close("kitty-test/7")
    XCTAssertEqual(fake.requests, [["cmd": "close-window", "version": [0, 20, 0], "payload": ["match": "id:7"]]])
  }

  func testReadsAnAnswerThatArrivesInSeveralWrites() async throws {
    let colors = "foreground #a0b0c0\nbackground #010203\ncolor1     #ff0000\n"
    let whole = FakeKitty.ok(.string(colors)) as NSString
    let pieces = [
      whole.substring(to: 10), whole.substring(with: NSRange(location: 10, length: 30)),
      whole.substring(with: NSRange(location: 40, length: whole.length - 41)), "\\",
    ]
    fake.answer = { _ in pieces }
    let c = try await fake.kitty().colors("kitty-test/1")!
    XCTAssertEqual(c["fg"], .int(0xA0B0C0))
    XCTAssertEqual(c["bg"], .int(0x010203))
    XCTAssertEqual(c["palette"]?[1], .int(0xFF0000))
  }

  private func shown(_ r: JSONObject) -> String {
    let payload = r["payload"]!
    if r["cmd"] == "send-key" { return "key " + payload["keys"]!.strings!.joined(separator: " ") }
    return "\(r["cmd"]!.string!) \(payload["data"]!.string!)"
  }

  func testAMultiLineSendTypesEachLineShiftEnterBetweenEnterLast() async throws {
    try await fake.kitty().send("kitty-test/3", "one\n\ntwo", enter: true)
    XCTAssertEqual(
      fake.requests.map(shown),
      ["send-text text:one", "key shift+enter", "key shift+enter", "send-text text:two", "key enter"])
    for r in fake.requests {
      XCTAssertEqual(r["payload"]?["match"], "id:3")
      if r["cmd"] == "send-text" { XCTAssertEqual(r["payload"]?["bracketed_paste"], "disable") }
    }
  }

  func testCRLFAndCRAreLineBreaksTooNeverABareEnterMidText() async throws {
    try await fake.kitty().send("kitty-test/3", "rm -rf build\r\necho done\rls", enter: false)
    let sent = fake.requests.map { r in
      r["payload"]?["keys"]?.strings?.joined() ?? r["payload"]!["data"]!.string!
    }
    XCTAssertEqual(sent, ["text:rm -rf build", "shift+enter", "text:echo done", "shift+enter", "text:ls"])
  }

  func testPressKeysSendsAllNamesInOneCommandPressRefusesKeysThePhoneMayNotPress() async throws {
    try await fake.kitty().pressKeys("kitty-test/2", ["down", "down", "enter"])
    XCTAssertEqual(fake.requests.map { $0["payload"] }, [["match": "id:2", "keys": ["down", "down", "enter"]]])
    await assertMessage(nil) { try await Terminals.standard(kittyDir: self.fake.dir).press("kitty-test/2", "ctrl+v") }
    XCTAssertEqual(fake.requests.count, 1)
  }

  func testWindowsReadsTheLsJSONKittyNestsInsideData() async throws {
    let ls: JSON = [
      [
        "id": 2,
        "tabs": [
          [
            "id": 3, "title": "work",
            "windows": [
              [
                "id": 4, "title": "omp: pocketterm", "is_focused": true, "cwd": "/x", "cmdline": ["-zsh"],
                "foreground_processes": [["cwd": "/Users/me/pocketterm", "cmdline": ["/opt/homebrew/bin/omp", "--resume"]]],
              ],
              ["id": 5, "title": "shell", "cwd": "/Users/me", "cmdline": ["-zsh"]],
            ],
          ]
        ],
      ]
    ]
    fake.answer = { _ in [FakeKitty.ok(.string(ls.encoded()))] }
    let windows = try await fake.kitty().windows()
    let caps: JSON = ["read", "ansi", "type", "line", "keys", "close"]
    XCTAssertEqual(
      windows.map { JSON.object($0.toJson()) },
      [
        [
          "key": "kitty-test/4", "osWindow": "kitty-test/os2", "tabId": "kitty-test/tab3", "title": "omp: pocketterm",
          "tab": "work", "cwd": "/Users/me/pocketterm", "program": "omp", "focused": true, "app": "kitty", "caps": caps,
        ],
        [
          "key": "kitty-test/5", "osWindow": "kitty-test/os2", "tabId": "kitty-test/tab3", "title": "shell",
          "tab": "work", "cwd": "/Users/me", "program": "zsh", "focused": false, "app": "kitty", "caps": caps,
        ],
      ])
    XCTAssertEqual(windows.first?.agent, .omp)
  }

  func testAWindowKittyNoLongerHasReadsAsGoneOtherErrorsPassThrough() async {
    fake.answer = { _ in [FakeKitty.frame(["ok": false, "error": "No matching windows for expression: id:9"])] }
    await assertMessage("That window is gone.") { try await self.fake.kitty().pressKeys("kitty-test/9", ["esc"]) }
    fake.answer = { _ in [FakeKitty.frame(["ok": false, "error": "Something else broke"])] }
    await assertMessage("Something else broke") { try await self.fake.kitty().type("kitty-test/9", "x") }
  }

  func testAKeyForASocketThatIsNotThereIsRefusedWithoutAskingKitty() async {
    await assertMessage(nil) { try await self.fake.kitty().close("kitty-gone/1") }
    await assertMessage(nil) { try await self.fake.kitty().close("../kitty-test/1") }
    XCTAssertTrue(fake.requests.isEmpty)
  }

  func testAnotherAccountsKittySocketInTheSharedFolderIsNeitherListedNorTypedInto() async throws {
    // The fake's socket is this user's; to a Kitty running as someone else it is a stranger's.
    let asOther = Kitty(socketDir: fake.dir, restoreFront: false, uid: 4_242_424)
    await assertMessage(nil) { _ = try await asOther.windows() }
    await assertMessage(nil) { try await asOther.type("kitty-test/1", "x") }
    XCTAssertTrue(fake.requests.isEmpty)
    try await fake.kitty().close("kitty-test/1")
    XCTAssertEqual(fake.requests.count, 1)
  }

  func testAKittyThatNeverAnswersTimesOut() async {
    fake.answer = { _ in nil }
    let start = ContinuousClock.now
    await assertMessage(nil) { _ = try await self.fake.kitty(timeout: .milliseconds(200)).plainScreen("kitty-test/1") }
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
  }

  func testLongTextGoesInPiecesKittyTakesInOrderNoneOfItAsAPaste() async throws {
    // kitty ignores a message over about 128 KB and hangs up.
    let text = (0..<9000).map { "é漢\"\\\u{1b}\($0)" }.joined()
    try await fake.kitty().type("kitty-test/1", text)
    let payloads = fake.requests.map { $0["payload"]!.object! }
    XCTAssertGreaterThan(payloads.count, 1)
    for p in payloads {
      XCTAssertLessThan(JSON.object(p).encoded().utf8.count, 100_000)
      XCTAssertEqual(p["bracketed_paste"], "disable")
    }
    XCTAssertEqual(payloads.map { String($0["data"]!.string!.dropFirst("text:".count)) }.joined(), text)
  }

  func testAKittyThatHangsUpOnWhatItWasSentIsAnAnswerNotACrash() async throws {
    let hup = try UnixServer("\(fake.dir)/kitty-hup") { close($0) }
    defer { hup.stop() }
    for size in [10, 9000] {
      await assertMessage(nil) { try await self.fake.kitty().type("kitty-hup/1", String(repeating: "x", count: size)) }
    }
    try await Task.sleep(for: .milliseconds(100))
  }

  func testASocketLeftBehindByAKittyThatWasKilledReadsAsKittyHavingQuit() async throws {
    // nc listens on it and is killed: the socket stays with nobody behind it.
    let path = "\(fake.dir)/kitty-stale"
    let nc = try Subprocess.start("/usr/bin/nc", ["-lU", path])
    for _ in 0..<50 where fileKind(path) == .notFound { try await Task.sleep(for: .milliseconds(20)) }
    nc.kill()
    _ = await nc.exitCode()
    XCTAssertEqual(fileKind(path), .socket)
    await assertMessage(Kitty.quit) { try await self.fake.kitty().type("kitty-stale/1", "x") }
    // The live one still lists; the stale one is passed over.
    fake.answer = { _ in [FakeKitty.ok("[]")] }
    let windows = try await fake.kitty().windows()
    XCTAssertEqual(windows, [])
  }

  func testLinesStripsPaddingDropsTrailingBlanksAndKeepsTheNewestLinesWithinHistoryBytes() async throws {
    // 100 lines of 1000 bytes each, then padded and blank lines at the bottom.
    let body = (0..<100).map { String(format: "%03d", $0) + String(repeating: "x", count: 997) }
    let text = (body + ["prompt \u{1b}[31m  \u{1b}[m   ", "   ", "\u{1b}[m", ""]).joined(separator: "\n")
    fake.answer = { _ in [FakeKitty.ok(.string(text))] }
    let lines = try await fake.kitty().lines("kitty-test/1", history: true)
    XCTAssertEqual(fake.requests.single?["payload"], ["match": "id:1", "extent": "all", "ansi": true])
    XCTAssertEqual(lines.last, "prompt\u{1b}[31m\u{1b}[m")
    XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.utf8.count + 1 }, historyBytes)
    // 59 full lines plus the prompt fit; the 60th would not.
    XCTAssertEqual(lines.count, 60)
    XCTAssertEqual(lines.first, body[41])
  }

  // ------------------------------------------------------------ a new session

  /// Answers `ls` with `kittyLs` and `launch` with window 42.
  private func listing() { fake.answer = { r in [FakeKitty.ok(.string(r["cmd"] == "ls" ? kittyLs : "42"))] } }
  private func launched() -> JSON? { fake.requests.first { $0["cmd"] == "launch" }?["payload"] }

  func testIntoAnOSWindowInTheBackgroundATabThereNextToOneOfItsWindows() async throws {
    listing()
    let key = try await fake.kitty().launch(fake.dir, command: nil, into: "kitty-test/os2")
    XCTAssertEqual(key, "kitty-test/42")
    XCTAssertEqual(
      launched(), ["args": [], "cwd": .string(fake.dir), "type": "tab", "match": "window_id:5", "keep_focus": false])
  }

  func testIntoTheOSWindowBeingTypedInATabThatTakesNoFocusFromIt() async throws {
    listing()
    _ = try await fake.kitty().launch(fake.dir, command: ["omp"], into: "kitty-test/os1")
    XCTAssertEqual(
      launched(), ["args": ["omp"], "cwd": .string(fake.dir), "type": "tab", "match": "window_id:1", "keep_focus": true])
  }

  func testIntoAnOSWindowThatIsGoneOrOfAKittyThatIsANewOSWindow() async throws {
    for into in ["kitty-test/os9", "kitty-gone/os2"] {
      listing()
      fake.clearRequests()
      let key = try await fake.kitty().launch(fake.dir, command: nil, into: into)
      XCTAssertEqual(key, "kitty-test/42")
      XCTAssertEqual(launched(), ["args": [], "cwd": .string(fake.dir), "type": "os-window", "keep_focus": true])
    }
  }

  func testIntoNoWindowANewOSWindowWithoutAskingWhatKittyHasOpen() async throws {
    listing()
    _ = try await fake.kitty().launch(fake.dir)
    XCTAssertEqual(fake.requests.map { $0["cmd"] }, ["launch"])
    XCTAssertEqual(launched(), ["args": [], "cwd": .string(fake.dir), "type": "os-window", "keep_focus": true])
  }

  func testClosingAnOSWindowsLastWindowIsToldApartFromClosingATab() {
    XCTAssertTrue(lastInOsWindow(kittyLs, 1))
    XCTAssertFalse(lastInOsWindow(kittyLs, 7))
  }

  func testKittyConfIsTurnedOnOnlyWithRemoteControlAndAUnixSocket() {
    XCTAssertTrue(Kitty.configured("allow_remote_control socket-only\nlisten_on unix:/tmp/kitty\n"))
    XCTAssertTrue(Kitty.configured("  allow_remote_control   yes\n listen_on unix:/tmp/k"))
    XCTAssertFalse(Kitty.configured("allow_remote_control no\nlisten_on unix:/tmp/kitty\n"))
    XCTAssertFalse(Kitty.configured("allow_remote_control yes\nlisten_on tcp:localhost:1234\n"))
    XCTAssertFalse(Kitty.configured("# allow_remote_control yes\nlisten_on unix:/tmp/kitty\n"))
  }
}

extension Array {
  var single: Element? { count == 1 ? self[0] : nil }
}

// kitty's ls: OS window 1 (focused) holds window 1; OS window 2 holds windows
// 5 and 7, each in a tab of its own.
let kittyLs = JSON.array([
  ["id": 1, "is_focused": true, "tabs": [["id": 1, "windows": [["id": 1]]]]],
  ["id": 2, "is_focused": false, "tabs": [["id": 2, "windows": [["id": 5]]], ["id": 3, "windows": [["id": 7]]]]],
]).encoded()
#endif
