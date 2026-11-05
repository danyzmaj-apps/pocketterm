import Foundation
import PocketTermKit
import XCTest

@testable import PocketTerm

/// The demo's computer: made up, in two projects, answering the phone itself with nothing on the network
/// (its server is http://localhost:1 and is never asked).
nonisolated final class DemoTests: XCTestCase {
  nonisolated(unsafe) private var demo: DemoComputer!
  nonisolated(unsafe) private var dir: URL!

  @MainActor private func start() {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
    demo = DemoComputer(cacheDir: dir)
  }

  @MainActor private func stop() {
    demo.dispose()
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "dispose removes the cache")
  }

  /// Lets the demo's answers (sent on the next main-actor turn) arrive.
  @MainActor private func settle() async {
    for _ in 0..<5 { await Task.yield() }
  }

  @MainActor func testAMadeUpComputerInTwoProjects() async {
    start()
    defer { stop() }
    let remote = demo.remote
    XCTAssertEqual(demo.desktops.all.map(\.id), [DemoComputer.desktopId])
    XCTAssertEqual(demo.desktops.all.first?.name, "MacBook Pro")
    XCTAssertTrue(remote.online)
    XCTAssertEqual(remote.projects, [demoGarden, demoSite])
    XCTAssertEqual(
      remote.sessions.map(\.title),
      ["Add a soil moisture endpoint", "Fix the pricing table on small screens", "Rate-limit the plant search"])
    XCTAssertEqual(remote.windows.count, 6)
    XCTAssertEqual(remote.session("tmux-%4")?.queue.map(\.id), ["dq1", "dq2", "dq3", "dq4"])
    XCTAssertNotNil(remote.session("wezterm-2")?.ask)
  }

  @MainActor func testAPromptGetsTheDemoReply() async throws {
    start()
    defer { stop() }
    let remote = demo.remote
    try await remote.prompt("wezterm-2", "Also check the footer")
    await settle()
    let texts = remote.view("wezterm-2")?.items.map(\.text) ?? []
    XCTAssertTrue(texts.contains("Also check the footer"))
    XCTAssertTrue(texts.contains { $0.hasPrefix("This is the demo: there's no computer behind it") })
  }

  @MainActor func testAnApprovalCarriesOn() async throws {
    start()
    defer { stop() }
    let remote = demo.remote
    let ask = try XCTUnwrap(remote.session("wezterm-2")?.ask)
    try await remote.answer("wezterm-2", ask, approve: true)
    await settle()
    XCTAssertNil(remote.session("wezterm-2")?.ask)
    XCTAssertTrue(remote.view("wezterm-2")?.items.last?.text.hasPrefix("Built in 6.2 s") == true)
  }

  @MainActor func testAFollowUpQueuesAndTheQueueChanges() async throws {
    start()
    defer { stop() }
    let remote = demo.remote
    let id = try await remote.prompt("tmux-%4", "And the docs", followUp: true)
    XCTAssertEqual(id, "dq5")
    XCTAssertEqual(remote.session("tmux-%4")?.queue.map(\.id), ["dq1", "dq2", "dq3", "dq4", "dq5"])
    try await remote.moveQueued("tmux-%4", "dq3", 0)
    XCTAssertEqual(remote.session("tmux-%4")?.queue.map(\.id), ["dq3", "dq1", "dq2", "dq4", "dq5"])
    try await remote.removeQueued("tmux-%4", "dq1")
    try await remote.pauseQueue("tmux-%4", paused: true)
    XCTAssertEqual(remote.session("tmux-%4")?.paused, true)
    do {
      try await remote.removeQueued("tmux-%4", "dq1")
      XCTFail("gone already")
    } catch {}
  }

  /// Flutter's queue screen: a prompt deleted there comes back with Undo where it was, queued again under a new id.
  @MainActor func testADeletedPromptComesBackWithUndoInItsPlace() async throws {
    start()
    defer { stop() }
    let remote = demo.remote
    let model = QueueScreenModel(remote: remote, session: "tmux-%4")
    model.start()
    defer { model.stop() }
    let dq2 = try XCTUnwrap(remote.session("tmux-%4")?.queue[1])
    await model.delete(dq2, at: 1)
    XCTAssertEqual(remote.session("tmux-%4")?.queue.map(\.id), ["dq1", "dq3", "dq4"])
    XCTAssertTrue(model.sent.isEmpty, "one deleted didn't go to the agent")
    let toast = try XCTUnwrap(Toaster.shared.current)
    XCTAssertEqual(toast.message, "Deleted")
    XCTAssertEqual(toast.action, "Undo")
    toast.handler?()
    for _ in 0..<200 where remote.session("tmux-%4")?.queue.count != 4 { await Task.yield() }
    await settle()
    let queue = try XCTUnwrap(remote.session("tmux-%4")?.queue)
    XCTAssertEqual(queue[1].text, dq2.text)
    XCTAssertEqual(queue.map(\.id), ["dq1", "dq5", "dq3", "dq4"])
  }

  /// One sent now from the queue screen shows as Sent for a moment, then goes.
  @MainActor func testOneSentNowShowsAsSentAMoment() async throws {
    start()
    defer { stop() }
    let remote = demo.remote
    let model = QueueScreenModel(remote: remote, session: "tmux-%4")
    model.start()
    defer { model.stop() }
    let dq3 = try XCTUnwrap(remote.session("tmux-%4")?.queue[2])
    model.sendNow(dq3)
    for _ in 0..<200 where model.sent.isEmpty { await Task.yield() }
    XCTAssertEqual(remote.session("tmux-%4")?.queue.map(\.id), ["dq1", "dq2", "dq4"])
    XCTAssertEqual(model.sent.map(\.item.id), ["dq3"])
    try await Task.sleep(for: .seconds(QueueScreenModel.sentFor + 0.5))
    XCTAssertTrue(model.sent.isEmpty)
  }

  @MainActor func testWhatItCantPretendSaysSo() async {
    start()
    defer { stop() }
    do {
      try await demo.remote.close("kitty-1/1")
      XCTFail("the demo closes nothing")
    } catch {
      XCTAssertTrue("\(error)".contains(demoNoComputer))
    }
  }
}
