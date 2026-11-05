#if os(macOS)
import PocketTermKit
import PocketTermTerminals
import XCTest

/// What a fake osascript was started with, and the processes it started.
final class Started: @unchecked Sendable {
  private let lock = NSLock()
  private var _args: [[String]] = []
  private var _procs: [Subprocess] = []

  func add(_ args: [String], _ p: Subprocess?) {
    lock.lock()
    _args.append(args)
    if let p { _procs.append(p) }
    lock.unlock()
  }

  var args: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return _args
  }

  var procs: [Subprocess] {
    lock.lock()
    defer { lock.unlock() }
    return _procs
  }

  /// `look` / `ask` for the consent helper, `script` for a script.
  var kinds: [String] { args.map { $0.contains("JavaScript") ? $0.last! : "script" } }

  func killAll() { for p in procs { p.kill() } }
}

/// A list the fake hands out one by one (the last again once it runs out, with `repeatLast`).
final class Queue: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String]
  private let repeatLast: Bool

  init(_ items: [String], repeatLast: Bool = false) {
    self.items = items
    self.repeatLast = repeatLast
  }

  func next() -> String {
    lock.lock()
    defer { lock.unlock() }
    return repeatLast && items.count == 1 ? items[0] : items.removeFirst()
  }
}

final class AppleScriptTests: XCTestCase {
  // osascript stood in for by sh: the consent look answers the next of
  // `looks`, the question to the person runs `ask`, a script runs `script`.
  private var started = Started()

  override func setUp() { started = Started() }
  override func tearDown() { started.killAll() }

  private func osa(_ looks: [String], ask: String = "sleep 30", script: String = "echo out") -> AppleScript {
    let looks = Queue(looks)
    let started = started
    return AppleScript(
      start: { _, args in
        let cmd = !args.contains("JavaScript") ? script : args.last == "ask" ? ask : "echo \(looks.next())"
        let p = try Subprocess.start("/bin/sh", ["-c", cmd])
        started.add(args, p)
        return p
      }, timeout: .milliseconds(600), stuckAfter: .milliseconds(200), lookFor: .milliseconds(300))
  }

  private func assertPending(_ body: () async throws -> String, file: StaticString = #filePath, line: UInt = #line)
    async
  {
    do {
      _ = try await body()
      XCTFail("no error", file: file, line: line)
    } catch let e as AutomationPending {
      XCTAssertEqual(e.app, "Terminal", file: file, line: line)
    } catch {
      XCTFail("\(error)", file: file, line: line)
    }
  }

  func testWhileMacOSAsksScriptsFailAtOnceNamingTheAppAndNothingPilesUp() async throws {
    let o = osa(["-1744"])
    for _ in 0..<3 { await assertPending { try await o.run("Terminal", "com.apple.Terminal", "x") } }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(started.kinds, ["look", "ask"])
  }

  func testOnceThePersonSaysYesScriptsGoToTheAppWithoutAskingAgain() async throws {
    let o = osa(["-1744"], ask: "echo 0")
    await assertPending { try await o.run("Terminal", "com.apple.Terminal", "x") }
    try await Task.sleep(for: .milliseconds(200))
    for p in started.procs { _ = await p.exitCode() }
    try await Task.sleep(for: .milliseconds(50))
    let first = try await o.run("Terminal", "com.apple.Terminal", "x")
    let second = try await o.run("Terminal", "com.apple.Terminal", "x")
    XCTAssertEqual([first, second], ["out", "out"])
    XCTAssertEqual(started.kinds, ["look", "ask", "script", "script"])
  }

  func testAnAppThatAnsweredAScriptIsNotLookedUpAgainHoweverLongALookHangs() async throws {
    // Ghostty's look can hang until it's killed: every script waited for it.
    let o = osa(["; sleep 30"])
    for _ in 0..<3 {
      let out = try await o.run("Ghostty", "com.mitchellh.ghostty", "x")
      XCTAssertEqual(out, "out")
    }
    XCTAssertEqual(started.kinds, ["look", "script", "script", "script"])
  }

  func testANoFailsWithoutSendingTheAppAnything() async {
    do {
      _ = try await osa(["-1743"]).run("Terminal", "com.apple.Terminal", "x")
      XCTFail("no error")
    } catch let e as AutomationDenied {
      XCTAssertEqual(e.app, "Terminal")
    } catch {
      XCTFail("\(error)")
    }
    XCTAssertEqual(started.kinds, ["look"])
  }

  func testAScriptThatNeverFinishesIsKilled() async {
    let o = osa(["0"], script: "sleep 30")
    do {
      _ = try await o.run("Terminal", "com.apple.Terminal", "x")
      XCTFail("no error")
    } catch let e as TerminalException {
      XCTAssertTrue(e.message.contains("did not answer"), e.message)
    } catch {
      XCTFail("\(error)")
    }
    let code = await started.procs.last!.exitCode()
    XCTAssertEqual(code, -9)
  }

  func testAScriptThatStartedTheAppAndThenWaitsOnMacOSAskingIsKilledAndFailsAsAsking() async throws {
    // Not running when looked at (-600); the script starts it, and macOS asks.
    let o = osa(["-600", "-1744"], script: "sleep 30")
    await assertPending { try await o.run("Terminal", "com.apple.Terminal", "x") }
    let code = await started.procs[1].exitCode()
    XCTAssertEqual(code, -9)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(started.kinds, ["look", "script", "look", "ask"])
  }

  func testAQuestionHelperThatFailsToStartLeavesTheNextScriptFreeToLookAgain() async throws {
    let looks = Queue(["-1744", "0"])
    let started = started
    let o = AppleScript(
      start: { _, args in
        if args.last == "ask" {
          started.add(args, nil)
          throw ProcessLaunchError(message: "Resource busy")
        }
        let p = try Subprocess.start("/bin/sh", ["-c", args.contains("JavaScript") ? "echo \(looks.next())" : "echo out"])
        started.add(args, p)
        return p
      }, timeout: .milliseconds(600), stuckAfter: .milliseconds(200))
    await assertPending { try await o.run("Terminal", "com.apple.Terminal", "x") }
    try await Task.sleep(for: .milliseconds(50))
    let out = try await o.run("Terminal", "com.apple.Terminal", "x")
    XCTAssertEqual(out, "out")
    XCTAssertEqual(started.kinds, ["look", "ask", "look", "script"])
  }
}
#endif
