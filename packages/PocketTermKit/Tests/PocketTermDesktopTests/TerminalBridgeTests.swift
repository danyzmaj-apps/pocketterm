#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

@testable import PocketTermDesktop

final class TerminalBridgeTests: XCTestCase {
  private let nowhere = "/nonexistent-pocketterm"

  /// Terminals that touch nothing on this Mac; `tmux`: an executable that exists (/bin/sh stands in).
  private func terms(tmux: Bool = false) -> Terminals {
    Terminals(
      home: nowhere, kitty: Kitty(home: nowhere, socketDir: nowhere, restoreFront: false),
      tmux: Tmux(executable: tmux ? "/bin/sh" : "\(nowhere)/tmux", socketDirs: []),
      wezterm: WezTerm(executable: "\(nowhere)/wezterm", socketDir: nowhere),
      ghostty: Ghostty(appPath: "\(nowhere)/Ghostty.app"))
  }

  private let ghosttyKey = "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074"

  // ------------------------------------------------------------ answering an ask from the phone

  func testAnsweringWorksWhereTheScreenCanBeReadAndKeysPressed() {
    let terms = terms()
    for key in ["kitty-1/2", "tmux:default/0", "wezterm:9/1"] { XCTAssertNil(cantAnswer(terms, key), key) }
  }

  func testGhosttyCantShowItsScreenTmuxIsTheWayOut() {
    XCTAssertTrue(cantAnswer(terms(tmux: true), ghosttyKey)!.contains("run in tmux there"))
    let ghostty = cantAnswer(terms(), ghosttyKey)!
    XCTAssertTrue(ghostty.hasPrefix("Ghostty can't show its screen"), ghostty)
    XCTAssertTrue(ghostty.contains("brew install tmux"))
  }

  func testThePhoneHearsOfInstalledTerminalsAndOfTmuxEvenWhenMissing() {
    let statuses = [
      TermStatus("kitty", "kitty", .ready), TermStatus("tmux", "tmux", .missing, note: "Install tmux"),
      TermStatus("wezterm", "WezTerm", .missing), TermStatus("ghostty", "Ghostty", .limited),
    ]
    XCTAssertEqual(phoneTerminals(statuses).map(\.id), ["kitty", "tmux", "ghostty"])
  }

  // ------------------------------------------------------------ what goes to the phone fits under the server frame

  private func size(_ json: JSON) -> Int { json.encoded().utf8.count }

  private let cmds: JSON = .array(
    (0..<90).map { i in .strings(["command-\(i)", "What command \(i) does, in up to eighty characters or so, as omp says"]) })

  private func state(sessions: Int = 60, projects: Int = 5000, windows: Int = 80) -> JSONObject {
    [
      "windows": .array(
        (0..<windows).map { i in
          ["key": .string("kitty-1/\(i)"), "title": .string("π > 中文 window \(i) 😀"), "cwd": .string("/Users/me/p \(i)")]
        }),
      "sessions": .array(
        (0..<sessions).map { i in
          ["key": .string("kitty-1/\(i)"), "id": .string("s\(i)"), "title": .string("Fix \(i)"), "cmds": cmds]
        }),
      "projects": .strings((0..<projects).map { "/Users/me/Dev/some-organisation/project-number-\($0)" }),
      "home": "/Users/me",
    ]
  }

  func testASmallStateGoesAsItIs() {
    let s = state(sessions: 2, projects: 10)
    XCTAssertEqual(TerminalBridge.fitState(s, watched: []), s)
  }

  func testManySessionsAndRepositoriesUnwatchedCommandsGoFirstThenRepositoriesPastWhatFits() {
    let fit = TerminalBridge.fitState(state(), watched: ["kitty-1/3"])
    XCTAssertLessThanOrEqual(size(.object(fit)), 150_000)
    let sessions = fit["sessions"]!.array!.map(\.object!)
    XCTAssertEqual(sessions.count, 60, "every session is still listed")
    XCTAssertEqual(sessions.filter { $0["cmds"] != nil }.map { $0["key"] }, ["kitty-1/3"])
    XCTAssertEqual(sessions[3]["cmds"], cmds, "the watched one keeps its commands whole")
    XCTAssertEqual(fit["windows"]!.array!.count, 80)
    let projects = fit["projects"]!.array!
    XCTAssertFalse(projects.isEmpty)
    XCTAssertLessThan(projects.count, 5000)
    XCTAssertEqual(projects.first, "/Users/me/Dev/some-organisation/project-number-0")
  }

