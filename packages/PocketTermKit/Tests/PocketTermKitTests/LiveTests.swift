import Foundation
import XCTest

@testable import PocketTermKit

private func text(_ id: String, _ text: String, kind: ItemKind = .assistant) -> LiveItem {
  LiveItem(id: id, kind: kind, text: text)
}

private func roundTrip(_ j: JSONObject) -> JSONObject { try! JSON.parse(j.encoded()).object! }

/// What a phone ends up with when every op reaches it through JSON.
@discardableResult
private func follow(_ log: LiveLog, _ ops: [LiveOp], view: LiveView? = nil, file: StaticString = #filePath,
  line: UInt = #line) -> LiveView
{
  let v = view ?? LiveView(epoch: log.epoch)
  let wire = ops.map { LiveOp(json: roundTrip($0.toJson()))! }
  XCTAssertTrue(v.apply(log.epoch, wire), file: file, line: line)
  return v
}

private func catchUp(_ view: LiveView, _ log: LiveLog, older: Bool? = nil) {
  view.catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: log.items, last: true, older: older)
}

final class LiveLogViewTests: XCTestCase {
  func testRoutedKeySplitsBack() {
    for key in ["kitty-1/2", "tmux:default/0", "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074"] {
      let r = splitRoutedKey(routedKey("ab12cd34", key))
      XCTAssertEqual(r?.desktop, "ab12cd34")
      XCTAssertEqual(r?.key, key)
    }
    for s in ["kitty-1/2", "ab12cd3/kitty-1/2", "ab12cd345/kitty-1/2", "AB12CD34/kitty-1/2", "ab12cd34kitty-1",
      "ab12cd34/", ""]
    {
      XCTAssertNil(splitRoutedKey(s), s)
    }
  }

  func testFollowerEndsWithWhatTheMacHas() {
    let log = LiveLog([text("u1", "hi", kind: .user)], older: false)
    let view = LiveView(epoch: log.epoch)
    catchUp(view, log)
    let ops = [
      log.upsert(text("a1", "")),
      log.append("a1", "Hel")!,
      log.append("a1", "lo")!,
      log.upsert(LiveItem(id: "t1", kind: .tool, tool: "bash", args: "ls")),
      log.upsert(LiveItem(id: "t1", kind: .tool, tool: "bash", args: "ls", output: "a\nb")),
    ]
    follow(log, ops, view: view)
    XCTAssertEqual(view.items.map(\.id), ["u1", "a1", "t1"])
    XCTAssertEqual(view.items[1].text, "Hello")
    XCTAssertEqual(view.items[2].output, "a\nb")
    XCTAssertEqual(view.seq, log.seq)
  }

  func testReplacedItemShowsNewTextAfterTheListWasRead() {
    let log = LiveLog([], older: false)
    let view = follow(log, [log.upsert(text("a1", "")), log.append("a1", "Hel")!])
    XCTAssertEqual(view.items.map(\.text), ["Hel"])
    // The answer's final text, whole: the last streamed bit never went out on its own.
    follow(log, [log.upsert(text("a1", "Hello."))], view: view)
    XCTAssertEqual(view.items.map(\.text), ["Hello."])
  }

  func testAppendAfterSnapshotIsNotAppliedTwice() {
    let log = LiveLog([], older: false)
    let upsert = log.upsert(text("a1", "He"))
    let append = log.append("a1", "llo")!
    XCTAssertEqual(follow(log, [upsert, append]).items.map(\.text), ["Hello"])
  }

  func testMissingOpIsDetectedAndCatchUpFillsTheGap() {
    let log = LiveLog([], older: false)
    let view = follow(log, [log.upsert(text("a1", "one"))])
    _ = log.upsert(text("a2", "two"))  // lost on the way
    let third = log.upsert(text("a3", "three"))
    XCTAssertFalse(view.apply(log.epoch, [third]))
    view.catchUp(epoch: log.epoch, seq: log.seq, reset: false, items: log.since(view.seq), last: true)
    XCTAssertEqual(view.items.map(\.text), ["one", "two", "three"])
    XCTAssertEqual(view.seq, log.seq)
    // Ops the catch-up already covered are skipped, not doubled.
    XCTAssertTrue(view.apply(log.epoch, [third]))
    XCTAssertEqual(view.items.count, 3)
  }

