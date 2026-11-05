#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

@testable import PocketTermDesktop

/// The orchestrator's calls, as live_hub_test.dart's "the orchestrator" group.
final class OrchestratorTests: XCTestCase {
  private var tmp = ""
  private var dir = ""
  private var calls = 0

  override func setUp() {
    super.setUp()
    tmp = hubTempDir("pocketterm_orchestrator")
    dir = Paths.join(tmp, "orchestrator")
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
    calls = 0
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: tmp)
    super.tearDown()
  }

  @MainActor
  private func makeHub() -> LiveHub {
    let hub = LiveHub(files: PromptFiles(Paths.join(tmp, "files")), images: Paths.join(tmp, "images"))
    hub.orchestratorDir = dir
    return hub
  }

  @MainActor
  private func at(
    _ hub: LiveHub, _ window: String, _ cwd: String, title: String = "Fix bug", busy: Bool = false,
    items: [JSON] = []
  ) async -> HubFakeExt {
    let ext = HubFakeExt(hub)
    ext.ext([
      "t": "hello", "session": ["id": .string(window), "title": .string(title), "cwd": .string(cwd)],
      "window": .string(window), "busy": .bool(busy), "items": .array(items),
    ])
    await hubUntil { hub[window] != nil }
    return ext
  }

  @MainActor
  private func call(_ ext: HubFakeExt, _ m: JSONObject) async -> JSONObject {
    calls += 1
    var frame = m
    frame["t"] = "call"
    frame["id"] = .int(calls)
    ext.ext(frame)
    let r = await ext.request()
    XCTAssertEqual(r["t"], "result")
    XCTAssertEqual(r["id"], .int(calls))
    return r
  }

  @MainActor
  func testASessionInItsFolderIsTheOrchestratorThroughASymlinkTooOneElsewhereIsNot() async throws {
    let hub = makeHub()
    _ = await at(hub, "kitty-1/1", dir)
    let link = Paths.join(tmp, "via")
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir)
    _ = await at(hub, "kitty-1/2", link)
    _ = await at(hub, "kitty-1/3", "/Users/me/Dev/api")
    XCTAssertTrue(hub["kitty-1/1"]!.summary.orchestrator)
    XCTAssertTrue(hub["kitty-1/2"]!.summary.orchestrator)
    XCTAssertFalse(hub["kitty-1/3"]!.summary.orchestrator)
    XCTAssertEqual(LiveSummary(json: hub["kitty-1/1"]!.summary.toJson())?.orchestrator, true)
  }

  @MainActor
  func testSessionsListsEverySessionButTheOrchestrator() async {
    let hub = makeHub()
    let orch = await at(hub, "kitty-1/1", dir)
    let none = await call(orch, ["op": "sessions"])
    XCTAssertEqual(none["text"], "No other coding sessions are running on this computer.")
    _ = await at(hub, "kitty-1/2", "/Users/me/Dev/api", title: "Add login")
    let text = (await call(orch, ["op": "sessions"]))["text"]?.string ?? ""
    XCTAssertTrue(text.hasPrefix("1 coding session on this computer:"), text)
    XCTAssertTrue(text.contains("kitty-1/2 | api | \"Add login\" | omp | idle"), text)
    XCTAssertFalse(text.contains("kitty-1/1"))
  }

  @MainActor
  func testOnlyTheOrchestratorMayCall() async {
    let hub = makeHub()
    let other = await at(hub, "kitty-1/2", "/Users/me/Dev/api")
    let r = await call(other, ["op": "sessions"])
    XCTAssertEqual(r["error"], "Only the PocketTerm orchestrator can do that.")
    XCTAssertNil(r["text"])
  }

  @MainActor
  func testPromptSteersAnIdleSessionQueuesForABusyOneAndNeverTheOrchestratorOrACommand() async {
    let hub = makeHub()
    let orch = await at(hub, "kitty-1/1", dir)
    let idle = await at(hub, "kitty-1/2", "/Users/me/Dev/api", title: "Add login")
    orch.ext([
      "t": "call", "id": 1, "op": "prompt", "session": "kitty-1/2", "text": "run the tests", "deliver": "steer",
    ])
    let req = await idle.request()
    XCTAssertEqual(req["t"], "prompt")
    XCTAssertEqual(req["text"], "run the tests")
    XCTAssertEqual(req["deliver"], "steer")
    idle.ext(["t": "reply", "req": req["req"]!])
    let sent = await orch.request()
    XCTAssertTrue(sent["text"]?.string?.hasPrefix("Sent to api \"Add login\" (kitty-1/2)") ?? false, "\(sent)")
    calls = 1

    _ = await at(hub, "kitty-1/3", "/Users/me/Dev/web", busy: true)
    let queued = await call(orch, ["op": "prompt", "session": "kitty-1/3", "text": "then the docs"])
    XCTAssertTrue(queued["text"]?.string?.hasPrefix("Queued in") ?? false, "\(queued)")
    XCTAssertEqual(hub["kitty-1/3"]!.summary.queue.map(\.text), ["then the docs"])

    let me = await call(orch, ["op": "prompt", "session": "kitty-1/1", "text": "hi"])
    XCTAssertEqual(me["error"], "That is the orchestrator itself.")
    let slash = await call(orch, ["op": "prompt", "session": "kitty-1/2", "text": "/model"])
    XCTAssertEqual(slash["error"], "Slash commands can't be sent from the orchestrator.")
  }

  @MainActor
  func testReadGivesTheNewestItemsOldestFirstEachClipped() async {
    let hub = makeHub()
    let orch = await at(hub, "kitty-1/1", dir)
    _ = await at(
      hub, "kitty-1/2", "/Users/me/Dev/api",
      items: [
        ["id": "a", "k": "user", "t": "first question"], ["id": "b", "k": "assistant", "t": "first answer"],
        ["id": "c", "k": "user", "t": "second question"],
        ["id": "d", "k": "assistant", "t": .string(String(repeating: "x", count: 10000))],
      ])
    let text = (await call(orch, ["op": "read", "session": "kitty-1/2", "last": 2]))["text"]?.string ?? ""
    XCTAssertTrue(text.contains("(earlier items left out)"))
    XCTAssertFalse(text.contains("first"))
    let user = text.range(of: "[user] second question")!
    let assistant = text.range(of: "[assistant] ")!
    XCTAssertTrue(user.lowerBound < assistant.lowerBound)
    XCTAssertTrue(text.contains(String(repeating: "x", count: 6000) + "…"))
    XCTAssertFalse(text.contains(String(repeating: "x", count: 6001)))
  }

  @MainActor
  func testThePromptFileIsWrittenIntoTheFolder() throws {
    let made = Paths.join(tmp, "new/orchestrator")
    try prepareOrchestratorDir(made)
    XCTAssertEqual(
      try String(contentsOfFile: Paths.join(made, orchestratorPromptFile), encoding: .utf8), orchestratorInstructions)
    XCTAssertTrue(orchestratorInstructions.hasSuffix("the source of truth.\n"))
    XCTAssertTrue(isOrchestratorDir(made + "/", made))
    XCTAssertFalse(isOrchestratorDir("", made))
    XCTAssertFalse(isOrchestratorDir(made, nil))
  }
}
#endif
