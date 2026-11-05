#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

@testable import PocketTermDesktop

/// The queue tests' session.
private let key = "kitty-1/7"

private let png = Data([0x89, 0x50, 0x4E, 0x47, 1])
private let files = [
  PromptFile(name: "notes.txt", mime: "text/plain", bytes: Data("the notes".utf8)),
  PromptFile(name: "../my plan.md", mime: "text/markdown", bytes: Data("# plan".utf8)),
]

final class LiveHubTests: XCTestCase {
  private var tempDirs: [String] = []

  override func tearDown() {
    for d in tempDirs { try? FileManager.default.removeItem(atPath: d) }
    tempDirs = []
    super.tearDown()
  }

  private func tempDir(_ prefix: String) -> String {
    let d = hubTempDir(prefix)
    tempDirs.append(d)
    return d
  }

  /// A hub whose prompt files and images stay in a temp folder of the test's own.
  @MainActor
  private func makeHub(locate: Locate? = nil) -> LiveHub {
    let dir = tempDir("pocketterm_hub")
    return LiveHub(
      locate: locate, files: PromptFiles(Paths.join(dir, "files")), images: Paths.join(dir, "images"))
  }

  @MainActor
  func testASessionIsKnownByItsKittyWindowWithItsSnapshotAndSummary() async {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.hello(items: [
      ["id": "u", "k": "user", "t": "hi"], ["id": "a", "k": "assistant", "t": "**Done.** All tests pass\nmore"],
    ])
    await hubUntil { hub["kitty-1/7"] != nil }
    let s = hub["kitty-1/7"]!
    XCTAssertEqual(s.log.items.map(\.id), ["u", "a"])
    XCTAssertEqual(s.summary.preview, "Done. All tests pass")
    XCTAssertEqual(hub.projectName(s), "pocketterm")
  }