  func testNewEpochRefusedByApplyAndReplacesOnReset() {
    let old = LiveLog([text("x", "old")], older: false)
    let view = LiveView(epoch: old.epoch)
    catchUp(view, old)
    let log = LiveLog([text("y", "new")], older: true)
    XCTAssertFalse(view.apply(log.epoch, [log.upsert(text("z", "!"))]))
    catchUp(view, log, older: log.older)
    XCTAssertEqual(view.items.map(\.id), ["y", "z"])
    XCTAssertTrue(view.older)
  }

  func testSeqMovesOnlyWithTheLastChunk() {
    let log = LiveLog((0..<4).map { text("\($0)", "\($0)") }, older: false)
    let view = LiveView(epoch: log.epoch)
    let items = log.items
    view.catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: Array(items[0..<2]), last: false)
    XCTAssertEqual(view.seq, 0)
    view.catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: Array(items[2...]), last: true)
    XCTAssertEqual(view.seq, log.seq)
    XCTAssertEqual(view.items.count, 4)
  }

  func testOlderItemsGoAboveAndReachAFollower() {
    let log = LiveLog([text("c", "c"), text("d", "d")], older: true)
    let view = LiveView(epoch: log.epoch)
    catchUp(view, log)
    follow(log, log.addOlder([text("a", "a"), text("b", "b"), text("c", "dup")], more: false), view: view)
    XCTAssertEqual(view.items.map(\.id), ["a", "b", "c", "d"])
    XCTAssertEqual(view.items[2].text, "c", "an item already there is not replaced by an older copy")
    XCTAssertFalse(log.older)
  }

  func testLogCapDropsTheOldest() {
    let log = LiveLog((0..<5).map { text("\($0)", "\($0)") }, older: false, cap: 3)
    XCTAssertEqual(log.items.map(\.id), ["2", "3", "4"])
    XCTAssertTrue(log.older)
    _ = log.upsert(text("5", "5"))
    XCTAssertEqual(log.items.map(\.id), ["3", "4", "5"])
  }

  func testViewCapDropsTheOldestButKeepsPagedInItems() {
    let log = LiveLog((0..<3).map { text("\($0)", "\($0)") }, older: false, cap: 5)
    let view = LiveView(epoch: log.epoch, cap: 3)
    catchUp(view, log)
    XCTAssertFalse(view.older)
    follow(log, [log.upsert(text("3", "3")), log.upsert(text("4", "4"))], view: view)
    XCTAssertEqual(view.items.map(\.id), ["2", "3", "4"])
    XCTAssertTrue(view.older, "the Mac has the rest")
    follow(log, log.addOlder([text("a", "a")], more: false), view: view)
    XCTAssertEqual(view.items.first?.id, "a", "asked for, so it stays")
    follow(log, [log.upsert(text("5", "5"))], view: view)
    XCTAssertEqual(view.items.map(\.id), ["3", "4", "5"])
  }

  func testDiskCacheKeepsTheNewest() {
    let log = LiveLog((0..<10).map { text("\($0)", "\($0)") }, older: false)
    let view = LiveView(epoch: log.epoch)
    catchUp(view, log)
    let back = LiveView(json: roundTrip(view.toJson(keep: 4)))!
    XCTAssertEqual(back.items.map(\.id), ["6", "7", "8", "9"])
    XCTAssertTrue(back.older)
    XCTAssertEqual(back.seq, view.seq)
    // A cached view still follows the live ops.
    follow(log, [log.upsert(text("10", "x"))], view: back)
    XCTAssertEqual(back.items.last?.id, "10")
  }

  func testJsonBytesIsTheEncodedSize() {
    for s in ["plain", #"quote " and \ back"#, "tab\tnl\n\u{0}\u{1b}[31m", "é中文", "😀👍🏽", "שלום", "a\u{200d}b"] {
      XCTAssertEqual(jsonBytes(s), JSON.string(s).encoded().utf8.count - 2, s)
    }
    // "\ud800 lone": a lone surrogate is escaped as \ud800.
    XCTAssertEqual(jsonBytes(utf16: [0xD800] + Array(" lone".utf16)), 6 + 5)
  }

  func testHugeItemIsCutTheSameForMacAndPhone() {
    let log = LiveLog([], older: false)
    let huge = String(repeating: "中文 ok 😀 \u{1b}[1m\"", count: 40000)
    var ops = [log.upsert(text("u", huge, kind: .user)), log.upsert(text("a", ""))]
    for i in 0..<300 {
      if let op = log.append("a", "\(i) \(String(repeating: "x", count: 500))\n") { ops.append(op) }
    }
    ops.append(
      log.upsert(
        LiveItem(
          id: "t", kind: .tool, tool: "bash", args: String(repeating: "y", count: 100000),
          output: String(repeating: "z", count: 100000) + "END")))
    let view = follow(log, ops)
    for i in log.items {
      XCTAssertLessThan(i.toJson().encoded().utf8.count, maxItemTextBytes + 32 * 1024, i.id)
    }
    XCTAssertTrue(log.items[0].text.hasPrefix("中文 ok 😀"))
    XCTAssertTrue(log.items[0].text.hasSuffix(cutNote))
    XCTAssertTrue(log.items[1].text.hasSuffix(cutNote), "streamed text stops at the cap")
    XCTAssertTrue(log.items[2].output.hasSuffix("END"), "a tool's output keeps its end")
    func texts(_ i: LiveItem) -> [String] { [i.id, i.text, i.args, i.output] }
    XCTAssertEqual(view.items.map(texts), log.items.map(texts))
    // What a catch-up sends: every chunk under the server's frame once sealed.
    for chunk in chunkJson(log.items.map { $0.toJson() }) {
      XCTAssertLessThan(JSON.array(chunk.map(JSON.object)).encoded().utf8.count * 4 / 3, 256 * 1024)
    }
  }

  func testChunkJsonKeepsEveryChunkUnderTheLimit() {
    let items: [JSONObject] = (0..<50).map { ["id": .string("\($0)"), "t": .string(String(repeating: "x", count: 900))] }
    let chunks = chunkJson(items, maxBytes: 5000)
    XCTAssertGreaterThan(chunks.count, 1)
    for c in chunks { XCTAssertLessThan(JSON.array(c.map(JSON.object)).encoded().utf8.count, 5000 + 100) }
    XCTAssertEqual(chunks.flatMap { $0 }.count, 50)
  }
}

