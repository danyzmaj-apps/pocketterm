import PocketTermKit
import SwiftUI
import XCTest

@testable import PocketTerm
private typealias Fg = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
private typealias Bg = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute

nonisolated final class TerminalTests: XCTestCase {
  @MainActor
  private func window(
    _ key: String = "kitty-1/1", program: String = "omp", caps: Set<TermCap> = allCaps
  ) -> TermWindow {
    TermWindow(key: key, title: "", tab: "", cwd: "/Users/me/x", program: program, caps: caps)
  }

  @MainActor
  private func session(window: String) -> LiveSummary {
    LiveSummary(json: ["key": .string(window), "id": "s1", "window": .string(window), "title": "Fix it"])!
  }

  /// A screen-only agent window switches only when PocketTerm is in its agent, its terminal presses keys and
  /// types, and no live session claims it.
  @MainActor
  func testSwitchableNeedsTheIntegrationKeysTypingAndNoSession() {
    let installed: [Agent: AgentIntegration] = [.omp: .installed]
    XCTAssertTrue(switchable(window(), agents: installed, sessions: []))
    XCTAssertFalse(switchable(window(program: "zsh"), agents: installed, sessions: []), "no agent in it")
    XCTAssertFalse(switchable(window(), agents: [:], sessions: []), "PocketTerm not in omp")
    XCTAssertFalse(switchable(window(program: "claude"), agents: installed, sessions: []), "only omp has it")
    XCTAssertFalse(switchable(window(caps: allCaps.subtracting([.keys])), agents: installed, sessions: []))
    XCTAssertFalse(switchable(window(caps: allCaps.subtracting([.type])), agents: installed, sessions: []))
    XCTAssertFalse(switchable(window(), agents: installed, sessions: [session(window: "kitty-1/1")]))
    XCTAssertTrue(switchable(window(), agents: installed, sessions: [session(window: "kitty-1/2")]))
  }

  @MainActor
  func testCloseWordingNamesTheAgentOrWhatRuns() {
    let agent = closeWording(window(), computer: "MacBook", path: "~/x")
    XCTAssertEqual(agent.title, "End this omp session on MacBook?")
    XCTAssertEqual(agent.detail, "Its window in ~/x closes with it.")
    XCTAssertEqual(agent.action, "End session")

    let shell = closeWording(window(program: "vim"), computer: nil, path: "")
    XCTAssertEqual(shell.title, "Close this window on the computer?")
    XCTAssertEqual(shell.detail, "vim stops with it.")
    XCTAssertEqual(shell.action, "Close window")
    XCTAssertEqual(closeWording(window(program: ""), computer: nil, path: "~").detail, "Whatever runs in it in ~ stops with it.")
  }

  @MainActor
  func testScreenLineStylesTheEscapesAndDropsTheRest() {
    let c = TermColors.fallback
    let line = screenLine("a\u{1b}[1;31mred\u{1b}[0m \u{1b}[4;7mrev\u{1b}]8;;https://x\u{07}", c)
    XCTAssertEqual(String(line.characters), "ared rev")
    let runs = Array(line.runs)
    XCTAssertEqual(runs.count, 4)
    XCTAssertEqual(String(line[runs[1].range].characters), "red")
    XCTAssertEqual(runs[1][Fg.self], TermColors.xterm(1).color)
    XCTAssertEqual(runs[1].inlinePresentationIntent, .stronglyEmphasized)
    XCTAssertNil(runs[0].inlinePresentationIntent)
    XCTAssertEqual(runs[0][Fg.self], c.foreground.color)
    // Reversed: the default colours swap.
    XCTAssertEqual(runs[3][Fg.self], c.background.color)
    XCTAssertEqual(runs[3][Bg.self], c.foreground.color)
    XCTAssertEqual(runs[3][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self], .single)
  }

  @MainActor
  func testAnEmptyLineKeepsItsHeight() {
    XCTAssertEqual(String(screenLine("", .fallback).characters), " ")
    XCTAssertEqual(String(screenLine("\u{1b}[0m", .fallback).characters), " ")
  }

  @MainActor
  func testScreenLinesRemakeForNewColours() {
    let cache = ScreenLines()
    let other = TermColors(
      foreground: TermColor(argb: 0xFF11_2233), background: .init(argb: 0xFF00_0000), palette: TermColors.fallback.palette)
    XCTAssertEqual(cache.line("x", .fallback).runs.first?[Fg.self], TermColors.fallback.foreground.color)
    XCTAssertEqual(cache.line("x", other).runs.first?[Fg.self], other.foreground.color)
  }
}