  @MainActor
  func testTwoProjectsWithTheSameFolderNameAreToldApartByTheFolderAbove() async {
    let hub = makeHub()
    var exts: [HubFakeExt] = []
    func at(_ n: Int, _ cwd: String) async -> LiveSession {
      let ext = HubFakeExt(hub)
      exts.append(ext)
      ext.ext(["t": "hello", "session": ["id": .string("s\(n)"), "cwd": .string(cwd)], "window": .string("kitty-1/\(n)")])
      await hubUntil { hub["kitty-1/\(n)"] != nil }
      return hub["kitty-1/\(n)"]!
    }

    let work = await at(1, "/Users/me/work/api")
    XCTAssertEqual(hub.projectName(work), "api", "alone, the folder name is enough")
    let mine = await at(2, "/Users/me/My Projects/api/")
    let windows = await at(3, #"C:\Users\me\Ünïcode Dev\web"#)
    let unknown = await at(4, "")
    XCTAssertEqual(hub.projectName(work), "work/api")
    XCTAssertEqual(hub.projectName(mine), "My Projects/api")
    XCTAssertEqual(hub.projectName(windows), "web")
    XCTAssertEqual(hub.projectName(unknown), "")
  }

  @MainActor
  func testFramesTheHubCantReadAreSkippedAndTheSessionGoesOn() async {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.ext([
      "t": "hello", "session": ["id": "s1", "cwd": "/tmp"], "window": "kitty-1/7",
      "items": [["k": "user"], "junk", ["id": "a", "k": "assistant", "t": "kept"]],
    ])
    ext.ext(["t": "item"])
    ext.ext(["t": "append", "text": "x"])
    ext.ext(["t": "meta", "title": 7])
    ext.ext(["t": "shiny-new-thing", "what": true])
    ext.raw("[1, 2]")
    ext.raw("not json")
    ext.ext(["t": "item", "item": ["id": "b", "k": "assistant", "t": "after"]])
    await hubUntil { hub["kitty-1/7"]?.log.items.count == 2 }
    XCTAssertEqual(hub["kitty-1/7"]!.log.items.map(\.text), ["kept", "after"])
  }

  @MainActor
  func testOutsideKittyTheKeyIsThePid() async {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.hello(window: nil)
    await hubUntil { hub["pid:42"] != nil }
  }

  @MainActor
  func testAReportedTermNamesTheWindowTmuxsPaneOverLeakedKittyVariables() async {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.ext([
      "t": "hello", "v": 1, "session": ["id": "s1", "cwd": "/Users/me/Dev/pocketterm"],
      // A newer extension still sends kitty's `window` from the leaked variables.
      "window": "kitty-23224/116",
      "term": [
        "TERM_PROGRAM": "tmux", "KITTY_WINDOW_ID": "116", "KITTY_PID": "23224",
        "TMUX": "/private/tmp/tmux-501/default,4226,0", "TMUX_PANE": "%0",
      ],
      "pid": 42, "items": [],
    ])
    await hubUntil { hub["tmux:default/0"] != nil }
    XCTAssertNil(hub["kitty-23224/116"])
  }

  @MainActor
  func testATermThatNamesNoWindowKeysTheSessionByPid() async {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.ext([
      "t": "hello", "v": 1, "session": ["id": "s1", "cwd": "/Users/me/Dev/pocketterm"], "window": "kitty-23224/116",
      "term": ["TERM_PROGRAM": "ghostty", "KITTY_WINDOW_ID": "116", "KITTY_PID": "23224", "tty": "/dev/ttys011"],
      "pid": 42, "items": [],
    ])
    await hubUntil { hub["pid:42"] != nil }
    XCTAssertNil(hub["kitty-23224/116"])
  }

  @MainActor
  func testGhosttyWindowsSharingAFolderATitleArrivingLaterClaimsItsWindow() async {
    func g(_ id: String, _ title: String) -> TermWindow {
      TermWindow(key: "ghostty:\(id)", title: title, tab: "", cwd: "/tmp/work", program: "", app: "ghostty")
    }
    let ghostty = HubListedGhostty([g("A", "π > work"), g("B", "π > work")])
    let terms = Terminals(home: "/nonexistent-pocketterm", ghostty: ghostty, snapshot: { Procs(parsePs("")) })
    let hub = makeHub(locate: LiveHub.locate(using: terms))
    func omp(_ pid: Int, id: String = "s1") -> HubFakeExt {
      let ext = HubFakeExt(hub)
      ext.ext([
        "t": "hello", "v": 1, "agent": "omp", "session": ["id": .string(id), "title": "", "cwd": "/tmp/work"],
        "term": ["TERM_PROGRAM": "ghostty", "tty": .string("/dev/ttys0\(pid)")], "pid": .int(pid), "items": [],
      ])
      return ext
    }

    let first = omp(41)
    let second = omp(42)
    await hubUntil { hub["pid:41"] != nil && hub["pid:42"] != nil }
    // Two untitled omps, two windows titled alike: neither is guessed.
    XCTAssertEqual(hub.sessions.map(\.window), [nil, nil])

    // The first prompt names the session, and omp the window after it.
    ghostty.listed[0] = g("A", "π > Fix missing playable sources")
    first.ext(["t": "meta", "title": "Fix missing playable sources"])
    await hubUntil { hub["pid:41"]?.window == "ghostty:A" && hub["pid:42"]?.window == "ghostty:B" }
    // Under the keys the phone knows, each naming its window.
    let pairs = Set(hub.sessions.map { "\($0.summary.toJson()["key"]!.string!) \($0.summary.toJson()["window"]!.string!)" })
    XCTAssertEqual(pairs, ["pid:41 ghostty:A", "pid:42 ghostty:B"])

    // /new in the first: the same window, under the same key.
    first.ext([
      "t": "hello", "v": 1, "agent": "omp", "session": ["id": "s9", "title": "", "cwd": "/tmp/work"],
      "term": ["TERM_PROGRAM": "ghostty", "tty": "/dev/ttys041"], "pid": 41, "items": [],
    ])
    await hubUntil { hub["pid:41"]?.id == "s9" }
    XCTAssertEqual(hub["pid:41"]!.window, "ghostty:A")
    XCTAssertNil(hub["ghostty:A"])
    _ = second
  }

  @MainActor
  func testSlashCommandsComeWithTheHelloAndChangeWithAMetaCtxAndCostReachThePhone() async throws {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.hello(commands: [["name": "new", "description": "Start a new session"], ["name": "review"]])
    await hubUntil { hub["kitty-1/7"] != nil }
    let s = hub["kitty-1/7"]!
    XCTAssertEqual(
      s.summary.commands, [LiveCommand(name: "new", description: "Start a new session"), LiveCommand(name: "review")])
    ext.ext(["t": "meta", "ctx": 40, "cost": 43.34])
    await hubUntil { s.ctx == 40 }
    XCTAssertEqual(s.commands.count, 2)
    let phone = LiveSummary(json: try JSON.parse(s.summary.toJson().encoded()).object!)!
    XCTAssertEqual(phone.ctx, 40)
    XCTAssertEqual(phone.cost, 43.34)
    ext.ext(["t": "meta", "commands": [["name": "skill:pdf", "description": "Read PDFs"]]])
    await hubUntil { s.commands.count == 1 }
    XCTAssertEqual(s.commands.first?.name, "skill:pdf")
  }

  @MainActor
  func testItemsAndStreamedTextBecomeOpsInOrder() async {
    let hub = makeHub()
    var ops: [LiveOp] = []
    let listener = hub.onOps { _, o in ops += o }
    defer { listener.cancel() }
    let ext = HubFakeExt(hub)
    ext.hello()
    ext.ext(["t": "item", "item": ["id": "a", "k": "assistant", "t": ""]])
    ext.ext(["t": "append", "id": "a", "text": "Hel"])
    ext.ext(["t": "append", "id": "a", "text": "lo"])
    ext.ext(["t": "append", "id": "nope", "text": "x"])
    await hubUntil { ops.count == 3 }
    let view = LiveView(epoch: hub["kitty-1/7"]!.log.epoch)
    XCTAssertTrue(view.apply(view.epoch, ops))
    XCTAssertEqual(view.items.map(\.text), ["Hello"])
  }

  @MainActor
  func testAFinishedRunAndAQuestionAreEventsARunThatWillGoOnIsNot() async {
    let hub = makeHub()
    let events = HubEventLog(hub)
    let ext = HubFakeExt(hub)
    ext.hello()
    ext.ext(["t": "busy", "busy": true])
    ext.ext(["t": "busy", "busy": false])
    ext.ext(["t": "busy", "busy": false, "summary": "All done"])
    ext.ext([
      "t": "ask",
      "ask": [
        "kind": "ask", "id": "call1",
        "questions": [["id": "db", "question": "Database?", "options": ["SQLite", "Postgres"]]],
      ],
    ])
    await hubUntil { events.events.count == 2 }
    XCTAssertEqual(events.finished, ["All done"])
    XCTAssertEqual(events.asked.first?.questions?.first?.options, ["SQLite", "Postgres"])
    XCTAssertEqual(hub["kitty-1/7"]!.summary.ask?.id, "call1")
    ext.ext(["t": "ask", "ask": nil])
    await hubUntil { hub["kitty-1/7"]!.ask == nil }
  }

  @MainActor
  func testAPlanReviewIsAnEventItsOptionsReadOffTheScreenUpdateTheAskWithoutAnother() async throws {
    let hub = makeHub()
    let events = HubEventLog(hub)
    var changes = 0
    let listener = hub.onChange { changes += 1 }
    defer { listener.cancel() }
    let ext = HubFakeExt(hub)
    ext.hello()
    ext.ext(["t": "ask", "ask": ["kind": "plan", "id": "call9", "title": "notes-plan"]])
    await hubUntil { events.events.count == 1 }
    let asked = events.asked[0]
    XCTAssertTrue(asked.isPlan)
    XCTAssertEqual(asked.text, "Plan ready: notes-plan")
    XCTAssertEqual(asked.options, [])

    let before = changes
    let read = LiveAsk.plan("call9", title: "notes-plan", options: ["Approve and execute", "Refine plan"], selected: 1)
    XCTAssertTrue(hub.updateAsk("kitty-1/7", "call9", read))
    XCTAssertEqual(changes, before + 1)
    XCTAssertEqual(hub["kitty-1/7"]!.summary.toJson()["ask"], .object(read.toJson()))
    // An ask that's no longer there isn't brought back.
    XCTAssertFalse(hub.updateAsk("kitty-1/7", "other", read))
    XCTAssertTrue(hub.updateAsk("kitty-1/7", "call9", nil))
    XCTAssertNil(hub["kitty-1/7"]!.ask)
    XCTAssertFalse(hub.updateAsk("kitty-1/7", "call9", read))
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(events.events.count, 1)
  }

  @MainActor
  func testAPickerReadOffTheScreenTakesAFreeAsksPlaceNeverOmpsAndMakesNoPush() async {
    let hub = makeHub()
    let events = HubEventLog(hub)
    let ext = HubFakeExt(hub)
    ext.hello()
    await hubUntil { hub["kitty-1/7"] != nil }
    let menu = LiveAsk.menu("menu-1", title: "Select theme", items: [MenuItem(label: "dark", detail: "")])
    XCTAssertTrue(hub.updateAsk("kitty-1/7", nil, menu))
    XCTAssertEqual(hub["kitty-1/7"]!.summary.ask?.isMenu, true)
    // Another picker opened from it (/model, then its thinking level) replaces it.
    let next = LiveAsk.menu("menu-2", title: "Thinking level", items: [MenuItem(label: "high", detail: "")])
    XCTAssertTrue(hub.updateAsk("kitty-1/7", "menu-1", next))
    // omp's own question wins, and a picker doesn't push it aside.
    ext.ext(["t": "ask", "ask": ["kind": "plan", "id": "call9", "title": "notes-plan"]])
    await hubUntil { hub["kitty-1/7"]!.ask?.isPlan ?? false }
    XCTAssertFalse(hub.updateAsk("kitty-1/7", nil, menu))
    XCTAssertFalse(hub.updateAsk("kitty-1/7", "menu-2", nil))
    XCTAssertEqual(hub["kitty-1/7"]!.ask?.id, "call9")
    await hubUntil { !events.asked.isEmpty }
    XCTAssertEqual(events.asked.map(\.id), ["call9"])
  }

  @MainActor
  func testAPromptReachesTheExtensionAndItsReplyCompletesItAnErrorReplyFailsIt() async throws {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.hello()
    await hubUntil { hub["kitty-1/7"] != nil }
    async let ok = hub.prompt("kitty-1/7", "go on", followUp: true)
    let req = await ext.request()
    XCTAssertEqual(req["t"], "prompt")
    XCTAssertEqual(req["text"], "go on")
    XCTAssertEqual(req["deliver"], "followUp")
    ext.ext(["t": "reply", "req": req["req"]!])
    _ = try await ok

    async let failing: Void = hub.abort("kitty-1/7")
    let abort = await ext.request()
    ext.ext(["t": "reply", "req": abort["req"]!, "error": "Nothing to stop."])
    do {
      try await failing
      XCTFail("no error")
    } catch let e as LiveException {
      XCTAssertEqual(e.message, "Nothing to stop.")
    }
  }

  // ------------------------------------------------------------ the queue

  @MainActor
  private func queued(_ hub: LiveHub) -> [String] { hub[key]!.summary.queue.map(\.text) }

  /// An omp session at work.
  @MainActor
  private func working(_ hub: LiveHub) async -> HubFakeExt {
    let ext = HubFakeExt(hub)
    ext.hello()
    ext.ext(["t": "busy", "busy": true])
    await hubUntil { hub[key]?.busy ?? false }
    return ext
  }

  /// The prompt the hub hands `ext` next, answered.
  @MainActor
  private func handed(_ ext: HubFakeExt) async -> JSONObject {
    let req = await ext.request()
    XCTAssertEqual(req["t"], "prompt")
    ext.ext(["t": "reply", "req": req["req"] ?? .null])
    return req
  }

  @MainActor
  func testAPromptSentToWaitGoesWhenTheRunEndsOnePerRunNeverLookingDoneBetween() async throws {
    let hub = makeHub()
    let events = HubEventLog(hub)
    let ext = await working(hub)
    let first = try await hub.prompt(key, "then the docs", followUp: true)
    try await hub.prompt(key, "then the changelog", followUp: true)
    XCTAssertNotNil(first)
    XCTAssertEqual(queued(hub), ["then the docs", "then the changelog"])
    XCTAssertEqual(hub[key]!.summary.queue.first?.id, first)

    ext.ext(["t": "busy", "busy": false, "summary": "Fixed."])
    let req = await handed(ext)
    XCTAssertEqual(req["text"], "then the docs")
    XCTAssertEqual(req["deliver"], "followUp", "an agent that started meanwhile keeps it for the run end")
    XCTAssertTrue(hub[key]!.busy, "working from the hand-off on")
    XCTAssertEqual(queued(hub), ["then the changelog"])

    ext.ext(["t": "busy", "busy": true])
    ext.ext(["t": "busy", "busy": false, "summary": "Docs done."])
    let second = await handed(ext)
    XCTAssertEqual(second["text"], "then the changelog")
    ext.ext(["t": "busy", "busy": true])
    ext.ext(["t": "busy", "busy": false, "summary": "All done."])
    await hubUntil { !hub[key]!.busy }
    XCTAssertEqual(queued(hub), [])
    try await Task.sleep(nanoseconds: 20_000_000)
    XCTAssertEqual(events.finished, ["All done."])
  }

  @MainActor
  func testASteerAndAPromptToAnAgentAtRestGoNowClaudeQueuesAnyPromptWhileItWorks() async throws {
    let hub = makeHub()
    let ext = await working(hub)
    async let steer = hub.prompt(key, "look at the tests too")
    let req = await handed(ext)
    let steered = try await steer
    XCTAssertNil(steered)
    XCTAssertEqual(req["deliver"], "steer")

    let claude = HubFakeExt(hub)
    claude.ext([
      "t": "hello", "agent": "claude", "session": ["id": "c1", "cwd": "/tmp"], "window": "kitty-1/8", "busy": true,
    ])
    await hubUntil { hub["kitty-1/8"]?.busy ?? false }
    let waits = try await hub.prompt("kitty-1/8", "and then this")
    XCTAssertNotNil(waits)
    XCTAssertEqual(hub["kitty-1/8"]!.summary.queue.map(\.text), ["and then this"])
    do {
      try await hub.sendQueuedNow("kitty-1/8", hub["kitty-1/8"]!.summary.queue[0].id)
      XCTFail("Claude Code took a steer")
    } catch is LiveException {}
  }

  @MainActor
  func testStopHoldsTheQueueUntilResumeSoDoesARunStoppedAtTheComputer() async throws {
    let hub = makeHub()
    let ext = await working(hub)
    try await hub.prompt(key, "next", followUp: true)
    async let stopping: Void = hub.abort(key)
    let abort = await ext.request()
    XCTAssertEqual(abort["t"], "abort")
    ext.ext(["t": "reply", "req": abort["req"]!])
    ext.ext(["t": "busy", "busy": false, "stopped": true])
    try await stopping
    await hubUntil { !hub[key]!.busy }
    XCTAssertTrue(hub[key]!.summary.paused)
    XCTAssertEqual(queued(hub), ["next"])

    try hub.pauseQueue(key, paused: false)
    let resumed = await handed(ext)
    XCTAssertEqual(resumed["text"], "next")

    // Esc at the computer: the extension says the run was stopped.
    ext.ext(["t": "busy", "busy": true])
    await hubUntil { hub[key]!.busy && queued(hub).isEmpty }
    try await hub.prompt(key, "after that", followUp: true)
    ext.ext(["t": "busy", "busy": false, "stopped": true])
    await hubUntil { !hub[key]!.busy }
    XCTAssertTrue(hub[key]!.summary.paused)
    XCTAssertEqual(queued(hub), ["after that"])
  }

  @MainActor
  func testARunThatEndedInAnErrorShowsFailedUntilTheNextRunStarts() async {
    let hub = makeHub()
    let ext = await working(hub)
    ext.ext(["t": "busy", "busy": false, "failed": true])
    await hubUntil { !hub[key]!.busy }
    XCTAssertTrue(hub[key]!.summary.failed)
    XCTAssertEqual(LiveSummary(json: hub[key]!.summary.toJson())?.failed, true, "it reaches the phone")

    ext.ext(["t": "busy", "busy": true])
    await hubUntil { hub[key]!.busy }
    XCTAssertFalse(hub[key]!.summary.failed)

    // Stopped is not failed: the phone hears nothing of it.
    ext.ext(["t": "busy", "busy": false, "stopped": true])
    await hubUntil { !hub[key]!.busy }
    XCTAssertFalse(hub[key]!.summary.failed)
    XCTAssertNil(hub[key]!.summary.toJson()["failed"])
  }

  @MainActor
  func testEditsMovesAndRemovalsChangeWhatGoesAnEmptiedQueueIsNoLongerPaused() async throws {
    let hub = makeHub()
    let ext = await working(hub)
    let a = try await hub.prompt(key, "a", followUp: true)!
    let b = try await hub.prompt(key, "b", followUp: true)!
    let c = try await hub.prompt(key, "c", followUp: true)!
    try hub.editQueued(key, b, "b, but better")
    try hub.moveQueued(key, c, to: 0)
    try hub.removeQueued(key, a)
    XCTAssertEqual(queued(hub), ["c", "b, but better"])
    XCTAssertThrowsError(try hub.editQueued(key, c, "  "), "nothing left to send") { XCTAssert($0 is LiveException) }
    XCTAssertThrowsError(try hub.removeQueued(key, a), "gone already") { XCTAssert($0 is LiveException) }

    try hub.pauseQueue(key, paused: true)
    try hub.removeQueued(key, c)
    try hub.removeQueued(key, b)
    XCTAssertFalse(hub[key]!.summary.paused)

    try await hub.prompt(key, "d", followUp: true)
    ext.ext(["t": "busy", "busy": false])
    let d = await handed(ext)
    XCTAssertEqual(d["text"], "d")
  }

  @MainActor
  func testSendNowSteersTheRunWithItOutOfTheQueue() async throws {
    let hub = makeHub()
    let ext = await working(hub)
    try await hub.prompt(key, "first", followUp: true)
    let now = try await hub.prompt(key, "right away", followUp: true)!
    async let sending: Void = hub.sendQueuedNow(key, now)
    let req = await handed(ext)
    try await sending
    XCTAssertEqual(req["text"], "right away")
    XCTAssertEqual(req["deliver"], "steer")
    XCTAssertEqual(queued(hub), ["first"])
  }

  @MainActor
  func testOneTheAgentDoesntTakeGoesBackFirstAndTheQueuePauses() async throws {
    let hub = makeHub()
    let ext = await working(hub)
    try await hub.prompt(key, "one", followUp: true)
    try await hub.prompt(key, "two", followUp: true)
    ext.ext(["t": "busy", "busy": false])
    let req = await ext.request()
    ext.ext(["t": "reply", "req": req["req"]!, "error": "No model."])
    await hubUntil { !hub[key]!.busy }
    XCTAssertEqual(queued(hub), ["one", "two"])
    XCTAssertTrue(hub[key]!.summary.paused)
  }

  @MainActor
  func testTheSameAgentBackInTheSameWindowKeepsTheQueue() async throws {
    let hub = makeHub()
    let ext = await working(hub)
    try await hub.prompt(key, "still wanted", followUp: true)
    ext.end()
    await hubUntil { hub[key] == nil }

    let again = HubFakeExt(hub)
    again.ext(["t": "hello", "session": ["id": "s1", "cwd": "/tmp"], "window": .string(key), "busy": true])
    await hubUntil { hub[key] != nil }
    XCTAssertEqual(queued(hub), ["still wanted"])
  }

  @MainActor
  func testItHoldsAtMostMaxQueuedPrompts() async throws {
    let hub = makeHub()
    _ = await working(hub)
    for i in 0..<LiveHub.maxQueued { try await hub.prompt(key, "p\(i)", followUp: true) }
    do {
      try await hub.prompt(key, "one more", followUp: true)
      XCTFail("the queue took one more")
    } catch is LiveException {}
    XCTAssertEqual(queued(hub).count, LiveHub.maxQueued)
  }

  // ------------------------------------------------------------ a prompt with files

  /// The paths `text` names as @path or @"path".
  private func mentioned(_ text: String) -> [String] {
    let re = try! NSRegularExpression(pattern: #"@(?:"([^"]+)"|(\S+))"#)
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
      m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range(at: 2))
    }
  }