final class LiveDialogTests: XCTestCase {
  private let db = LiveQuestion(id: "db", question: "Database?", options: ["SQLite", "Postgres", "MySQL"])

  private func flat(_ steps: [KeyStep], wait: String = "wait") -> [String] {
    steps.map {
      switch $0 {
      case .keys(let k): k.joined(separator: " ")
      case .typed(let t): "type:\(t)"
      case .settle: wait
      }
    }
  }

  private func to(_ row: Int, _ rows: Int) -> String {
    (Array(repeating: "up", count: rows) + Array(repeating: "down", count: row)).joined(separator: " ")
  }

  private func ask(_ qs: [LiveQuestion]) -> LiveAsk { .questions("call", qs) }

  func testOmpSingleChoice() throws {
    XCTAssertEqual(flat(try answerKeys(ask([db]), answers: [LiveAnswer(picks: [1])])), ["\(to(1, 4)) enter"])
  }

  func testOmpTypedAnswer() throws {
    XCTAssertEqual(
      flat(try answerKeys(ask([db]), answers: [LiveAnswer(custom: " DuckDB ")])),
      ["\(to(3, 4)) enter", "wait", "type:DuckDB", "enter", "wait"])
  }

  func testOmpTypedAnswersToSeveralQuestions() throws {
    let q2 = LiveQuestion(id: "wt", question: "Worktree?", options: ["Yes", "No"])
    XCTAssertEqual(
      flat(try answerKeys(ask([db, q2]), answers: [LiveAnswer(custom: "a"), LiveAnswer(custom: "b")])),
      [
        "\(to(3, 4)) enter", "wait", "type:a", "enter", "wait", "\(to(2, 3)) enter", "wait", "type:b", "enter", "wait",
        "enter",
      ])
  }

