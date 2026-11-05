import PocketTermKit
import XCTest

@testable import PocketTerm

/// The conversation page's logic: prompts on their way and how the agent's copy replaces them
/// (prompt_bubble_test), the queue as the phone shows it (queue_strip_test, queue_screen_test), Markdown blocks.
nonisolated final class SessionTests: XCTestCase {
  private func user(_ id: String, _ text: String, _ order: Int) -> LiveItem {
    LiveItem(id: id, kind: .user, text: text, order: order)
  }

  private func answer(_ id: String, _ order: Int) -> LiveItem { LiveItem(id: id, kind: .assistant, text: "ok", order: order) }

  private func summary(busy: Bool = false, ask: LiveAsk? = nil, queue: [LiveQueued] = []) -> LiveSummary {
    LiveSummary(key: "k", id: "s1", title: "t", cwd: "/p", epoch: "e1", seq: 0, busy: busy, ask: ask, queue: queue)
  }

  // MARK: Outgoing

  @MainActor func testTheAgentsCopyReplacesItNeverBoth() {
    let v = LiveView(epoch: "e1", items: [answer("a1", 1)])
    let o = Outgoing("fix the tests", [], followUp: false, transcript: v)
    // A catch-up that doesn't have it yet keeps it.
    XCTAssertEqual(stillOutgoing([o], view: v, summary: summary()).count, 1)
    let back = LiveView(epoch: "e1", items: [answer("a1", 1), user("u1", "fix the tests", 2)])
    XCTAssertTrue(stillOutgoing([o], view: back, summary: summary()).isEmpty)
  }

  @MainActor func testTheComputerMayAddToItsCopyAndSpacesDontCount() {
    let v = LiveView(epoch: "e1", items: [answer("a1", 1)])
    let o = Outgoing("read   this", [], followUp: false, transcript: v)
    let back = LiveView(epoch: "e1", items: [answer("a1", 1), user("u1", "read this @/tmp/pocketterm/notes.md", 2)])
    XCTAssertEqual(cameBack([o], back), [ObjectIdentifier(o)])
  }

  @MainActor func testAnEarlierPromptWithTheSameTextIsntItComingBack() {
    let v = LiveView(epoch: "e1", items: [user("u0", "continue", 1)])
    let o = Outgoing("continue", [], followUp: false, transcript: v)
    XCTAssertTrue(cameBack([o], v).isEmpty)
    let back = LiveView(epoch: "e1", items: [user("u0", "continue", 1), user("u1", "continue", 2)])
    XCTAssertEqual(cameBack([o], back).count, 1)
  }

  @MainActor func testTwoAlikeComeBackOneItemEach() {
    let v = LiveView(epoch: "e1", items: [answer("a1", 1)])
    let a = Outgoing("yes", [], followUp: false, transcript: v)
    let b = Outgoing("yes", [], followUp: false, transcript: v)
    let one = LiveView(epoch: "e1", items: [answer("a1", 1), user("u1", "yes", 2)])
    XCTAssertEqual(cameBack([a, b], one), [ObjectIdentifier(a)])
    let both = LiveView(epoch: "e1", items: [answer("a1", 1), user("u1", "yes", 2), user("u2", "yes", 3)])
    XCTAssertEqual(cameBack([a, b], both).count, 2)
  }

  @MainActor func testATranscriptStartedOverIsSearchedFromTheStart() {
    let v = LiveView(epoch: "e1", items: [answer("a1", 5)])
    let o = Outgoing("go", [], followUp: false, transcript: v)
    let fresh = LiveView(epoch: "e2", items: [user("n1", "go", 0)])
    XCTAssertEqual(cameBack([o], fresh).count, 1)
  }

  @MainActor func testAQueuedPromptGoesOnceTheQueueListsIt() {
    let v = LiveView(epoch: "e1", items: [answer("a1", 1)])
    let o = Outgoing("then update the docs", [], followUp: true, transcript: v)
    o.sending = false
    o.queued = "q1"
    XCTAssertTrue(o.waiting)
    XCTAssertEqual(stillOutgoing([o], view: v, summary: summary(busy: true)).count, 1)
    let listed = summary(busy: true, queue: [LiveQueued(id: "q1", text: "then update the docs")])
    XCTAssertTrue(stillOutgoing([o], view: v, summary: listed).isEmpty)
    // One that left the queue at rest went to the agent.
    XCTAssertTrue(stillOutgoing([o], view: v, summary: summary()).isEmpty)
  }

  @MainActor func testAFollowUpWithoutAQueueIdStaysUntilTheAgentTakesIt() {
    let v = LiveView(epoch: "e1", items: [answer("a1", 1)])
    let o = Outgoing("then update the docs", [], followUp: true, transcript: v)
    o.sending = false
    XCTAssertTrue(o.waiting)
    XCTAssertEqual(stillOutgoing([o], view: v, summary: summary()).count, 1)
    let back = LiveView(epoch: "e1", items: [answer("a1", 1), user("u1", "then update the docs", 2)])
    XCTAssertTrue(stillOutgoing([o], view: back, summary: summary()).isEmpty)
  }

  @MainActor func testAFailedOneIsntWaiting() {
    let o = Outgoing("deploy it", [], followUp: false, transcript: nil)
    o.sending = false
    o.problem = "That session has ended."
    XCTAssertFalse(o.waiting)
  }

  // MARK: Queue view

  private let q = ["a", "b", "c", "d"].map { LiveQueued(id: $0, text: $0) }

  @MainActor func testAMoveShowsAtOnceUntilTheComputerAgrees() {
    let view = QueueView()
    let (all, shown) = view.items(q)
    // Dragged from the top to the third place.
    XCTAssertEqual(view.drop(all, shown, 0, 2), 2)
    XCTAssertEqual(view.items(q).shown.map(\.id), ["b", "c", "a", "d"])
    // The computer has it too: its order again.
    let moved = ["b", "c", "a", "d"].map { LiveQueued(id: $0, text: $0) }
    XCTAssertEqual(view.items(moved).all.map(\.id), ["b", "c", "a", "d"])
    XCTAssertNil(view.order)
  }

  @MainActor func testAMoveAmongShownCountsTheGoingOnes() {
    let view = QueueView()
    view.gone.insert("b")
    let (all, shown) = view.items(q)
    XCTAssertEqual(shown.map(\.id), ["a", "c", "d"])
    // "d" up above "c": before it among all, those going too.
    XCTAssertEqual(view.drop(all, shown, 2, 1), 2)
    XCTAssertEqual(view.items(q).all.map(\.id), ["a", "b", "d", "c"])
    // To the bottom: after the one above.
    let (all2, shown2) = view.items(q)
    XCTAssertEqual(view.drop(all2, shown2, 0, 2), 3)
    XCTAssertEqual(view.items(q).shown.map(\.id), ["d", "c", "a"])
  }

  @MainActor func testARefusedMoveGoesBackAndGoneOnesComeBackOnlyIfStillThere() {
    let view = QueueView()
    view.put(q, "d", 0)
    XCTAssertEqual(view.items(q).all.map(\.id), ["d", "a", "b", "c"])
    view.forgetOrder()
    XCTAssertEqual(view.items(q).all.map(\.id), ["a", "b", "c", "d"])
    view.gone = ["a", "zz"]
    XCTAssertEqual(view.items(q).shown.map(\.id), ["b", "c", "d"])
    XCTAssertEqual(view.gone, ["a"])
  }

  @MainActor func testOnMoveDestinationsAreThePlaceOnceMoved() {
    XCTAssertEqual(movedPlace(from: 0, destination: 3), 2)
    XCTAssertEqual(movedPlace(from: 3, destination: 0), 0)
    XCTAssertEqual(movedPlace(from: 1, destination: 1), 1)
  }

  @MainActor func testOnlyPlainTextQueuesAgainAndOnlyWhileTheAgentWorks() {
    let working = summary(busy: true)
    XCTAssertTrue(requeueable(LiveQueued(id: "1", text: "docs"), in: working))
    XCTAssertTrue(requeueable(LiveQueued(id: "1", text: "docs"), in: summary(ask: .approval("x", tool: "bash"))))
    XCTAssertFalse(requeueable(LiveQueued(id: "1", text: "docs"), in: summary()))
    XCTAssertFalse(requeueable(LiveQueued(id: "1", text: "docs"), in: nil))
    XCTAssertFalse(requeueable(LiveQueued(id: "1", text: "docs", images: 1), in: working))
    XCTAssertFalse(requeueable(LiveQueued(id: "1", text: "docs", files: ["a.pdf"]), in: working))
    XCTAssertFalse(requeueable(LiveQueued(id: "1", text: "docs", cut: true), in: working))
    XCTAssertFalse(requeueable(LiveQueued(id: "1", text: " /model"), in: working))
    XCTAssertFalse(requeueable(LiveQueued(id: "1", text: "  "), in: working))
  }

  @MainActor func testExtrasNameImagesThenFiles() {
    XCTAssertEqual(attachedExtras(images: 1, files: ["a.pdf"]), ["\u{2295} 1 image", "a.pdf"])
    XCTAssertEqual(attachedExtras(images: 3), ["\u{2295} 3 images"])
    XCTAssertEqual(attachedExtras(images: 0), [])
  }

  // MARK: Markdown

  @MainActor func testMarkdownBlocks() {
    let md = """
      # Plan
      First line
      second line

      - one
        more of one
      - two
        1. nested

      ```swift
      let x = 1
        indented
      ```
      > quoted
      ---
      | a | b |
      |---|:-:|
      | 1 | 2 |
      """
    XCTAssertEqual(
      markdownBlocks(md),
      [
        .heading(level: 1, text: "Plan"),
        .paragraph("First line\nsecond line"),
        .list([
          MdListItem(marker: "\u{2022}", text: "one\nmore of one", depth: 0),
          MdListItem(marker: "\u{2022}", text: "two", depth: 0),
          MdListItem(marker: "1.", text: "nested", depth: 1),
        ]),
        .code(language: "swift", text: "let x = 1\n  indented"),
        .quote("quoted"),
        .rule,
        .table(header: ["a", "b"], rows: [["1", "2"]]),
      ])
  }

  @MainActor func testAnUnclosedFenceRunsToTheEndAndInlineBackticksArentOne() {
    XCTAssertEqual(markdownBlocks("```\ncode\nmore"), [.code(language: "", text: "code\nmore")])
    XCTAssertEqual(markdownBlocks("```a``` b"), [.paragraph("```a``` b")])
  }

  @MainActor func testSetextHeadings() {
    XCTAssertEqual(markdownBlocks("Title\n===\ntext"), [.heading(level: 1, text: "Title"), .paragraph("text")])
  }

  @MainActor func testInlineMarkdownKeepsLineBreaksAndCode() {
    let s = inlineMarkdown("a `b`\nc")
    XCTAssertEqual(String(s.characters), "a b\nc")
    XCTAssertTrue(s.runs.contains { $0.inlinePresentationIntent == .code })
  }
}
