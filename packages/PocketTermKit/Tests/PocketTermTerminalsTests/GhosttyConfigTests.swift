#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

final class GhosttyConfigTests: XCTestCase {
  private var dir = ""
  private var xdg = ""
  private var support = ""
  private var config = GhosttyConfig([])

  private let tmux = "/opt/homebrew/bin/tmux"
  private var ours: String { "\(GhosttyConfig.marker)\n\(GhosttyConfig.line(tmux))\n" }
  private let fm = FileManager.default

  override func setUp() {
    dir = realPathOf(fm.temporaryDirectoryForTests("pocketterm-ghostty-"))
    xdg = "\(dir)/.config/ghostty/config.ghostty"
    support = "\(dir)/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
    config = GhosttyConfig.standard(home: dir)
  }

  override func tearDown() { try? fm.removeItem(atPath: dir) }

  private func write(_ path: String, _ text: String) {
    try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! text.write(toFile: path, atomically: false, encoding: .utf8)
  }

  private func read(_ path: String) -> String { try! String(contentsOfFile: path, encoding: .utf8) }

  private func mode(_ path: String) -> Int { (try! fm.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue }

  func testWithNoConfigAnywhereCreatesTheXDGOneWithJustItsLines() throws {
    XCTAssertEqual(config.read().state, .none)
    XCTAssertEqual(try config.add(tmux), xdg)
    XCTAssertEqual(read(xdg), ours)
    XCTAssertEqual(
      config.read(), GhosttyCommand(state: .ours, command: String(GhosttyConfig.line(tmux).dropFirst(10))))
  }

  func testTheLineRunsTheAbsoluteTmuxInASessionPerWindowThatEndsWithItAndNamesItInTheTitle() {
    XCTAssertEqual(
      GhosttyConfig.line(tmux),
      #"command = /opt/homebrew/bin/tmux new-session \; set-option destroy-unattached on"#
        + #" \; set-option set-titles on \; set-option set-titles-string '#T (tmux #S)'"#)
    XCTAssertTrue(GhosttyConfig.line("/Users/a b/tmux").hasPrefix("command = '/Users/a b/tmux' new-session"))
  }

  func testWritesToTheApplicationSupportFileWhenItIsTheOneThatExists() throws {
    write(support, "font-size = 14\n")
    XCTAssertEqual(try config.add(tmux), support)
    XCTAssertEqual(read(support), "font-size = 14\n\(ours)")
    XCTAssertFalse(fm.fileExists(atPath: xdg))
  }

  func testRemoveLeavesTheFileByteIdenticalToBeforeAdd() throws {
    for before in ["", "font-size = 14\ntheme = dark\n", "font-size = 14", "# just a comment\n\n"] {
      write(xdg, before)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: xdg)
      try config.add(tmux)
      XCTAssertTrue(read(xdg).hasPrefix(before), before)
      XCTAssertEqual(config.read().state, .ours, before)
      XCTAssertEqual(mode(xdg), 0o600, "permissions kept")
      try config.remove()
      XCTAssertEqual(read(xdg), before)
      XCTAssertEqual(config.read().state, .none, before)
      XCTAssertEqual(mode(xdg), 0o600, "permissions kept")
    }
  }

  func testRemoveTakesOnlyTheMarkedLinesWhereverTheyAreEvenAfterEditsAroundThem() throws {
    write(xdg, "a = 1\n")
    try config.add(tmux)
    write(xdg, read(xdg) + "b = 2\n")
    try config.remove()
    XCTAssertEqual(read(xdg), "a = 1\nb = 2\n")
  }

  func testACommandOfThePersonsOwnBlocksAddingInAnyFileGhosttyReads() throws {
    for line in ["command = /bin/zsh -l", "command=fish", #"  command  =  "nu"  "#] {
      write(support, "# command = ignored\nfont-size = 14\n\(line)\n")
      let before = read(support)
      XCTAssertEqual(config.read().state, .theirs, line)
      XCTAssertNil(try config.add(tmux))
      XCTAssertEqual(read(support), before)
      XCTAssertFalse(fm.fileExists(atPath: xdg))
    }
    XCTAssertEqual(config.read().command, "nu")
  }

  func testACommentedOutOrEmptiedCommandIsNotOne() {
    write(xdg, "# command = /bin/zsh\ncommand =\n")
    XCTAssertEqual(config.read().state, .none)
  }

  func testAHandEditToOurLineStillReadsAsOursAndRemoveTakesIt() throws {
    write(xdg, "\(GhosttyConfig.marker)\ncommand = /usr/local/bin/tmux new-session\n")
    XCTAssertEqual(config.read(), GhosttyCommand(state: .ours, command: "/usr/local/bin/tmux new-session"))
    try config.remove()
    XCTAssertEqual(read(xdg), "")
  }

  func testRemoveTakesTheLineAnEarlierPocketTermWroteToo() throws {
    write(
      xdg,
      "a = 1\n\(GhosttyConfig.marker)\n" + #"command = /opt/homebrew/bin/tmux new-session \; set-option destroy-unattached on"#
        + "\n")
    XCTAssertEqual(config.read().state, .ours)
    try config.remove()
    XCTAssertEqual(read(xdg), "a = 1\n")
  }

  private let old = #"command = /opt/homebrew/bin/tmux new-session \; set-option destroy-unattached on"#

  func testUpgradeAnEarlierPocketTermsLineBecomesThisOnesEveryOtherByteAndThePermissionsStay() throws {
    // Around it: the person's lines, a CRLF one, and no newline at the end.
    let before = "font-size = 14\r\n# a comment\n\(GhosttyConfig.marker)\n\(old)\ntheme = dark"
    write(xdg, before)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: xdg)
    XCTAssertTrue(try config.upgrade(tmux))
    XCTAssertEqual(read(xdg), before.replacingOccurrences(of: old, with: GhosttyConfig.line(tmux)))
    XCTAssertEqual(mode(xdg), 0o600, "permissions kept")
    XCTAssertFalse(try config.upgrade(tmux), "once")
    try config.remove()
    XCTAssertEqual(read(xdg), "font-size = 14\r\n# a comment\ntheme = dark")
  }

  func testUpgradeNeverTouchesACommandOfThePersonsOwn() throws {
    let mine = "# command = /bin/zsh\n\(old)\n"
    write(support, mine)
    write(xdg, "\(GhosttyConfig.marker)\ncommand =\n")
    XCTAssertFalse(try config.upgrade(tmux))
    XCTAssertEqual(read(support), mine)
    XCTAssertEqual(read(xdg), "\(GhosttyConfig.marker)\ncommand =\n")
  }

  func testWritesThroughASymlinkedConfigToItsTarget() throws {
    let real = "\(dir)/dotfiles/ghostty"
    write(real, "a = 1\n")
    try fm.createDirectory(atPath: "\(dir)/.config/ghostty", withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: xdg, withDestinationPath: real)
    try config.add(tmux)
    XCTAssertEqual(fileKind(xdg), .link)
    XCTAssertEqual(read(real), "a = 1\n\(ours)")
    try config.remove()
    XCTAssertEqual(read(real), "a = 1\n")
  }
}
#endif