  func testOmpMultipleChoice() throws {
    let q = LiveQuestion(id: "f", question: "Features?", options: ["a", "b", "c"], multi: true)
    XCTAssertEqual(
      flat(try answerKeys(ask([q]), answers: [LiveAnswer(picks: [0, 2])])),
      ["\(to(0, 4)) space \(to(2, 4)) space enter"])
  }

  func testOmpLoneMultipleChoiceWithTextEndsOnSubmit() throws {
    let q = LiveQuestion(id: "f", question: "Features?", options: ["a"], multi: true)
    XCTAssertEqual(
      flat(try answerKeys(ask([q]), answers: [LiveAnswer(picks: [0], custom: "z")])),
      ["\(to(0, 2)) space \(to(1, 2)) enter", "wait", "type:z", "enter", "wait", "enter"])
  }

  func testOmpSeveralQuestionsThenSubmit() throws {
    let q2 = LiveQuestion(id: "os", question: "OS?", options: ["mac", "linux"])
    XCTAssertEqual(
      flat(try answerKeys(ask([db, q2]), answers: [LiveAnswer(picks: [2]), LiveAnswer(picks: [0])])),
      ["\(to(2, 4)) enter \(to(0, 3)) enter", "wait", "enter"])
  }

  func testOmpApproval() throws {
    let a = LiveAsk.approval("call", tool: "bash")
    XCTAssertEqual(flat(try answerKeys(a, approve: true)), ["enter"])
    XCTAssertEqual(flat(try answerKeys(a)), ["down enter"])
  }

  func testAnswersTheDialogCannotTakeAreRefused() {
    XCTAssertThrowsError(try answerKeys(ask([db]), answers: []))
    XCTAssertThrowsError(try answerKeys(ask([db]), answers: [LiveAnswer(picks: [3])]))
    XCTAssertThrowsError(try answerKeys(ask([db]), answers: [LiveAnswer(picks: [0, 1])]))
    XCTAssertThrowsError(try answerKeys(ask([db]), answers: [LiveAnswer(custom: "  ")]))
    XCTAssertThrowsError(try answerKeys(.plan("p"), answers: []))
  }

  func testAskOnScreen() {
    let q = LiveQuestion(id: "x", question: "Which **storage** backend should the sync layer use?", options: ["a"])
    let screen = "│ Which storage backend should\n│ the sync layer use?\n│ > a"
    XCTAssertTrue(askOnScreen(.questions("c", [q]), screen.replacingOccurrences(of: "│", with: "")))
    XCTAssertFalse(askOnScreen(.questions("c", [q]), "π > waiting for input"))
    let a = LiveAsk.approval("c", tool: "bash")
    XCTAssertTrue(askOnScreen(a, "Run bash?\n> Approve\n  Deny"))
    XCTAssertFalse(askOnScreen(a, "Approve the plan"))
    let plan = LiveAsk.plan("c", title: "notes")
    XCTAssertTrue(askOnScreen(plan, planScreen()))
    XCTAssertTrue(askOnScreen(plan, planScreen(help: "↑/↓ scroll · a annotate · ⇥ regions")))
    XCTAssertFalse(askOnScreen(plan, "π > waiting for input\n  plan the next release"))
  }