  func testWithNothingElseLeftToCutWindowsGoFromTheEnd() {
    let fit = TerminalBridge.fitState(state(projects: 0, windows: 4000), watched: [], maxBytes: 100_000)
    XCTAssertLessThanOrEqual(size(.object(fit)), 100_000)
    XCTAssertEqual(fit["windows"]!.array!.first?["key"], "kitty-1/0")
  }

  func testUnwatchedSessionsQueuedPromptsKeepTheirStartBeforeAnythingAPhoneShowsGoes() {
    let long = Array(repeating: "word", count: 4000).joined(separator: " ")
    var s = state(sessions: 8, projects: 100)
    s["sessions"] = .array(
      s["sessions"]!.array!.map { sj in
        var session = sj.object!
        let key = session["key"]!.string!
        session["queue"] = .array((0..<4).map { i in ["id": .string("\(key)-\(i)"), "t": .string(long), "im": 1] })
        return .object(session)
      })
    let fit = TerminalBridge.fitState(s, watched: ["kitty-1/3"])
    XCTAssertLessThanOrEqual(size(.object(fit)), 150_000)
    let sessions = fit["sessions"]!.array!.map(\.object!)
    let watched = sessions[3]["queue"]!.array!.map(\.object!)
    XCTAssertTrue(watched.allSatisfy { $0["t"]?.string == long }, "the session a phone shows keeps them whole")
    XCTAssertTrue(watched.allSatisfy { $0["c"] == nil })
    let other = LiveSummary(json: sessions[0])!.queue
    XCTAssertTrue(other.allSatisfy(\.cut))
    XCTAssertTrue(other[0].text.hasPrefix("word word"))
    XCTAssertLessThan(other[0].text.count, long.count)
    XCTAssertEqual(other[0].images, 1)
    XCTAssertEqual(fit["projects"]!.array!.count, 100, "nothing else had to go")
  }

  func testAScreenKeepsItsNewestLinesASingleLineTooLongKeepsItsStart() {
    let lines = (0..<5000).map { "\u{1b}[38;2;1;2;3m\($0) 中文 😀\u{1b}[0m" }
    let fit = TerminalBridge.fitLines(lines, 60000)
    XCTAssertLessThanOrEqual(size(.strings(fit)), 60000)
    XCTAssertEqual(fit.last, lines.last)
    XCTAssertEqual(fit, Array(lines[(lines.count - fit.count)...]))
    let long = TerminalBridge.fitLines([String(repeating: "x", count: 200_000)], 60000)
    XCTAssertLessThanOrEqual(size(.strings(long)), 60000)
    XCTAssertTrue(long[0].hasPrefix("xxx"))
    XCTAssertEqual(TerminalBridge.fitLines([], 60000), [])
  }

  // ------------------------------------------------------------ errors and refusals

  func testAnErrorOnlyWhenNothingShowsAndNoTerminalIsUsableTheSetupOne() {
    let setup = TermStatus("kitty", "kitty", .setup, note: "kitty isn't listening.")
    let idle = TermStatus("ghostty", "Ghostty", .idle)
    let limited = TermStatus("wezterm", "WezTerm", .limited)
    XCTAssertEqual(terminalsError([idle, setup], nothingShown: true), "kitty isn't listening.")
    XCTAssertNil(terminalsError([idle, setup], nothingShown: false))
    XCTAssertNil(terminalsError([setup, limited], nothingShown: true))
    XCTAssertNil(terminalsError([idle], nothingShown: true))
  }

  func testASlashCommandForASessionInNoTerminalPocketTermDrivesIsRefusedNotSentAsChat() {
    let terms = terms()
    for key in ["kitty-1/2", "tmux:default/0", ghosttyKey] { XCTAssertNil(cantCommand(terms, key), key) }
    XCTAssertTrue(cantCommand(terms, nil)!.hasPrefix("Slash commands are typed into the agent's terminal window"))
  }