  @MainActor
  func testOmpGetsFilesNamedInTheTextAsPathSavedOnThisComputerAndTheImagesInline() async throws {
    let dir = tempDir("pocketterm_hub_files")
    let hub = LiveHub(files: PromptFiles(dir), images: Paths.join(dir, "images"))
    let ext = HubFakeExt(hub)
    ext.hello()
    await hubUntil { hub["kitty-1/7"] != nil }
    async let done = hub.prompt(
      "kitty-1/7", "read these", images: [PromptImage(bytes: png, mimeType: "image/png")], files: files)
    let req = await ext.request()
    ext.ext(["t": "reply", "req": req["req"]!])
    _ = try await done

    let text = req["text"]!.string!
    XCTAssertTrue(text.hasPrefix("read these\n\n@"))
    let paths = mentioned(text)
    XCTAssertEqual(paths.map(Paths.basename), ["notes.txt", "my plan.md"])
    XCTAssertTrue(text.contains("@\"\(paths.last!)\""), "a path with a space is quoted")
    XCTAssertEqual(try paths.map { try String(contentsOfFile: $0, encoding: .utf8) }, ["the notes", "# plan"])
    for f in paths { XCTAssertTrue(Paths.isWithin(dir, f), f) }
    XCTAssertEqual(req["images"], [["data": .string(png.base64EncodedString()), "mimeType": "image/png"]])
    XCTAssertNil(req["docs"])
  }