  func testPlanReview() throws {
    let review = parsePlanReview(planScreen())
    XCTAssertEqual(
      review?.options,
      [
        "Approve and execute", "Approve and compact context",
        "Approve and keep context (~47k / 1m) — then save every draft note as it changes", "Refine plan",
        "Save and quit",
      ])
    XCTAssertEqual(review?.current, 2)
    let plain = planScreen(cursor: 4, slider: false, long: false)
    XCTAssertEqual(parsePlanReview(plain)?.options.count, 5)
    XCTAssertEqual(parsePlanReview(plain)?.current, 4)
    XCTAssertNil(parsePlanReview(planScreen(help: "↑/↓ scroll · a annotate · ⇥ regions")))
    XCTAssertNil(parsePlanReview(planScreen(help: "Applying your selection — this can take a moment.")))
    XCTAssertNil(parsePlanReview("π > waiting for input\n↑/↓ select"))

    XCTAssertEqual(try menuKeys(1, 3), ["down", "down", "enter"])
    XCTAssertEqual(try menuKeys(3, 0), ["up", "up", "up", "enter"])
    XCTAssertEqual(try menuKeys(2, 2), ["enter"])
    XCTAssertEqual(try menuKeys(4, 1, enter: false), ["up", "up", "up"])
    XCTAssertThrowsError(try menuKeys(2, -1))
    XCTAssertThrowsError(try menuKeys(-1, 0))
  }

  func testPlanAskThroughJson() {
    let ask = LiveAsk.plan("call", title: "notes-plan", options: ["Approve and execute", "Refine plan"], selected: 1)
    let back = LiveAsk(json: roundTrip(ask.toJson()))!
    XCTAssertEqual(back, ask)
    XCTAssertEqual(back.text, "Plan ready: notes-plan")
    // The extension sends a plan without options; the Mac reads them off the screen.
    let bare = LiveAsk(json: ["kind": "plan", "id": "x", "title": "notes-plan"])!
    XCTAssertTrue(bare.isPlan)
    XCTAssertTrue(bare.options.isEmpty)
  }

  // /resume in a 60-column kitty, as its plain text reads.
  private let resume = """
     Resume Session (current folder)

     > █

     ❯ Build kitty socket client and live protoc…
       i want you to review our WHOLE terminal f…
       3 minutes ago  ·  5.2MB  ·  ✔ done

       Check if mobile app rebuild needed
       we did bunch of changes to this app, do i…
       1 day ago  ·  239.3KB  ·  ✔ done

       Fix popup notes
       2 days ago  ·  12.1KB
       …
     [⌦/⌫ delete · ⏎ select · ⇥ all projects · esc cancel]
    """

  func testResumePicker() {
    let menu = parseMenu(resume)
    XCTAssertEqual(menu?.title, "Resume Session (current folder)")
    XCTAssertEqual(menu?.filter, true)
    XCTAssertEqual(menu?.current, 0)
    XCTAssertEqual(
      menu?.items,
      [
        MenuItem(
          label: "Build kitty socket client and live protoc…",
          detail: "i want you to review our WHOLE terminal f… · 3 minutes ago · 5.2MB · ✔ done"),
        MenuItem(
          label: "Check if mobile app rebuild needed",
          detail: "we did bunch of changes to this app, do i… · 1 day ago · 239.3KB · ✔ done"),
        MenuItem(label: "Fix popup notes", detail: "2 days ago · 12.1KB"),
      ])
  }

  func testResumeInItsBox() {
    func row(_ s: String) -> String {
      "│ \(s.padding(toLength: 54, withPad: " ", startingAt: 0))\(s.hasPrefix("  ") ? "█" : "│") │"
    }
    let screen = [
      "π  earlier answer in the transcript",
      "╭─ Resume Session (current folder) ───────────────────────╮",
      row("> fix"), row(""), row("  Build kitty socket client"), row("  3 minutes ago  ·  5.2MB"), row(""),
      row("❯ Fix popup notes"), row("  2 days ago  ·  12.1KB"), row(""),
      row("[⌦/⌫ delete · ⏎ select · ⇥ all projects · esc cancel]"),
      "╰\(String(repeating: "─", count: 58))╯",
    ].joined(separator: "\n")
    let menu = parseMenu(screen)
    XCTAssertEqual(menu?.title, "Resume Session (current folder)")
    XCTAssertEqual(menu?.filter, true)
    XCTAssertEqual(menu?.current, 1)
    XCTAssertEqual(menu?.items.map(\.label), ["Build kitty socket client", "Fix popup notes"])
    XCTAssertEqual(menu?.items.last?.detail, "2 days ago · 12.1KB")
  }