  func testAPhoneImageGoesAsPngOrJpegOffTheMacNothingElseIsRead() async throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
    let heic = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
    let asPng = try await TerminalBridge.image(png, macos: false)
    XCTAssertEqual(asPng.mimeType, "image/png")
    let asJpeg = try await TerminalBridge.image(jpeg, macos: false)
    XCTAssertEqual(asJpeg.mimeType, "image/jpeg")
    do {
      _ = try await TerminalBridge.image(heic, macos: false)
      XCTFail("read HEIC off the Mac")
    } catch let e as LiveException {
      XCTAssertEqual(e.message, "This computer reads PNG and JPEG images only.")
    }
  }

  func testOnTheMacAnyOtherImageBecomesPngThroughSipsAndGarbageIsRefused() async throws {
    // A 1×1 GIF, which no model is promised to read.
    let gif = Data([
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
      0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
      0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    ])
    let converted = try await TerminalBridge.image(gif)
    XCTAssertEqual(converted.mimeType, "image/png")
    XCTAssertEqual(Array(converted.bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    do {
      _ = try await TerminalBridge.image(Data([0, 1, 2, 3, 4, 5, 6, 7]))
      XCTFail("sips read garbage")
    } catch let e as LiveException {
      XCTAssertEqual(e.message, "The computer couldn't read that image.")
    }
  }

  @MainActor
  func testAPhonesImageOrFileIsStoredSealedOnlyThisComputersKeyOpensItForItsOwnPath() async throws {
    let dir = hubTempDir("pocketterm_image")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let key = ChannelKey.generate()
    let stored = HubLocked<[String: Data]>([:])
    var runs: [JSONObject] = []
    var phone: TerminalRemote!
    phone = TerminalRemote(
      PocketTermServerClient(Backend(url: "http://localhost:1"), tokens: MemoryDeviceTokens()),
      supportDir: URL(fileURLWithPath: dir), desktopId: "abcd1234", key: key,
      send: { event, payload in
        guard event == "run" else { return }
        runs.append(payload)
        phone.handle("ran", ["id": payload["id"] ?? .null])
      },
      upload: { path, sealed in stored.set(path, sealed) }, from: "phone")
    phone.handle("state", ["windows": [], "sessions": []])
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 1, 2, 3])
    let pdf = Data("%PDF-1.7 quarterly numbers".utf8)

    try await phone.prompt(
      "kitty-1/2", "look", images: [png], files: [PromptFile(name: "Q3 report.pdf", mime: "application/pdf", bytes: pdf)])

    let path = runs[0]["images"]!.array![0].string!
    XCTAssertTrue(Servers.isBlobPath(path))
    let sealed = stored.get[path]!
    XCTAssertNil(sealed.range(of: png), "Storage never holds the image itself")
    XCTAssertEqual(try TerminalBridge.openBlob(key, path, sealed), png)
    let opened = try await TerminalBridge.image(try TerminalBridge.openBlob(key, path, sealed), macos: false)
    XCTAssertEqual(opened.mimeType, "image/png")
    XCTAssertThrowsError(try TerminalBridge.openBlob(ChannelKey.generate(), path, sealed)) {
      XCTAssert($0 is LiveException)
    }
    XCTAssertThrowsError(try TerminalBridge.openBlob(key, "another", sealed)) { XCTAssert($0 is LiveException) }

    let file = runs[0]["files"]!.array![0].object!
    XCTAssertEqual(file["name"], "Q3 report.pdf")
    XCTAssertEqual(file["mime"], "application/pdf")
    let filePath = file["path"]!.string!
    XCTAssertTrue(Servers.isBlobPath(filePath))
    XCTAssertNotEqual(filePath, path)
    let sealedFile = stored.get[filePath]!
    XCTAssertNil(sealedFile.range(of: pdf), "Storage never holds the file itself")
    XCTAssertNil(sealedFile.range(of: Data("Q3 report".utf8)), "nor its name")
    XCTAssertEqual(try TerminalBridge.openBlob(key, filePath, sealedFile), pdf)
    XCTAssertThrowsError(try TerminalBridge.openBlob(key, path, sealedFile)) { XCTAssert($0 is LiveException) }
  }

  func testAFollowedSessionsUpdateGoesSealedForAndroidIPhonesGetOnlyItsState() throws {
    let key = ChannelKey.generate()
    let body = TerminalBridge.activityPush(
      key, "abcd1234", "kitty-1/2", ActivityStatus(state: .needs, kind: .approval))
    XCTAssertEqual(Set(body.keys), ["session", "state", "kind", "tag", "enc"])
    XCTAssertEqual(body["session"], "abcd1234/kitty-1/2")
    // The phone finds the key by this computer's tag; the computer's id goes only inside the seal.
    XCTAssertEqual(body["tag"], .string(pushTag(key)))

    let sealed = Data(base64Encoded: body["enc"]!.string!)!
    let opened = try JSON.parse(openBytes(key, sealed, activityAad("abcd1234"))!).object!
    XCTAssertEqual(Set(opened.keys), ["session", "state", "kind", "since", "ts", "id"])
    XCTAssertEqual(opened["session"], "abcd1234/kitty-1/2")
    XCTAssertEqual(opened["state"], "needs")
    XCTAssertEqual(opened["kind"], "approval")
    XCTAssertNotNil(opened["since"]?.int)
    XCTAssertNotNil(opened["ts"]?.int)
    XCTAssertNotNil(opened["id"]?.string)
    // Not another computer's, not a notification.
    XCTAssertNil(openBytes(key, sealed, activityAad("zzzz9999")))
    XCTAssertNil(openBytes(key, sealed, pushAad("abcd1234")))
  }

  @MainActor
  func testARequestSentAgainUnderItsIdIsAnsweredAsBeforeNotRunTwiceIdsAreForgottenAfterAWhile() {
    var now = Date(timeIntervalSince1970: 1_767_225_600)
    let runs = RunLog(clock: { now })
    var again: [JSONObject] = []
    XCTAssertTrue(runs.start("a") { again.append($0) })
    XCTAssertFalse(runs.start("a") { again.append($0) }, "still running: its answer goes out when it ends")
    XCTAssertTrue(again.isEmpty)
    runs.done("a", ["id": "a", "error": "nope"])
    XCTAssertFalse(runs.start("a") { again.append($0) })
    XCTAssertEqual(again, [["id": "a", "error": "nope", "repeat": true]])
    XCTAssertTrue(runs.start("b") { again.append($0) }, "another request runs")
    now = now.addingTimeInterval(3 * 60)
    XCTAssertTrue(runs.start("a") { again.append($0) })
  }

  // ------------------------------------------------------------ switching a screen-only agent window

  private let window = "kitty-1/7"
  private let tty = "ttys004"

  /// A kitty that records what it's told, and `ps` showing `foreground`'s programs on the tty in turn (the last one
  /// from then on).
  private func switchTerms(_ kitty: BridgeFakeKitty, _ foreground: [String]) -> Terminals {
    let shown = HubLocked(foreground)
    let tty = tty
    return Terminals(
      home: nowhere, kitty: kitty,
      snapshot: {
        let program = shown.next()
        kitty.add("ps \(program)")
        var procs = [
          Proc(pid: 40, ppid: 1, pgid: 40, tpgid: program == "zsh" ? 40 : 50, tty: tty, stat: "Ss", args: "-zsh")
        ]
        if program != "zsh" {
          procs.append(Proc(pid: 50, ppid: 40, pgid: 50, tpgid: 50, tty: tty, stat: "S+", args: program))
        }
        return Procs(procs)
      })
  }

  private func run(_ t: Terminals, _ agent: Agent, tty: String? = nil, profile: String = "") async throws {
    try await switchToConversation(
      t, window, agent, tty: tty ?? self.tty, profile: profile, settle: 0, quitFor: 0.2, noTty: 0, pollEvery: 0)
  }

  func testOmpEscCtrlCCtrlDThenOmpCOnceOmpHasQuit() async throws {
    let kitty = BridgeFakeKitty()
    try await run(switchTerms(kitty, ["omp", "omp", "omp", "zsh"]), .omp)
    XCTAssertEqual(
      kitty.log,
      ["ps omp", "keys esc", "keys ctrl+c", "keys ctrl+d", "ps omp", "ps omp", "ps zsh", "type omp -c", "keys enter"])
  }

  func testOmpInAProfileStartsAgainInThatProfile() async throws {
    let kitty = BridgeFakeKitty()
    try await run(
      switchTerms(kitty, ["omp --profile=personal", "omp --profile=personal", "zsh"]), .omp, profile: "personal")
    XCTAssertEqual(kitty.log.filter { $0.hasPrefix("type") }, ["type omp --profile=personal -c"])
  }

  func testAPhonesLaunchRunsOmpOnlyInAProfileThisComputerHasAndOtherAgentsInNone() throws {
    XCTAssertEqual(try launchProfile("personal", .omp, ["personal"]), "personal")
    XCTAssertEqual(try launchProfile(nil, .omp, ["personal"]), "")
    XCTAssertEqual(try launchProfile("", .omp, ["personal"]), "")
    XCTAssertThrowsError(try launchProfile("x", .omp, ["personal"])) { XCTAssert($0 is TerminalException) }
    XCTAssertThrowsError(try launchProfile("a; rm -rf ~", .omp, ["personal"])) { XCTAssert($0 is TerminalException) }
    XCTAssertEqual(try launchProfile("personal", .claude, ["personal"]), "")
  }

  func testAnAgentThatQuitSinceThePhoneLookedGetsNoKeys() async {
    let kitty = BridgeFakeKitty()
    let t = switchTerms(kitty, ["zsh"])
    for agent in Agent.allCases {
      do {
        try await run(t, agent)
        XCTFail("\(agent) switched")
      } catch let e as TerminalException {
        XCTAssertTrue(e.message.contains("isn't running"), e.message)
      } catch {
        XCTFail("\(error)")
      }
    }
    XCTAssertTrue(kitty.log.allSatisfy { $0.hasPrefix("ps") })
  }

  func testOmpInATerminalThatTellsNoTtyOmpCAfterAWait() async throws {
    let kitty = BridgeFakeKitty()
    try await run(switchTerms(kitty, ["omp"]), .omp, tty: "")
    XCTAssertEqual(kitty.log, ["keys esc", "keys ctrl+c", "keys ctrl+d", "type omp -c", "keys enter"])
  }

  func testOmpThatDoesntQuitGetsNothingTypedIntoIt() async {
    let kitty = BridgeFakeKitty()
    do {
      try await run(switchTerms(kitty, ["omp"]), .omp)
      XCTFail("omp quit")
    } catch let e as TerminalException {
      XCTAssertTrue(e.message.hasPrefix("omp didn't quit."), e.message)
    } catch {
      XCTFail("\(error)")
    }
    XCTAssertTrue(kitty.log.filter { $0.hasPrefix("type") }.isEmpty)
  }

  func testClaudeCodeReloadPluginsAndEnterNothingRestarts() async throws {
    let kitty = BridgeFakeKitty()
    try await run(switchTerms(kitty, ["claude"]), .claude)
    XCTAssertEqual(kitty.log, ["ps claude", "type /reload-plugins", "keys enter"])
  }

  func testATerminalThatCantPressKeysIsRefused() async {
    do {
      try await switchToConversation(switchTerms(BridgeFakeKitty(), ["omp"]), "nowhere:1", .omp)
      XCTFail("switched")
    } catch let e as TerminalException {
      XCTAssertTrue(e.message.hasPrefix("This terminal can't press keys"), e.message)
    } catch {
      XCTFail("\(error)")
    }
  }

  func testProbeBusyWhenTheScreenChangesBetweenTwoReadsNotWhenItDoesnt() async throws {
    let kitty = BridgeFakeKitty()
    let t = switchTerms(kitty, ["omp"])
    kitty.screens = ["π ⠋ Working", "π ⠙ Working"]
    let working = try await screenChanges(t, window, gap: 0)
    XCTAssertTrue(working)
    kitty.screens = ["π > idle", "π > idle"]
    let idle = try await screenChanges(t, window, gap: 0)
    XCTAssertFalse(idle)
  }

  func testProbeInATerminalThatCantShowItsScreenBusyWhenTheTitleSpins() async throws {
    let ghostty = BridgeFakeGhostty()
    let t = Terminals(home: nowhere, ghostty: ghostty, snapshot: { Procs([]) })
    ghostty.titles = ["π ⠋ chat", "π ⠋ chat", "π ⠙ chat"]
    let spinning = try await screenChanges(t, ghosttyKey, gap: 0)
    XCTAssertTrue(spinning)
    ghostty.titles = ["π > chat"]
    let still = try await screenChanges(t, ghosttyKey, gap: 0)
    XCTAssertFalse(still)
    ghostty.titles = []
    do {
      _ = try await screenChanges(t, ghosttyKey, gap: 0)
      XCTFail("a closed window probed")
    } catch is TerminalException {}
  }
}

/// A value several tasks touch.
final class HubLocked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  var get: Value { lock.withLock { value } }
}

extension HubLocked where Value == [String: Data] {
  func set(_ key: String, _ data: Data) { lock.withLock { value[key] = data } }
}

extension HubLocked where Value == [String] {
  /// The first one, taken unless it's the last.
  func next() -> String { lock.withLock { value.count > 1 ? value.removeFirst() : value[0] } }
}
#endif
