import PocketTermKit
import XCTest

@testable import PocketTerm

/// The Terminal list's logic (terminal_list_test.dart's): projects in a steady order, where terminals sit on the
/// computer, and why agent windows show only as screens.
nonisolated final class HomeTests: XCTestCase {
  private let a = "/Users/me/a"
  private let b = "/Users/me/b"
  private let c = "/Users/me/c"
  private let z = "/Users/me/z"
  private let home = "/Users/me"

  @MainActor private func summary(
    _ key: String, _ cwd: String, at minutesAgo: Double? = nil, busy: Bool = false, now: Date = Date()
  ) -> LiveSummary {
    LiveSummary(
      key: key, id: key, title: key, cwd: cwd, epoch: "e", seq: 0, busy: busy,
      at: minutesAgo.map { now.addingTimeInterval(-$0 * 60) })
  }

  /// z: an older one first, then a newer one; a: idle; b: working; c: no window; one somewhere unknown.
  @MainActor private func macSessions(now: Date) -> [LiveSummary] {
    [
      summary("kitty-1/2", a, at: 10, now: now),
      summary("kitty-1/3", b, at: 0, busy: true, now: now),
      summary("pid:9", c, at: 15, now: now),
      summary("pid:8", "", at: 16, now: now),
      summary("kitty-1/5", z, at: 1, now: now),
      summary("kitty-1/1", z, at: 20, now: now),
    ]
  }

  @MainActor func testProjectsGoByNameSessionsInTheComputersOrderSomewhereLast() {
    let groups = groupedSessions(macSessions(now: Date()), .name, home: home)
    XCTAssertEqual(groups.map(\.cwd), [a, b, c, z, ""])
    XCTAssertEqual(groups[3].sessions.map(\.key), ["kitty-1/5", "kitty-1/1"], "the computer's order, not lifted")
  }

  @MainActor func testHomeFolderSortsAsGeneral() {
    let groups = groupedSessions([summary("1", z), summary("2", home), summary("3", a)], .name, home: home)
    XCTAssertEqual(groups.map(\.cwd), [a, home, z])
  }

  @MainActor func testByActivityProjectsKeepTheirRankUntilRankedAfresh() {
    let now = Date()
    var sessions = macSessions(now: now)
    let first = groupedSessions(sessions, .activity, home: home)
    XCTAssertEqual(first.map(\.cwd), [b, z, a, c, ""])

    // a gets busy now: it stays where it is while ranked.
    sessions[0].busy = true
    sessions[0].at = now.addingTimeInterval(1)
    let kept = groupedSessions(sessions, .activity, ranked: first.map(\.cwd), home: home)
    XCTAssertEqual(kept.map(\.cwd), [b, z, a, c, ""])

    // A project that wasn't ranked yet goes first; one that's gone drops out.
    let newer = sessions.filter { $0.cwd != c } + [summary("new", "/Users/me/n", at: 30, now: now)]
    XCTAssertEqual(
      groupedSessions(newer, .activity, ranked: first.map(\.cwd), home: home).map(\.cwd),
      ["/Users/me/n", b, z, a, ""])

    // Refreshed (nothing ranked): afresh.
    XCTAssertEqual(groupedSessions(sessions, .activity, home: home).map(\.cwd), [a, b, z, c, ""])
  }

  @MainActor private func pane(_ key: String, _ osWindow: String, _ tabId: String, app: String = "kitty", via: String = "")
    -> TermWindow
  {
    TermWindow(key: key, title: "", tab: "", cwd: "", program: "zsh", app: app, via: via, osWindow: osWindow, tabId: tabId)
  }

  @MainActor func testWindowsCountPerAppAndTabsPerWindowInListOrderPanesShareTheirTab() {
    let windows = [
      pane("tmux-%1", "ghostty-w1", "ghostty-t1", app: "tmux", via: "Ghostty"),
      pane("kitty-1/1", "kitty-1/w1", "kitty-1/t1"),
      pane("kitty-1/2", "kitty-1/w2", "kitty-1/t2"),
      pane("ghostty-1", "ghostty-w1", "ghostty-t2", app: "ghostty"),
      pane("kitty-1/3", "kitty-1/w1", "kitty-1/t1"),
      // An older computer's: where it sits is unknown.
      pane("kitty-2/1", "", ""),
      // Its window known, not its tab: a tab of its own.
      pane("kitty-1/4", "kitty-1/w1", ""),
    ]
    let layout = macLayout(windows)
    XCTAssertEqual(layout.map(\.id), ["ghostty-w1", "kitty-1/w1", "kitty-1/w2"])
    XCTAssertEqual(layout.map(\.app), ["Ghostty", "kitty", "kitty"])
    XCTAssertEqual(layout.map(\.number), [1, 1, 2])
    XCTAssertEqual(layout[1].tabs.map(\.number), [1, 2])
    XCTAssertEqual(layout[1].tabs.map { $0.panes.map(\.key).joined(separator: " ") }, ["kitty-1/1 kitty-1/3", "kitty-1/4"])
    XCTAssertEqual(
      macPlaces(layout),
      [
        "tmux-%1": "Ghostty window 1 · tab 1",
        "ghostty-1": "Ghostty window 1 · tab 2",
        "kitty-1/1": "kitty window 1 · tab 1",
        "kitty-1/3": "kitty window 1 · tab 1",
        "kitty-1/4": "kitty window 1 · tab 2",
        "kitty-1/2": "kitty window 2 · tab 1",
      ])
    XCTAssertEqual(layoutCount(layout), "3 windows · 5 tabs")
    XCTAssertEqual(layoutCount(Array(layout.prefix(1)).map { MacWindow(id: $0.id, app: $0.app, number: 1, tabs: [$0.tabs[0]]) }), "1 window · 1 tab")
    // The computer's name for its terminal app wins over the phone's.
    XCTAssertEqual(macLayout(windows, terminals: [TermStatus("kitty", "Kitty", .ready)])[1].app, "Kitty")
    XCTAssertTrue(macLayout([pane("kitty-2/1", "", "")]).isEmpty, "an older computer shows no count")
  }

  @MainActor func testATabShowsItsFocusedPane() {
    var focused = pane("kitty-1/3", "w", "t")
    focused.focused = true
    let tab = MacTab(id: "t", number: 1, panes: [pane("kitty-1/2", "w", "t"), focused])
    XCTAssertEqual(tabLead(tab).key, "kitty-1/3")
    XCTAssertEqual(tabLead(MacTab(id: "t", number: 1, panes: [pane("kitty-1/2", "w", "t")])).key, "kitty-1/2")
  }

  @MainActor func testWhyAnAgentWindowShowsOnlyAsAScreen() {
    XCTAssertTrue(screensOnly(.omp, .missing, "Studio").contains("isn\u{2019}t installed in omp on Studio"))
    XCTAssertTrue(screensOnly(.omp, .missing, "the computer").contains("on the computer."))
    XCTAssertTrue(screensOnly(.omp, .installed, "x").contains("started before PocketTerm was installed in omp"))
    XCTAssertTrue(screensOnly(.omp, .installed, "x").contains(Agent.omp.resume))
    XCTAssertTrue(screensOnly(.omp, .outdated, "Studio").contains("out of date on Studio"))
    XCTAssertTrue(screensOnly(.omp, nil, "x").contains("It may be out of date"))
    // Claude Code reloads its plugins in place: nothing to restart.
    for integration in [AgentIntegration.installed, .outdated, .missing, nil] {
      let text = screensOnly(.claude, integration, "x")
      XCTAssertTrue(text.contains("/reload-plugins"), "\(String(describing: integration))")
      XCTAssertFalse(text.contains(Agent.claude.resume), "\(String(describing: integration))")
    }
    XCTAssertEqual(switchHint(1), "1 session shows only its screen. Tap it to switch it to the conversation view.")
    XCTAssertEqual(
      switchHint(3), "3 sessions show only their screen. Tap one to switch it to the conversation view.")
  }

  @MainActor func testAFoldedProjectStillSaysWhatNeedsYou() {
    var asking = summary("1", a)
    asking.ask = .approval("q1", tool: "Bash")
    asking.busy = true
    let s = FoldedSummary([asking, summary("2", a, busy: true), summary("3", a)])
    XCTAssertEqual(s.sessionsText + (s.askingText ?? "") + (s.workingText ?? ""), "3 sessions · 1 needs you · 1 working")
    XCTAssertEqual(FoldedSummary([summary("1", a)]).sessionsText, "1 session")
  }

  @MainActor func testProfileFilterLabels() {
    XCTAssertEqual([profileLabel(nil), profileLabel(""), profileLabel("work")], ["All profiles", "default", "work"])
  }
}