  func testSimplePicker() {
    let screen = """
      π  Theme changed.

       Select theme

         dark
         light       the default
       ❯ solarized
         nord
         (3/4)  Type to search

       ↑/↓ navigate  ⏎ select  esc cancel
      """
    let menu = parseMenu(screen)
    XCTAssertEqual(menu?.title, "Select theme")
    XCTAssertEqual(menu?.current, 2)
    XCTAssertEqual(menu?.filter, true)
    XCTAssertEqual(
      menu?.items,
      [
        MenuItem(label: "dark", detail: ""), MenuItem(label: "light", detail: "the default"),
        MenuItem(label: "solarized", detail: ""), MenuItem(label: "nord", detail: ""),
      ])
  }

  func testPromptsAndPlanReviewAreNotPickers() {
    let prompt = """
      π  Done: the popup keeps its notes now.
         > ran 3 tests

      ╭──────────────────────────────────────────────────────────╮
      │ > █                                                        │
      ╰──────────────────────────────────────────────────────────╯
        opus-4.5 · 12% · ~/Dev/pocketterm
      """
    XCTAssertNil(parseMenu(prompt))
    XCTAssertNil(parseMenu(planScreen()))
  }

  func testClaudeTranscriptPromptsAreNotPickersButModelIs() {
    // Its prompt line is ❯ and a no-break space, under the transcript's `❯ ` prompts.
    let idle =
      "⏺ pong\n\n› Prompt from the pocketterm plugin\n❯ Reply just: Q3OK\n\n⏺ Q3OK\n"
      + "────────────────────────────────────────\n❯\u{a0}\n────────────────────────────────────────\n"
      + "  ⏸ manual mode on · ? for shortcuts"
    XCTAssertNil(parseMenu(idle))
    let model =
      "❯ Reply just: Q3OK\n▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔\n   Select model\n\n"
      + "   ❯ 1.  Default (recommended) ✔  Opus 5.5\n     2.  Sonnet 5.5               Most efficient\n\n"
      + "   Enter to set as default · Esc to cancel"
    let menu = parseMenu(model)
    XCTAssertEqual(menu?.title, "Select model")
    XCTAssertEqual(menu?.current, 0)
    XCTAssertEqual(menu?.items.map(\.label), ["1. Default (recommended) ✔", "2. Sonnet 5.5"])
  }

  func testPickerOnScreenWhileItsTitleIs() {
    XCTAssertTrue(askOnScreen(.menu("m1", title: "Resume Session (current folder)", items: []), resume))
    XCTAssertFalse(askOnScreen(.menu("m1", title: "Select theme", items: []), resume))
  }

  func testPickerThroughJson() {
    let ask = LiveAsk.menu(
      "menu-3", title: "Select model",
      items: [MenuItem(label: "opus", detail: "Anthropic · 200k"), MenuItem(label: "gpt-5", detail: "")],
      selected: 1, filter: true)
    let back = LiveAsk(json: roundTrip(ask.toJson()))!
    XCTAssertEqual(back, ask)
    XCTAssertTrue(back.isMenu)
    XCTAssertEqual(back.text, "Select model")
  }

  // The screens and keys below were read off and tried on Claude Code 2.1.296 in kitty.
  private let color = LiveQuestion(id: "", question: "Which color should the button be?", options: ["Red", "Blue", "Green"])
  private let sizes = LiveQuestion(
    id: "", question: "Which sizes do you want?", options: ["Small", "Medium", "Large"], multi: true)

  func testClaudeSingleQuestion() throws {
    let ask = LiveAsk.questions("t1", [color])
    XCTAssertEqual(flat(try answerKeys(ask, answers: [LiveAnswer(picks: [1])], agent: .claude)), ["2"])
    XCTAssertEqual(
      flat(try answerKeys(ask, answers: [LiveAnswer(custom: "Purple")], agent: .claude), wait: "settle"),
      ["4", "settle", "type:Purple", "settle", "enter"])
  }