  @MainActor
  func testClaudeCodeGetsFilesNamedInTheTextAndTheirPathsToReadWithoutAsking() async throws {
    let dir = tempDir("pocketterm_hub_files")
    let hub = LiveHub(files: PromptFiles(dir), images: Paths.join(dir, "images"))
    let ext = HubFakeExt(hub)
    ext.ext([
      "t": "hello", "v": 1, "agent": "claude", "session": ["id": "c1", "title": "", "cwd": "/Users/me/Dev/pocketterm"],
      "window": "kitty-1/7", "items": [],
    ])
    await hubUntil { hub["kitty-1/7"]?.agent == .claude }
    async let done = hub.prompt("kitty-1/7", "", images: [PromptImage(bytes: png, mimeType: "image/png")], files: files)
    let req = await ext.request()
    ext.ext(["t": "reply", "req": req["req"]!])
    _ = try await done

    let docs = req["docs"]!.strings!
    XCTAssertEqual(mentioned(req["text"]!.string!), docs, "nothing but the mentions, with no words")
    XCTAssertEqual(docs.map(Paths.basename), ["notes.txt", "my plan.md"])
    XCTAssertEqual(req["images"], [])
    let image = req["files"]!.strings!
    XCTAssertEqual(image.count, 1)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image[0])), png, "the image, from disk")
    XCTAssertEqual(req["deliver"], "followUp")
  }

  @MainActor
  func testImagesAndFilesOlderThanADayGoWhenPocketTermStartsNewerOnesStay() async throws {
    let dir = tempDir("pocketterm_hub_files")
    let images = Paths.join(dir, "images")
    let filesDir = Paths.join(dir, "files")
    let fm = FileManager.default
    try fm.createDirectory(atPath: images, withIntermediateDirectories: false)
    try fm.createDirectory(atPath: filesDir, withIntermediateDirectories: false)
    let old = Date().addingTimeInterval(-2 * 24 * 60 * 60)
    let oldImage = Paths.join(images, "old.png")
    try png.write(to: URL(fileURLWithPath: oldImage))
    try fm.setAttributes([.modificationDate: old], ofItemAtPath: oldImage)
    let newImage = Paths.join(images, "new.png")
    try png.write(to: URL(fileURLWithPath: newImage))
    let oldFolder = Paths.join(filesDir, "old")
    try fm.createDirectory(atPath: oldFolder, withIntermediateDirectories: false)
    try Data("the notes".utf8).write(to: URL(fileURLWithPath: Paths.join(oldFolder, "notes.txt")))
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 946_684_800)], ofItemAtPath: oldFolder)

    _ = LiveHub(files: PromptFiles(filesDir), images: images)
    await hubUntil { !fm.fileExists(atPath: oldFolder) }
    XCTAssertFalse(fm.fileExists(atPath: oldImage))
    XCTAssertTrue(fm.fileExists(atPath: newImage))
  }

  // ------------------------------------------------------------ transcripts

  @MainActor
  func testOlderItemsArriveAsOpsAboveTheOldest() async throws {
    let hub = makeHub()
    var ops: [LiveOp] = []
    let listener = hub.onOps { _, o in ops += o }
    defer { listener.cancel() }
    let ext = HubFakeExt(hub)
    ext.ext([
      "t": "hello", "session": ["id": "s"], "window": "kitty-1/7", "items": [["id": "c", "k": "user", "t": "c"]],
      "older": true,
    ])
    await hubUntil { hub["kitty-1/7"] != nil }
    async let done: Void = hub.older("kitty-1/7")
    let req = await ext.request()
    ext.ext([
      "t": "reply", "req": req["req"]!,
      "items": [["id": "a", "k": "user", "t": "a"], ["id": "b", "k": "user", "t": "b"]], "older": false,
    ])
    try await done
    XCTAssertEqual(hub["kitty-1/7"]!.log.items.map(\.id), ["a", "b", "c"])
    XCTAssertFalse(hub["kitty-1/7"]!.log.older)
    XCTAssertEqual(ops.count, 2)
  }

  @MainActor
  func testNewInTheSameOmpStartsANewTranscriptUnderTheSameKey() async {
    let hub = makeHub()
    let ext = HubFakeExt(hub)
    ext.hello(items: [["id": "x", "k": "user", "t": "old"]])
    await hubUntil { hub["kitty-1/7"] != nil }
    let epoch = hub["kitty-1/7"]!.log.epoch
    ext.hello(id: "s2")
    await hubUntil { hub["kitty-1/7"]!.id == "s2" }
    XCTAssertNotEqual(hub["kitty-1/7"]!.log.epoch, epoch)
    XCTAssertEqual(hub["kitty-1/7"]!.log.items.count, 0)
  }

  @MainActor
  func testANewOmpInTheSameWindowReplacesTheOldOneItsEndRemovesItAndFailsWhatWaits() async {
    let hub = makeHub()
    let first = HubFakeExt(hub)
    first.hello()
    await hubUntil { hub["kitty-1/7"] != nil }
    let pending = Task { () -> Bool in
      do {
        try await hub.prompt("kitty-1/7", "x")
        return false
      } catch {
        return error is LiveException
      }
    }
    _ = await first.request()
    let second = HubFakeExt(hub)
    second.hello(id: "s9")
    await hubUntil { hub["kitty-1/7"]?.id == "s9" }
    let failed = await pending.value
    XCTAssertTrue(failed)
    XCTAssertTrue(first.closed, "the old connection is closed")
    second.end()
    await hubUntil { hub["kitty-1/7"] == nil }
    XCTAssertTrue(hub.sessions.isEmpty)
  }
}
#endif
