import Foundation
import XCTest

@testable import PocketTermKit

/// terminal_remote_test.dart.
@MainActor
final class TerminalRemoteTests: XCTestCase {
  var dir: URL!
  var sent: [(String, JSONObject)] = []
  let client = FakeServer()

  override func setUp() async throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm_terminal_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    sent = []
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: dir)
  }

  func remote(_ desktopId: String = "abcd1234") -> TerminalRemote {
    TerminalRemote(
      client, supportDir: dir, desktopId: desktopId, key: ChannelKey(Data(repeating: 7, count: 32))!,
      send: { [weak self] e, p in self?.sent.append((e, p)) }, from: "phone")
  }

  func syncs() -> [JSONObject] { sent.filter { $0.0 == "sync" }.map(\.1) }
  func runs() -> [JSONObject] { sent.filter { $0.0 == "run" }.map(\.1) }

  func item(_ id: String, _ text: String, _ order: Int, _ seq: Int) -> JSON {
    .object(LiveItem(id: id, kind: .assistant, text: text, order: order, seq: seq).toJson())
  }

  func state(epoch: String = "e1", seq: Int = 2) -> JSONObject {
    [
      "windows": [["key": "kitty-1/1", "title": "omp", "cwd": "/Users/me/x", "program": "omp"]],
      "sessions": [
        [
          "key": "kitty-1/1", "id": "s1", "window": "kitty-1/1", "title": "Fix it", "cwd": "/Users/me/x",
          "epoch": .string(epoch), "seq": .int(seq),
        ]
      ],
      "projects": ["/Users/me/x"],
      "roots": ["/Users/me"],
      "home": "/Users/me",
    ]
  }

  func items(to: String = "phone", seq: Int = 2, last: Bool = true) -> JSONObject {
    [
      "to": .string(to), "session": "kitty-1/1", "epoch": "e1", "seq": .int(seq), "reset": true,
      "items": [item("a", "one", 0, 1), item("b", "two", 1, 2)], "last": .bool(last), "older": false,
    ]
  }

  /// Lets tasks started by the test run up to their first wait.
  func settle() async {
    for _ in 0..<20 { await Task.yield() }
  }

  func testCacheShowsLastStateBeforeTheComputerAnswers() {
    let a = remote()
    a.handle("state", state())
    a.handle("items", items())
    a.flush()

    let b = remote()
    XCTAssertTrue(b.fromCache)
    XCTAssertNotNil(b.stateAt)
    XCTAssertEqual(b.home, "/Users/me")
    XCTAssertEqual(b.projects, ["/Users/me/x"])
    XCTAssertEqual(b.roots, ["/Users/me"])
    XCTAssertEqual(b.windows.map(\.key), ["kitty-1/1"])
    XCTAssertEqual(b.sessions.map(\.title), ["Fix it"])
    let v = b.view("kitty-1/1")!
    XCTAssertEqual(v.epoch, "e1")
    XCTAssertEqual(v.seq, 2)
    XCTAssertEqual(v.items.map(\.text), ["one", "two"])
    b.handle("state", state())
    XCTAssertFalse(b.fromCache)
  }

  func testEachComputerHasItsOwnCache() {
    let a = remote()
    a.handle("state", state())
    a.handle("items", items())
    a.flush()
    let other = remote("zzzz9999")
    XCTAssertFalse(other.fromCache)
    XCTAssertTrue(other.sessions.isEmpty)
    XCTAssertNil(other.view("kitty-1/1"))
  }

  func testTerminalsAndFoldersSurviveTheCache() {
    let a = remote()
    var s = state()
    s["opensIn"] = "Ghostty (in tmux)"
    s["terminals"] = [
      ["id": "ghostty", "label": "Ghostty", "state": "limited", "note": "no screen"],
      ["id": "tmux", "label": "tmux", "state": "ready", "note": ""],
    ]
    a.handle("state", s)
    XCTAssertEqual(a.opensIn, "Ghostty (in tmux)")
    XCTAssertEqual(a.terminals.map(\.id), ["ghostty", "tmux"])
    XCTAssertEqual(a.terminals.map(\.state), [.limited, .ready])
    XCTAssertEqual(a.terminals.map(\.note), ["no screen", ""])
    a.flush()

    let b = remote()
    XCTAssertEqual(b.opensIn, "Ghostty (in tmux)")
    XCTAssertEqual(b.terminals.map(\.label), ["Ghostty", "tmux"])
    var noRoots = state()
    noRoots["roots"] = []
    b.handle("state", noRoots)
    XCTAssertEqual(b.roots, [])
    var older = state()
    older["roots"] = nil
    b.handle("state", older)
    XCTAssertNil(b.opensIn)
    XCTAssertTrue(b.terminals.isEmpty)
    XCTAssertNil(b.roots, "no Project folders at all: it can't make a project")
  }

  func testAgentsSurviveTheCache() {
    let a = remote()
    var s = state()
    s["agents"] = ["omp": "installed", "claude": "off", "codex": "installed", "other": "weird"]
    a.handle("state", s)
    XCTAssertEqual(a.agents, [.omp: .installed, .claude: .off])
    a.flush()
    let b = remote()
    XCTAssertEqual(b.agents, [.omp: .installed, .claude: .off])
    s["agents"] = ["omp": "bogus", "claude": "missing"]
    b.handle("state", s)
    XCTAssertEqual(b.agents, [.claude: .missing])
    b.handle("state", state())
    XCTAssertTrue(b.agents.isEmpty)
  }

  func testWatchingAsksForWhatTheCachedViewMisses() {
    let a = remote()
    a.handle("items", items())
    a.flush()
    _ = remote().watchSession("kitty-1/1")
    XCTAssertEqual(syncs(), [["from": "phone", "session": "kitty-1/1", "epoch": "e1", "since": 2]])
  }

  func testGapInLiveOpsSyncs() {
    let r = remote()
    _ = r.watchSession("kitty-1/1")
    XCTAssertEqual(syncs().first?["since"], 0)
    r.handle("items", items())
    sent.removeAll()
    r.handle("live", ["session": "kitty-1/1", "epoch": "e1", "ops": [["s": 4, "id": "b", "a": "!"]]])
    XCTAssertEqual(syncs(), [["from": "phone", "session": "kitty-1/1", "epoch": "e1", "since": 2]])
  }

  func testLiveOpsDuringASyncWaitThenApply() {
    let r = remote()
    _ = r.watchSession("kitty-1/1")
    r.handle("live", ["session": "kitty-1/1", "epoch": "e1", "ops": [["s": 3, "id": "b", "a": " more"]]])
    r.handle("items", items())
    XCTAssertEqual(r.view("kitty-1/1")!.items.last?.text, "two more")
    XCTAssertEqual(r.view("kitty-1/1")!.seq, 3)
    XCTAssertEqual(syncs().count, 1)
  }

  func testNewEpochSyncs() {
    let r = remote()
    _ = r.watchSession("kitty-1/1")
    r.handle("items", items())
    sent.removeAll()
    r.handle("state", state(epoch: "e2", seq: 1))
    XCTAssertEqual(syncs().first?["epoch"], "e1")
    XCTAssertEqual(syncs().count, 1)
  }

  func testItemsForAnotherPhoneAreIgnored() {
    let r = remote()
    r.handle("items", items(to: "other"))
    XCTAssertNil(r.view("kitty-1/1"))
  }

  func testScreenDiffs() {
    let r = remote()
    _ = r.watchWindow("w")
    sent.removeAll()
    r.handle("screen", ["window": "w", "v": 1, "lines": ["a", "b", "c"]])
    r.handle("screen", ["window": "w", "v": 2, "diff": .object(ScreenDiff(drop: 1, keep: 2, tail: ["d"]).toJson())])
    XCTAssertEqual(r.screen("w")?.lines, ["b", "c", "d"])
    XCTAssertEqual(r.screen("w")?.base, 1)
    XCTAssertTrue(syncs().isEmpty)
    r.handle("screen", ["window": "w", "v": 4, "diff": .object(ScreenDiff(drop: 0, keep: 3, tail: ["e"]).toJson())])
    XCTAssertEqual(r.screen("w")?.lines, ["b", "c", "d"])
    XCTAssertEqual(syncs(), [["from": "phone", "window": "w"]])

    let s = remote()
    s.handle("screen", ["window": "w", "v": 1, "lines": ["a", "b", "c", "d"]])
    s.handle("screen", ["window": "w", "v": 2, "lines": ["c", "d", "e", "f"]])
    XCTAssertEqual(s.screen("w")?.base, 2)
  }

  func testClosingAWatchGoesBack() {
    let r = remote()
    let unwatchSession = r.watchSession("s")
    let unwatchWindow = r.watchWindow("w")
    XCTAssertNil(r.watchedSession)
    XCTAssertEqual(r.watchedWindow, "w")
    unwatchWindow()
    XCTAssertEqual(r.watchedSession, "s")
    XCTAssertNil(r.watchedWindow)
    unwatchSession()
    XCTAssertNil(r.watchedSession)
  }

  func testOldSessionFilesArePruned() throws {
    let a = remote()
    a.handle("items", items())
    a.flush()
    let sessions = dir.appendingPathComponent("terminal/abcd1234/sessions")
    let file = try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil).first!
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-15 * 86400)], ofItemAtPath: file.path)
    XCTAssertNil(remote().view("kitty-1/1"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testLaunchUnderAnEndedSessionsKeyStartsFresh() async throws {
    let a = remote()
    a.handle("items", items())
    a.flush()
    let r = remote()
    var s = state()
    s["sessions"] = []
    r.handle("state", s)
    XCTAssertNotNil(r.view("kitty-1/1"))

    let launched = Task { try await r.launch("/Users/me/x", startAgent: true) }
    await settle()
    let run = runs().last!
    XCTAssertEqual(run["op"], "launch")
    r.handle("ran", ["id": run["id"]!, "window": "kitty-1/1", "where": "a new kitty window"])
    let opened = try await launched.value
    XCTAssertEqual(opened.window, "kitty-1/1")
    XCTAssertEqual(opened.where, "a new kitty window")
    XCTAssertNil(r.view("kitty-1/1"))
    r.flush()
    XCTAssertNil(remote().view("kitty-1/1"))
  }

  func testUnansweredPromptGoesAgainUnderTheSameId() async throws {
    let r = remote()
    r.handle("state", state())
    r.answerWait = 0.05

    do {
      try await r.prompt("kitty-1/1", "fix it")
      XCTFail("answered")
    } catch is TerminalException {}
    let first = runs().last!["id"]!
    let again = Task { try await r.prompt("kitty-1/1", "fix it") }
    await settle()
    XCTAssertEqual(runs().last!["id"], first)
    r.handle("ran", ["id": first, "repeat": true])
    _ = try await again.value

    let next = Task { try await r.prompt("kitty-1/1", "fix it") }
    await settle()
    XCTAssertNotEqual(runs().last!["id"], first)
    r.handle("ran", ["id": runs().last!["id"]!])
    _ = try await next.value

    do {
      try await r.prompt("kitty-1/1", "one")
      XCTFail("answered")
    } catch is TerminalException {}
    let one = runs().last!["id"]!
    do {
      try await r.prompt("kitty-1/1", "two")
      XCTFail("answered")
    } catch is TerminalException {}
    XCTAssertNotEqual(runs().last!["id"], one)
  }

  func testPromptSealsImagesAndFilesForTheirPaths() async throws {
    let r = remote()
    r.handle("state", state())
    let image = Data([0x89, 0x50, 0x4E, 0x47])
    let file = PromptFile(name: "notes.txt", mime: "text/plain", bytes: Data("hello".utf8))
    let prompted = Task { try await r.prompt("kitty-1/1", "look", images: [image], files: [file], followUp: true) }
    await settle()
    let run = runs().last!
    XCTAssertEqual(run["deliver"], "followUp")
    let path = run["images"]![0]!.string!
    let key = ChannelKey(Data(repeating: 7, count: 32))!
    XCTAssertEqual(openBytes(key, client.blobs[path]!, imageAad(path)), image)
    let sentFile = run["files"]![0]!
    XCTAssertEqual(sentFile["name"], "notes.txt")
    XCTAssertEqual(openBytes(key, client.blobs[sentFile["path"]!.string!]!, imageAad(sentFile["path"]!.string!)), file.bytes)
    r.handle("ran", ["id": run["id"]!, "queued": "q1"])
    let queued = try await prompted.value
    XCTAssertEqual(queued, "q1")
  }

  func testCreateProbeSwitch() async throws {
    let r = remote()
    r.handle("state", state())
    XCTAssertEqual(r.roots, ["/Users/me"])

    let made = Task { try await r.create("/Users/me", "new", startAgent: false) }
    await settle()
    var run = runs().last!
    XCTAssertEqual(run["op"], "create")
    XCTAssertEqual(run["root"], "/Users/me")
    XCTAssertEqual(run["name"], "new")
    XCTAssertEqual(run["agent"], false)
    r.handle("ran", ["id": run["id"]!, "window": "kitty-1/2"])
    let opened = try await made.value
    XCTAssertEqual(opened.window, "kitty-1/2")
    XCTAssertEqual(opened.where, "", "an older computer doesn't say where")

    let busy = Task { try await r.probe("kitty-1/1") }
    await settle()
    run = runs().last!
    XCTAssertEqual(run["op"], "probe")
    r.handle("ran", ["id": run["id"]!, "busy": true])
    let isBusy = try await busy.value
    XCTAssertTrue(isBusy)

    let switched = Task { try await r.switchToConversation("kitty-1/1", .claude) }
    await settle()
    run = runs().last!
    XCTAssertEqual(run["agent"], "claude")
    r.handle("ran", ["id": run["id"]!])
    try await switched.value

    let failed = Task { try await r.switchToConversation("kitty-1/1", .omp) }
    await settle()
    r.handle("ran", ["id": runs().last!["id"]!, "error": "omp didn't quit."])
    do {
      try await failed.value
      XCTFail("no error")
    } catch let e as TerminalException {
      XCTAssertEqual(e.message, "omp didn't quit.")
    }
  }
}