  func testClaudeMultipleChoice() throws {
    XCTAssertEqual(
      flat(
        try answerKeys(
          .questions("t2", [color, sizes]), answers: [LiveAnswer(picks: [2]), LiveAnswer(picks: [0, 2])],
          agent: .claude), wait: "settle"),
      ["3", "settle", "1 3 down down down down enter", "settle", "1"])
    XCTAssertEqual(
      flat(
        try answerKeys(.questions("t3", [sizes]), answers: [LiveAnswer(picks: [1], custom: "Huge")], agent: .claude),
        wait: "settle"),
      ["2 4 down down down", "settle", "type:Huge", "settle", "down enter", "settle", "1"])
  }

  func testClaudeApproval() throws {
    let ask = LiveAsk.approval("t4", tool: "Bash", summary: "touch made-by-fake.txt")
    XCTAssertEqual(flat(try answerKeys(ask, approve: true, agent: .claude)), ["1"])
    XCTAssertEqual(flat(try answerKeys(ask, agent: .claude)), ["esc"])
    let screen = """
       Bash command
       Create a marker file
       touch made-by-fake.txt
       Do you want to proceed?
       ❯ 1. Yes
         2. Yes, and always allow access to /private/tmp/work from this project
         3. No
       Esc to cancel · Tab to amend
      """
    XCTAssertTrue(askOnScreen(ask, screen, agent: .claude))
    XCTAssertFalse(askOnScreen(ask, "❯ say hello\n⏺ Hello.", agent: .claude))
  }

  func testClaudePlanReview() {
    let screen = """
       Ready to code?
       Here is Claude's plan:
       Paint the button
       1. Pick a color
       2. Paint it
       Claude has written up a plan and is ready to execute. Would you like to proceed?
       ❯ 1. Yes, auto-accept edits
         2. Yes, manually approve edits
         3. Tell Claude what to change
            shift+tab to approve with this feedback
       ctrl+g to edit in True · /tmp/plans/paint.md
      """
    let review = parsePlanReview(screen, agent: .claude)
    XCTAssertEqual(review?.options, ["Yes, auto-accept edits", "Yes, manually approve edits", "Tell Claude what to change"])
    XCTAssertEqual(review?.current, 0)
    XCTAssertTrue(askOnScreen(.plan("t5"), screen, agent: .claude))
    let exit = parsePlanReview(" Exit plan mode?\n Claude wants to exit plan mode\n   1. Yes\n ❯ 2. No", agent: .claude)
    XCTAssertEqual(exit?.options, ["Yes", "No"])
    XCTAssertEqual(exit?.current, 1)
    XCTAssertNil(parsePlanReview(screen))
  }
}

final class LiveSummaryTests: XCTestCase {
  func testScreenDiff() {
    func lines(_ from: Int, _ to: Int) -> [String] { (from..<to).map { "line \($0)" } }
    let a = lines(0, 100)
    let b = lines(5, 100) + lines(100, 105)
    let d = ScreenDiff.between(a, b)!
    XCTAssertEqual([d.drop, d.keep, d.tail.count], [5, 95, 5])
    XCTAssertEqual(d.apply(a), b)

    let a2 = lines(0, 50)
    let b2 = lines(0, 45) + ["x", "y"]
    let d2 = ScreenDiff.between(a2, b2)!
    XCTAssertEqual(d2.tail, ["x", "y"])
    XCTAssertEqual(d2.apply(a2), b2)

    XCTAssertNil(ScreenDiff.between(lines(0, 10), lines(50, 60)))
    XCTAssertNil(ScreenDiff.between(lines(0, 100), lines(10, 110))!.apply(lines(0, 20)))
  }

  func testProfileThroughJson() {
    let s = LiveSummary(key: "k", id: "s", title: "", cwd: "/x", epoch: "e", seq: 1, profile: "personal")
    XCTAssertEqual(s.toJson()["profile"], "personal")
    XCTAssertEqual(LiveSummary(json: roundTrip(s.toJson()))?.profile, "personal")
    XCTAssertNil(LiveSummary(key: "k", id: "s", title: "", cwd: "/x", epoch: "e", seq: 1).toJson()["profile"])
    XCTAssertEqual(LiveSummary(json: ["key": "k"])?.profile, "")
    XCTAssertNil(LiveSummary(json: ["id": "no key"]))
  }

