#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

@testable import PocketTermDesktop

final class TerminalFixesTests: XCTestCase {
  private final class Opened: @unchecked Sendable {
    let lock = NSLock()
    var urls: [String] = []
  }

  func testTheAutomationFixOpensSystemSettingsWhereAutomationIsAllowed() async {
    let opened = Opened()
    let r = await fixTerminal(
      Terminals(home: "/nonexistent"), TermStatus("iterm", "iTerm2", .setup, fix: .automation),
      open: { url in opened.lock.withLock { opened.urls.append(url) } })
    XCTAssertEqual(r, TerminalFixResult(note: "Turn on iTerm2 under PocketTerm, then come back here.", failed: false))
    XCTAssertEqual(
      opened.urls, ["x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"])
  }

  func testKittysFixAddsItsLinesToKittyConfKeepingTheOldOne() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipIf(
      env["KITTY_CONFIG_DIRECTORY"] != nil || env["XDG_CONFIG_HOME"] != nil,
      "kitty.conf would be looked for outside the test's home")
    let home = systemScratchDir(self, "pocketterm-fixes")
    systemWrite("\(home)/.config/kitty/kitty.conf", "font_size 13\n")
    let r = await fixTerminal(
      Terminals(home: home, kitty: Kitty(home: home)), TermStatus("kitty", "kitty", .setup, fix: .kittyConfig),
      open: { _ in XCTFail("opened") })
    XCTAssertFalse(r.failed)
    XCTAssertEqual(
      r.note,
      "Added to kitty.conf (the old one is kitty.conf.pocketterm-backup). Quit and reopen kitty to let PocketTerm in.")
    let conf = try String(contentsOfFile: "\(home)/.config/kitty/kitty.conf", encoding: .utf8)
    XCTAssertTrue(Kitty.configured(conf))
    XCTAssertEqual(
      try String(contentsOfFile: "\(home)/.config/kitty/kitty.conf.pocketterm-backup", encoding: .utf8),
      "font_size 13\n")
  }

  func testAKittyConfThatCantBeChangedFailsSoTheButtonStays() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipIf(env["KITTY_CONFIG_DIRECTORY"] != nil || env["XDG_CONFIG_HOME"] != nil)
    let home = systemScratchDir(self, "pocketterm-fixes")
    // A file where kitty's folder should be.
    systemWrite("\(home)/.config/kitty", "")
    let r = await fixTerminal(
      Terminals(home: home, kitty: Kitty(home: home)), TermStatus("kitty", "kitty", .setup, fix: .kittyConfig))
    XCTAssertTrue(r.failed)
    XCTAssertTrue(r.note.hasPrefix("Couldn't change kitty.conf: "), r.note)
  }

  func testNoFixNothingToSay() async {
    let r = await fixTerminal(Terminals(home: "/nonexistent"), TermStatus("tmux", "tmux", .ready))
    XCTAssertEqual(r, TerminalFixResult(note: "", failed: false))
  }

  func testTheTerminalsNeedingSetupAreTheOnesWaitingForThePerson() {
    let statuses = [
      TermStatus("kitty", "kitty", .setup, fix: .kittyConfig),
      TermStatus("iterm", "iTerm2", .ready),
      TermStatus("wezterm", "WezTerm", .missing, fix: .install),
      TermStatus("ghostty", "Ghostty", .missing),
      TermStatus("tmux", "tmux", .idle),
    ]
    XCTAssertEqual(terminalsNeedingSetup(statuses).map(\.id), ["kitty", "wezterm"])
  }

  func testTmuxAloneIsNoTerminalApp() {
    XCTAssertTrue(noTerminalApp([TermStatus("tmux", "tmux", .ready), TermStatus("kitty", "kitty", .missing)]))
    XCTAssertFalse(noTerminalApp([TermStatus("tmux", "tmux", .missing), TermStatus("iterm", "iTerm2", .idle)]))
    // One to install counts: the setup offers it.
    XCTAssertFalse(noTerminalApp([TermStatus("wezterm", "WezTerm", .missing, fix: .install)]))
    XCTAssertTrue(noTerminalApp([]))
  }
}
#endif