  private let commands = [
    LiveCommand(name: "model", description: "Switch model for this session"),
    LiveCommand(name: "new", description: "Start a new session"),
    LiveCommand(name: "compact", description: "Manually compact the session context"),
    LiveCommand(name: "plan-review", description: ""),
    LiveCommand(name: "plan", description: "Toggle plan mode"),
    LiveCommand(name: "skill:Pdf", description: "Read PDFs"),
  ]

  private func names(_ text: String, max: Int = 6) -> [String] { matchCommands(commands, text, max: max).map(\.name) }

  func testCommandsThroughJson() {
    let s = LiveSummary(key: "k", id: "s", title: "", cwd: "/x", epoch: "e", seq: 1, commands: commands)
    XCTAssertEqual(LiveSummary(json: roundTrip(s.toJson()))?.commands, commands)
    XCTAssertEqual(LiveSummary(json: ["key": "k"])?.commands, [])
  }

  func testCommandMatching() {
    XCTAssertEqual(names("/p"), ["plan-review", "plan", "compact", "skill:Pdf"])
    XCTAssertEqual(names("/PL"), ["plan-review", "plan"])
    XCTAssertEqual(names("/n"), ["new", "plan-review", "plan"])
    XCTAssertEqual(names("/", max: 3), ["model", "new", "compact"])
    for t in ["/new ", "/compact keep the API", "new", "/zzz"] { XCTAssertEqual(names(t), [], t) }
  }

  func testAtGoesBackUnchanged() {
    // An odd millisecond count survives the round trip through Date.
    let s = LiveSummary(json: ["key": "k", "at": 1_792_670_400_123])!
    XCTAssertEqual(s.toJson()["at"], 1_792_670_400_123)
    XCTAssertEqual(s.at.map(millisecondsSinceEpoch), 1_792_670_400_123)
  }
}

/// omp's plan review as kitty's plain text shows it `width` columns wide:
/// the plan in a rounded box, then the "next step" prompt, the model slider,
/// the options (cursor on `cursor`) and the help line. Rows too wide for the
/// terminal wrap onto the next line, as they do in kitty.
private func planScreen(
  width: Int = 60, cursor: Int = 2, slider: Bool = true, long: Bool = true,
  help: String = "↑/↓ select · ⏎ confirm · ←/→ model · c copy · ⇥ regions · esc cancel"
) -> String {
  let options = [
    "Approve and execute", "Approve and compact context",
    long
      ? "Approve and keep context (~47k / 1m) — then save every draft note as it changes"
      : "Approve and keep context (~47k / 1m)",
    "Refine plan", "Save and quit",
  ]
  let inner = width - 4
  var out = ["╭─ Plan Review \(String(repeating: "─", count: width - 17))╮"]
  func row(_ content: String) {
    // Dart's padRight and substring count UTF-16 code units; every character here is one.
    let padded = content + String(repeating: " ", count: max(0, inner - content.utf16.count))
    let line = Array("│ \(padded) │".utf16)
    var i = 0
    while i < line.count {
      out.append(String(decoding: line[i..<min(i + width, line.count)], as: UTF16.self))
      i += width
    }
  }
  for r in ["# Notes plan", "", "1. Read the notes store", "2. Save drafts on close", ""] { row(r) }
  out.append("├\(String(repeating: "─", count: width - 2))┤")
  row("Plan mode - next step")
  if slider {
    row("continue with  ◂  smol │ default │ slow  ▸")
    row("  ↳ Claude Sonnet 4.5")
  }
  for (i, o) in options.enumerated() { row("\(i == cursor ? "❯" : " ") \(o)") }
  out.append("├\(String(repeating: "─", count: width - 2))┤")
  row(help)
  out.append("╰\(String(repeating: "─", count: width - 2))╯")
  return out.joined(separator: "\n")
}
