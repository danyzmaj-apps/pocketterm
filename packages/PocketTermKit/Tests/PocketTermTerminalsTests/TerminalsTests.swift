#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

// terminals_test.dart: real outputs captured from each app (names shortened),
// with the `ps` lines of the same windows.

private let psWezTerm = " 1129  1128  1129 5249 ttys008  Ss+  -zsh\n 5249  1129  5249 5249 ttys008  S+   claude\n"

private let wezList = """
  [
    {
      "window_id": 0, "tab_id": 0, "pane_id": 0, "workspace": "default",
      "size": {"rows": 24, "cols": 80, "pixel_width": 1120, "pixel_height": 768, "dpi": 144},
      "title": "cap-wezterm", "cwd": "file://mac.local/tmp/dzt/cap-wezterm",
      "cursor_x": 15, "cursor_y": 0, "cursor_shape": "Default", "cursor_visibility": "Visible",
      "left_col": 0, "top_row": 0, "tab_title": "", "window_title": "cap-wezterm",
      "is_active": true, "is_zoomed": false, "tty_name": "/dev/ttys008"
    }
  ]
  """

private let nowhere = "/nonexistent-pocketterm"

/// Hosts that touch nothing on this Mac (paths that don't exist).
private func terms() -> Terminals {
  Terminals(
    home: nowhere,
    kitty: Kitty(home: nowhere, socketDir: nowhere, restoreFront: false),
    tmux: Tmux(executable: "\(nowhere)/tmux", socketDirs: []),
    wezterm: WezTerm(executable: "\(nowhere)/wezterm", socketDir: nowhere),
    ghostty: Ghostty(appPath: "\(nowhere)/Ghostty.app"))
}

private func w(
  _ key: String, tty: String = "", app: String = "x", cwd: String = "", osWindow: String = "", tabId: String = "",
  via: String = ""
) -> TermWindow {
  TermWindow(
    key: key, title: "", tab: "", cwd: cwd, program: "", app: app, via: via, tty: tty, osWindow: osWindow, tabId: tabId)
}

private final class RunningGhostty: Ghostty, @unchecked Sendable {
  init() { super.init(appPath: "\(nowhere)/Ghostty.app") }
  override func status(_ procs: Procs) async throws -> TermStatus {
    TermStatus(id, label, .limited, note: "2 windows · \(limits)")
  }
}

/// Ghostty listing these windows.
private final class ListedGhostty: Ghostty, @unchecked Sendable {
  let listed: [TermWindow]
  init(_ listed: [TermWindow]) {
    self.listed = listed
    super.init(appPath: "\(nowhere)/Ghostty.app")
  }
  override func windows(_ procs: Procs) async throws -> [TermWindow] { listed }
}

/// tmux listing these panes, attached by these clients.
private final class ListedTmux: Tmux, @unchecked Sendable {
  let listed: [TermWindow]
  let attached: [String: TmuxClient]
  init(_ listed: [TermWindow], _ attached: [String: TmuxClient]) {
    self.listed = listed
    self.attached = attached
    super.init(executable: "\(nowhere)/tmux", socketDirs: [])
  }
  override func windows(_ procs: Procs) async throws -> [TermWindow] {
    clients = attached
    return listed
  }
}

final class TerminalsTests: XCTestCase {
  // ------------------------------------------------------------ tmux

  func testListPanesAPanePerRecordItsProgramFromTheTtyTheWindowNameForAHostNameTitle() {
    let out =
      "%0\u{1f}/dev/ttys008\u{1f}zsh\u{1f}/private/tmp/dzt/cap-tmux\u{1f}cap-tmux\u{1f}zsh\u{1f}pt-mv82o7z3\u{1f}1\u{1f}1\u{1f}1"
      + "\u{1f}$0\u{1f}@0\u{1e}\n"
      + "%3\u{1f}/dev/ttys012\u{1f}node\u{1f}/Users/me/Dev/x\u{1f}\u{1f}editor\u{1f}work\u{1f}1\u{1f}0\u{1f}0\u{1f}$2\u{1f}@5\u{1e}\n"
    let procs = Procs(parsePs(" 97892 97891 97892 97892 ttys008  Ss+  -zsh\n"))
    let panes = parseTmuxPanes("default", out, procs)
    XCTAssertEqual(panes.map(\.key), ["tmux:default/0", "tmux:default/3"])
    XCTAssertEqual(panes.map(\.osWindow), ["tmux:default/s0", "tmux:default/s2"])
    XCTAssertEqual(panes.map(\.tabId), ["tmux:default/w0", "tmux:default/w5"])
    let first = panes[0]
    XCTAssertEqual(first.title, "cap-tmux")
    XCTAssertEqual(first.tab, "pt-mv82o7z3:zsh")
    XCTAssertEqual(first.cwd, "/private/tmp/dzt/cap-tmux")
    XCTAssertEqual(first.program, "zsh")
    XCTAssertEqual(first.tty, "ttys008")
    XCTAssertTrue(first.focused)
    XCTAssertEqual(first.app, "tmux")
    XCTAssertEqual(first.caps, allCaps)
    // No ps entry: tmux's own idea of the command; an inactive window isn't focused.
    XCTAssertEqual(panes[1].title, "editor")
    XCTAssertEqual(panes[1].program, "node")
    XCTAssertFalse(panes[1].focused)
  }

  func testAFolderWhoseNameHoldsATabOrALineBreakKeepsItsPaneAndThePanesAfterIt() {
    // As tmux 3.8 prints them: the folder's bytes as they are.
    let out =
      "%1\u{1f}/dev/ttys014\u{1f}bash\u{1f}/tmp/ptx/tab\tdir\nnl\u{1f}\u{1f}bash\u{1f}s\u{1f}1\u{1f}1\u{1f}0\u{1f}$1\u{1f}@1\u{1e}\n"
      + "%2\u{1f}/dev/ttys015\u{1f}zsh\u{1f}/tmp\u{1f}t\u{1f}zsh\u{1f}s\u{1f}1\u{1f}0\u{1f}0\u{1f}$1\u{1f}@2\u{1e}\n"
    let panes = parseTmuxPanes("edge", out)
    XCTAssertEqual(panes.map(\.key), ["tmux:edge/1", "tmux:edge/2"])
    XCTAssertEqual(panes.map(\.cwd), ["/tmp/ptx/tab\tdir\nnl", "/tmp"])
  }

  func testListClientsClientTtyToThePaneItShowsAndTheTitleTmuxGivesItsTerminal() {
    XCTAssertEqual(
      parseTmuxClients("default", "/dev/ttys009\u{1f}%0\u{1f}\u{1e}\n/dev/ttys011\u{1f}%14\u{1f}~ (tmux 3)\u{1e}\n"),
      [
        "ttys009": TmuxClient(pane: "tmux:default/0", title: ""),
        "ttys011": TmuxClient(pane: "tmux:default/14", title: "~ (tmux 3)"),
      ])
  }

  func testSendKeysRunsTmuxsKeyNamesCharactersLiterallyShiftEnterAsMEnter() throws {
    let runs = try tmuxKeyRuns(["down", "enter", "1", ";", "esc", "shift+enter", "ctrl+c", "shift+tab"])
    XCTAssertEqual(runs.map(\.literal), [false, true, false])
    XCTAssertEqual(runs.map(\.keys), [["Down", "Enter"], ["1", ";"], ["Escape", "M-Enter", "C-c", "BTab"]])
    XCTAssertThrowsError(try tmuxKeyRuns(["hyper+x"])) { XCTAssertTrue($0 is TerminalException) }
  }

  // ------------------------------------------------------------ WezTerm, Ghostty lists

  func testWezTermListPaneKeyWithTheGUIPidItsWindowAndTabFolderFromTheFileURLProgramFromTheTty() {
    let list = parseWezTermList("1128", wezList, procs: Procs(parsePs(psWezTerm)))
    XCTAssertEqual(list.count, 1)
    let w = list[0]
    XCTAssertEqual(w.key, "wezterm:1128/0")
    XCTAssertEqual(w.title, "cap-wezterm")
    XCTAssertEqual(w.cwd, "/tmp/dzt/cap-wezterm")
    XCTAssertEqual(w.tty, "ttys008")
    XCTAssertEqual(w.program, "claude")
    XCTAssertTrue(w.focused)
    XCTAssertEqual(w.app, "wezterm")
    XCTAssertEqual(w.osWindow, "wezterm:1128/w0")
    XCTAssertEqual(w.tabId, "wezterm:1128/t0")
  }

  func testGhosttyListIdTitleFolderWindowAndTabNoTtyAndItsWindowsCantBeRead() {
    let out =
      "CB2035E7-67BF-48C7-8D0A-83F3FA5B8074\u{1f}cap-ghostty\u{1f}/tmp/dzt/cap-ghostty\u{1f}cap-ghostty\u{1f}true\u{1f}"
      + "W-1\u{1f}T-2\u{1e}\nfront\u{1f}false"
    let list = parseGhosttyList(out)
    XCTAssertEqual(list.count, 1)
    let w = list[0]
    XCTAssertEqual(w.key, "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074")
    XCTAssertEqual(w.title, "cap-ghostty")
    XCTAssertEqual(w.cwd, "/tmp/dzt/cap-ghostty")
    XCTAssertEqual(w.tty, "")
    XCTAssertFalse(w.focused)
    XCTAssertEqual(w.osWindow, "ghostty:wW-1")
    XCTAssertEqual(w.tabId, "ghostty:tT-2")
    XCTAssertFalse(w.can(.read))
    XCTAssertTrue(w.can(.keys))
  }

  func testGhosttyListATitleOrFolderWithATabOrLineBreakStaysOneWindow() {
    let out =
      "CB2035E7-67BF-48C7-8D0A-83F3FA5B8074\u{1f}a\tb\nc\u{1f}/tmp/x\ty\u{1f}tab\u{1f}true\u{1f}W-1\u{1f}T-1\u{1e}\r"
      + "DB2035E7-67BF-48C7-8D0A-83F3FA5B8074\u{1f}second\u{1f}/tmp\u{1f}tab\u{1f}false\u{1f}W-1\u{1f}T-1\u{1e}\n"
      + "front\u{1f}true\n"
    let ws = parseGhosttyList(out)
    XCTAssertEqual(ws.map(\.title), ["a b c", "second"])
    XCTAssertEqual(ws.map(\.cwd), ["/tmp/x\ty", "/tmp"])
    XCTAssertEqual(ws.map(\.focused), [true, false])
  }

  func testGhosttyTextEscapesWhatAZigStringLiteralCantHold() {
    XCTAssertEqual(ghosttyText(#"echo "a\b""#), #"echo \"a\\b\""#)
    XCTAssertEqual(ghosttyText("\u{1b}[A\r\u{7f}"), #"\x1b[A\x0d\x7f"#)
    XCTAssertEqual(ghosttyText("čšž ✓"), "čšž ✓")
  }

  // ------------------------------------------------------------ merge

  private func keysAndVia(_ ws: [TermWindow]) -> [String] { ws.map { "\($0.key)|\($0.via)" } }

  func testATerminalWindowAttachedToTmuxGivesWayToTheTmuxPaneInItsPlace() {
    let merged = Terminals.merge(
      terms().hosts,
      [
        [w("kitty-1/2", tty: "ttys003")],
        [w("tmux:default/0", tty: "ttys008"), w("tmux:default/1", tty: "ttys011")],
        [w("wezterm:9/1", tty: "ttys009"), w("wezterm:9/2", tty: "ttys010")],
        [],
      ], ["ttys009": "tmux:default/0"], [:])
    XCTAssertEqual(keysAndVia(merged), ["kitty-1/2|", "tmux:default/1|", "tmux:default/0|WezTerm", "wezterm:9/2|"])
  }

  func testAGhosttyWindowPocketTermOpenedToShowAPaneGivesWayThroughTheShowsMap() {
    let merged = Terminals.merge(
      terms().hosts, [[], [w("tmux:default/4", tty: "ttys012")], [], [w("ghostty:G1"), w("ghostty:G2")]], [:],
      ["ghostty:G1": "tmux:default/4"])
    XCTAssertEqual(keysAndVia(merged), ["tmux:default/4|Ghostty", "ghostty:G2|"])
  }

  func testEveryPaneOfAShownTmuxSessionSitsInTheAppsWindowAndTab() {
    let merged = Terminals.merge(
      terms().hosts,
      [
        [w("kitty-1/2", tty: "ttys003", osWindow: "kitty-1/os1", tabId: "kitty-1/tab4")],
        [
          w("tmux:default/0", osWindow: "tmux:default/s1", tabId: "tmux:default/w1"),
          w("tmux:default/1", osWindow: "tmux:default/s1", tabId: "tmux:default/w2"),
          w("tmux:default/2", osWindow: "tmux:default/s2", tabId: "tmux:default/w3"),
        ],
        [], [],
      ], ["ttys003": "tmux:default/1"], [:])
    XCTAssertEqual(
      merged.map { "\($0.key)|\($0.via)|\($0.osWindow)|\($0.tabId)" },
      [
        "tmux:default/0|kitty|kitty-1/os1|kitty-1/tab4",
        "tmux:default/1|kitty|kitty-1/os1|kitty-1/tab4",
        "tmux:default/2||tmux:default/s2|tmux:default/w3",
      ])
  }

  // ------------------------------------------------------------ projectWindow

  private func find(_ ws: [TermWindow], _ cwd: String) -> String? {
    Terminals.projectWindow(ws, terms().kitty!, cwd, home: "/Users/me")
  }

  func testTheAppsWindowWithTheMostOfTheProjectsTabsPanesOfOneTabCountOnce() {
    let ws = [
      w("kitty-1/1", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os1", tabId: "kitty-1/tab1"),
      w("kitty-1/2", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os1", tabId: "kitty-1/tab1"),
      w("kitty-1/3", app: "kitty", cwd: "/Users/me/b", osWindow: "kitty-1/os1", tabId: "kitty-1/tab2"),
      w("kitty-1/4", app: "kitty", cwd: "/Users/me/a/lib", osWindow: "kitty-1/os2", tabId: "kitty-1/tab3"),
      w("kitty-1/5", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os2", tabId: "kitty-1/tab5"),
      // Another app's window, and a tmux pane no app shows: not kitty's to open a tab in.
      w("wezterm:9/1", app: "wezterm", cwd: "/Users/me/a", osWindow: "wezterm:9/w1", tabId: "wezterm:9/t1"),
      w("tmux:default/0", app: "tmux", cwd: "/Users/me/a", osWindow: "tmux:default/s1"),
    ]
    XCTAssertEqual(find(ws, "/Users/me/a"), "kitty-1/os2")
    XCTAssertEqual(find(ws, "/Users/me/b"), "kitty-1/os1")
    XCTAssertNil(find(ws, "/Users/me/ab"), "a folder whose name starts the same is another project")
  }

  func testATmuxPaneCountsForTheAppWindowShowingIt() {
    let ws = [
      w("tmux:default/0", app: "tmux", cwd: "/Users/me/a", osWindow: "kitty-1/os3", tabId: "kitty-1/tab7", via: "kitty")
    ]
    XCTAssertEqual(find(ws, "/Users/me/a"), "kitty-1/os3")
  }

  func testTheHomeFolderCountsOnlyTabsInItNotEveryFolderUnderIt() {
    let ws = [
      w("kitty-1/1", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os1", tabId: "kitty-1/tab1"),
      w("kitty-1/2", app: "kitty", cwd: "/Users/me/b", osWindow: "kitty-1/os1", tabId: "kitty-1/tab2"),
      w("kitty-1/3", app: "kitty", cwd: "/Users/me", osWindow: "kitty-1/os2", tabId: "kitty-1/tab3"),
    ]
    XCTAssertEqual(find(ws, "/Users/me"), "kitty-1/os2")
    XCTAssertNil(find(Array(ws.prefix(2)), "/Users/me"))
  }

  func testAWindowThatTellsNoAppWindowIsNoPlaceForATab() {
    XCTAssertNil(find([w("kitty-1/1", app: "kitty", cwd: "/Users/me/a")], "/Users/me/a"))
  }

  func testTheHomeFolderIsGeneralAProjectIsItsFolder() {
    XCTAssertEqual(Terminals.projectName("/Users/me", home: "/Users/me"), "General")
    XCTAssertEqual(Terminals.projectName("/Users/me/wrkly", home: "/Users/me"), "wrkly")
  }

  // ------------------------------------------------------------ Ghostty windows running tmux

  // As a real Ghostty 1.3.1 with the line runs it: each terminal's login
  // (a child of Ghostty, or orphaned) execs tmux's client on its tty; the
  // server, detached, runs the panes' shells on ttys of their own.
  private let app = "\(nowhere)/Ghostty.app"
  private let client = "-/opt/homebrew/bin/tmux new-session ; set-option destroy-unattached on"
  private var login: String { "/usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l \(client)" }
  private let g1 = "E7AD8A26-8A2F-4A2E-B8AA-AB5575C50B75"
  private let g2 = "F1AD8A26-8A2F-4A2E-B8AA-AB5575C50B75"

  private func ps(_ clientTtys: [String], plainTtys: [String] = []) -> String {
    var lines = [
      "  500     1   500     0 ??       S    \(app)/Contents/MacOS/ghostty",
      "  600     1   600     0 ??       Ss   \(client)",
    ]
    for (i, tty) in clientTtys.enumerated() {
      let p = 700 + i * 10
      lines.append("  \(p)   500   \(p)   \(p) \(tty)  Ss+  \(login)")
      lines.append("  \(p + 1)   \(p)   \(p)   \(p) \(tty)  S+   \(client)")
    }
    for (i, tty) in plainTtys.enumerated() { lines.append("  \(900 + i)   888   \(900 + i)   \(900 + i) \(tty)  Ss+  -zsh") }
    lines.append("  610   600   610   610 ttys014  Ss+  -zsh")
    lines.append("  620   600   620   620 ttys015  Ss+  -zsh")
    return lines.joined(separator: "\n")
  }

  private func ghosttyList(_ ws: [(String, String, String)]) -> String {
    ws.map { id, title, cwd in "\(id)\u{1f}\(title)\u{1f}\(cwd)\u{1f}\(title)\u{1f}false\u{1f}W-\(id)\u{1f}T-\(id)\u{1e}\n" }
      .joined() + "front\u{1f}false"
  }

  private var panes: [TermWindow] {
    parseTmuxPanes(
      "default",
      "%0\u{1f}/dev/ttys014\u{1f}zsh\u{1f}/Users/me/a\u{1f}a\u{1f}zsh\u{1f}3\u{1f}1\u{1f}1\u{1f}1\u{1f}$3\u{1f}@0\u{1e}\n"
        + "%1\u{1f}/dev/ttys015\u{1f}zsh\u{1f}/Users/me/b\u{1f}b\u{1f}zsh\u{1f}4\u{1f}1\u{1f}1\u{1f}1\u{1f}$4\u{1f}@1\u{1e}\n")
  }

  private func tie(_ ps: String, _ list: String, _ clients: String) -> TieGhostty {
    Terminals.tieGhostty(
      windows: parseGhosttyList(list), clients: parseTmuxClients("default", clients),
      surfaces: ghosttySurfaceTtys(Procs(parsePs(ps)), 500), panes: panes)
  }

  func testOneWindowAndOneClientItShowsThatPaneAndItsTtyIsLearnt() async {
    let ghostty = ListedGhostty(parseGhosttyList(ghosttyList([(g1, "👻", "")])))
    let procs = Procs(parsePs(ps(["ttys013"])))
    let terms = Terminals(
      home: nowhere,
      tmux: ListedTmux(Array(panes.prefix(1)), parseTmuxClients("default", "/dev/ttys013\u{1f}%0\u{1f}\u{1e}\n")),
      ghostty: ghostty, snapshot: { procs })
    let windows = await terms.windows()
    XCTAssertEqual(windows.map { "\($0.key)|\($0.app)|\($0.via)" }, ["tmux:default/0|tmux|Ghostty"])
    XCTAssertEqual(ghostty.byTty("ttys013"), "ghostty:\(g1)", "what closes it with its pane")
  }

  func testTwoWindowsAndTwoClientsByTheTitleTmuxGivesEachElseByFolder() {
    let clients = "/dev/ttys013\u{1f}%0\u{1f}a (tmux 3)\u{1e}\n/dev/ttys016\u{1f}%1\u{1f}b (tmux 4)\u{1e}\n"
    let titled = tie(ps(["ttys013", "ttys016"]), ghosttyList([(g1, "b (tmux 4)", ""), (g2, "a (tmux 3)", "")]), clients)
    XCTAssertEqual(titled, TieGhostty(ttys: ["ghostty:\(g1)": "ttys016", "ghostty:\(g2)": "ttys013"], untold: ""))
    // The line without titles, where Ghostty tells each window's folder.
    let byFolder = tie(
      ps(["ttys013", "ttys016"]), ghosttyList([(g1, "👻", "/Users/me/b"), (g2, "👻", "/Users/me/a")]),
      "/dev/ttys013\u{1f}%0\u{1f}\u{1e}\n/dev/ttys016\u{1f}%1\u{1f}\u{1e}\n")
    XCTAssertEqual(byFolder, TieGhostty(ttys: ["ghostty:\(g1)": "ttys016", "ghostty:\(g2)": "ttys013"], untold: ""))
  }

  func testWhatCanBeToldTwoWaysStaysTwoRows() {
    let untitled = "/dev/ttys013\u{1f}%0\u{1f}\u{1e}\n/dev/ttys016\u{1f}%1\u{1f}\u{1e}\n"
    let same = tie(ps(["ttys013", "ttys016"]), ghosttyList([(g1, "👻", ""), (g2, "👻", "")]), untitled)
    XCTAssertEqual(same.ttys, [:])
    XCTAssertEqual(same.untold, "ghostty:\(g1), ghostty:\(g2) / ttys013, ttys016")
    // Both in one folder, or both titled alike.
    XCTAssertEqual(
      tie(
        ps(["ttys013", "ttys016"]), ghosttyList([(g1, "👻", "/Users/me/a"), (g2, "👻", "/Users/me/a")]),
        "/dev/ttys013\u{1f}%0\u{1f}\u{1e}\n/dev/ttys016\u{1f}%0\u{1f}\u{1e}\n"
      ).ttys, [:])
    // A plain window in the pane's folder beside the tmux one Ghostty tells
    // no folder for: the folder could be the plain one's, so neither.
    let plain = tie(
      ps(["ttys013"], plainTtys: ["ttys020"]), ghosttyList([(g1, "zsh", "/Users/me/a"), (g2, "👻", "")]),
      "/dev/ttys013\u{1f}%0\u{1f}\u{1e}\n")
    XCTAssertEqual(plain.ttys, [:])
    XCTAssertFalse(plain.untold.isEmpty)
  }

  func testAGhosttyWindowRunningNoTmuxIsLeftAloneAndWindowsWhoseTtyIsKnownCountOut() {
    // Its client runs in kitty, not in Ghostty.
    let alone = tie(ps([], plainTtys: ["ttys020"]), ghosttyList([(g1, "zsh", "/Users/me/a")]), "/dev/ttys030\u{1f}%0\u{1f}\u{1e}\n")
    XCTAssertEqual(alone, TieGhostty(ttys: [:], untold: ""))
    // PocketTerm's own window (tty known) beside one the person opened.
    let known = Terminals.tieGhostty(
      windows: parseGhosttyList(ghosttyList([(g1, "👻", "")]))
        + [TermWindow(key: "ghostty:\(g2)", title: "👻", tab: "", cwd: "", program: "", app: "ghostty", tty: "ttys016")],
      clients: parseTmuxClients("default", "/dev/ttys013\u{1f}%0\u{1f}\u{1e}\n/dev/ttys016\u{1f}%1\u{1f}\u{1e}\n"),
      surfaces: ghosttySurfaceTtys(Procs(parsePs(ps(["ttys013", "ttys016"]))), 500), panes: panes)
    XCTAssertEqual(known, TieGhostty(ttys: ["ghostty:\(g1)": "ttys013"], untold: ""))
  }

  // ------------------------------------------------------------ pickApp

  private let statuses: [String: TermStatus] = [
    "kitty": TermStatus("kitty", "kitty", .setup),
    "wezterm": TermStatus("wezterm", "wezterm", .limited),
    "ghostty": TermStatus("ghostty", "ghostty", .idle),
  ]

  func testAChosenAppThatIsInstalledWinsEvenWhenNotRunning() {
    XCTAssertEqual(Terminals.pickApp(terms().apps, statuses, "ghostty", ["WezTerm"]).id, "ghostty")
  }

  func testAutoTheUsableAppUsedMostRecentlySkippingOnesThatNeedSetup() {
    XCTAssertEqual(Terminals.pickApp(terms().apps, statuses, "auto", ["Zen", "kitty", "Ghostty", "WezTerm"]).id, "wezterm")
    // A missing choice falls back the same way.
    var noGhostty = statuses
    noGhostty["ghostty"] = TermStatus("ghostty", "ghostty", .missing)
    XCTAssertEqual(Terminals.pickApp(terms().apps, noGhostty, "ghostty", ["WezTerm"]).id, "wezterm")
  }

  func testAutoWithNoneUsedLatelyTheFirstUsableElseOneThatCanBeStarted() {
    XCTAssertEqual(Terminals.pickApp(terms().apps, statuses, "auto", []).id, "wezterm")
    let none: [String: TermStatus] = [
      "kitty": TermStatus("kitty", "kitty", .idle),
      "wezterm": TermStatus("wezterm", "wezterm", .missing),
      "ghostty": TermStatus("ghostty", "ghostty", .idle),
    ]
    // kitty can't be started listening: Ghostty, the next idle app.
    XCTAssertEqual(Terminals.pickApp(terms().apps, none, "auto", []).id, "ghostty")
  }

  func testNewSessionsRunInTmuxOnlyWhereTheAppLacksScreenOrKeysAndOnlyWithTmux() {
    let t = terms()
    XCTAssertFalse(t.viaTmux(t.ghostty!))  // no tmux here
    let withTmux = Terminals(
      home: t.home, kitty: t.kitty, tmux: Tmux(executable: "/bin/sh", socketDirs: []), wezterm: t.wezterm,
      ghostty: t.ghostty)
    XCTAssertTrue(withTmux.viaTmux(withTmux.ghostty!))
    XCTAssertFalse(withTmux.viaTmux(withTmux.wezterm!))
    XCTAssertEqual(withTmux.describe(withTmux.ghostty!), "Ghostty (in tmux)")
    XCTAssertEqual(withTmux.describe(withTmux.kitty!), "kitty")
  }

  func testTmuxInstalledWhileTheAppRunsIsFoundWithoutARestart() throws {
    let installedBefore = fileExists("/opt/homebrew/bin/tmux") || fileExists("/usr/local/bin/tmux")
    try XCTSkipIf(installedBefore, "tmux is installed on this machine")
    let bin = FileManager.default.temporaryDirectoryForTests("pocketterm-tmux")
    defer { try? FileManager.default.removeItem(atPath: bin) }
    let tmux = Tmux(socketDirs: [], env: ["PATH": bin])
    XCTAssertFalse(tmux.installed)
    FileManager.default.createFile(atPath: "\(bin)/tmux", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    XCTAssertTrue(tmux.installed)
  }

  func testWithTmuxGhosttyIsReadyForPhoneSessionsAndStillNamesItsOwnLimit() async {
    func with(_ tmux: Tmux) -> Terminals {
      Terminals(home: nowhere, tmux: tmux, ghostty: RunningGhostty(), snapshot: { Procs(parsePs("")) })
    }
    let without = await with(Tmux(executable: "\(nowhere)/tmux", socketDirs: [])).statuses().first { $0.id == "ghostty" }!
    XCTAssertEqual(without.state, .limited)
    let withTmux = await with(Tmux(executable: "/bin/sh", socketDirs: [])).statuses().first { $0.id == "ghostty" }!
    XCTAssertEqual(withTmux.state, .ready)
    XCTAssertTrue(withTmux.note.contains(RunningGhostty().limits), withTmux.note)
  }

  func testAnOmpWindowCarriesTheProfileItsCommandLineNames() async {
    func pane(_ id: String, _ tty: String, _ program: String) -> TermWindow {
      TermWindow(key: "tmux:default/\(id)", title: "", tab: "", cwd: "", program: program, app: "tmux", tty: tty)
    }
    let procs = Procs(
      parsePs(
        "  500   400   500   500 ttys004  S+   omp --profile=personal\n"
          + "  600     1   600   600 ttys005  Ss+  -zsh --profile=personal\n"
          + "  700   400   700   700 ttys006  S+   /opt/homebrew/bin/omp -c\n"))
    let terms = Terminals(
      home: nowhere,
      tmux: ListedTmux([pane("1", "ttys004", "omp"), pane("2", "ttys005", "zsh"), pane("3", "ttys006", "omp")], [:]),
      snapshot: { procs })
    let windows = await terms.windows()
    XCTAssertEqual(windows.map { "\($0.key)|\($0.profile)" }, ["tmux:default/1|personal", "tmux:default/2|", "tmux:default/3|"])
  }

  // ------------------------------------------------------------ locate: Ghostty windows sharing a folder

  private func g(_ id: String, _ title: String, cwd: String = "/tmp/work") -> TermWindow {
    TermWindow(key: "ghostty:\(id)", title: title, tab: "", cwd: cwd, program: "", app: "ghostty")
  }

  private func with(_ listed: [TermWindow]) -> Terminals {
    Terminals(home: nowhere, ghostty: ListedGhostty(listed), snapshot: { Procs(parsePs("")) })
  }

  private func term(_ tty: String) -> JSONObject { ["TERM_PROGRAM": "ghostty", "tty": .string("/dev/\(tty)")] }

  func testEachOmpSessionGetsTheWindowWhoseTitleIsItsOwnOrItsFoldersWhileUntitled() async {
    let terms = with([
      g("A", "π > Fix missing playable sources for the player"), g("B", "π > work"), g("C", "zsh", cwd: "/tmp/other"),
    ])
    let a = await terms.locate(term("ttys001"), cwd: "/tmp/work", title: "Fix missing playable sources for the player")
    XCTAssertEqual(a, "ghostty:A")
    let b = await terms.locate(term("ttys002"), cwd: "/tmp/work")
    XCTAssertEqual(b, "ghostty:B")
    // Matched once, found by its tty from then on, whatever the title says.
    let again = await terms.locate(term("ttys001"), cwd: "/tmp/work", title: "Renamed")
    XCTAssertEqual(again, "ghostty:A")
  }

  func testOmpsTitleWhileItWorksOrAsksStillNamesTheSession() async {
    let terms = with([g("A", "π ⠋ Paint the button"), g("B", "π ! Fix the build"), g("C", "π: work")])
    let b = await terms.locate(term("ttys001"), cwd: "/tmp/work", title: "Fix the build")
    XCTAssertEqual(b, "ghostty:B")
    let a = await terms.locate(term("ttys002"), cwd: "/tmp/work", title: "Paint the button")
    XCTAssertEqual(a, "ghostty:A")
    let c = await terms.locate(term("ttys003"), cwd: "/tmp/work")
    XCTAssertEqual(c, "ghostty:C")
  }

  func testTheOneWindowThereNoOtherSessionRunsInIsTheOne() async {
    let terms = with([g("A", "π > work"), g("B", "π > work")])
    let b = await terms.locate(term("ttys002"), cwd: "/tmp/work", claimed: ["ghostty:A"])
    XCTAssertEqual(b, "ghostty:B")
    // Claude Code's title names no session: only what's left tells.
    let claude = with([g("A", "✳ Claude Code"), g("B", "✳ Claude Code")])
    let a = await claude.locate(term("ttys002"), cwd: "/tmp/work", agent: .claude, claimed: ["ghostty:B"])
    XCTAssertEqual(a, "ghostty:A")
  }

  func testStillMoreThanOneNoneRatherThanAGuess() async {
    let untitled = with([g("A", "π > work"), g("B", "π > work")])
    let u = await untitled.locate(term("ttys001"), cwd: "/tmp/work")
    XCTAssertNil(u)
    let titled = with([g("A", "π > Fix the build"), g("B", "π > work"), g("C", "π > Paint the button")])
    let t = await titled.locate(term("ttys001"), cwd: "/tmp/work", title: "Write docs")
    XCTAssertNil(t)
    let claude = with([g("A", "✳ Claude Code"), g("B", "✳ Claude Code")])
    let c = await claude.locate(term("ttys001"), cwd: "/tmp/work", agent: .claude)
    XCTAssertNil(c)
    // Nothing learned from a miss.
    XCTAssertNil(untitled.ghostty!.byTty("ttys001"))
  }

  // ------------------------------------------------------------ projects

  private func withRoot(_ body: (String) async throws -> Void) async rethrows {
    let dir = FileManager.default.temporaryDirectoryForTests("pocketterm-projects")
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try await body(realPathOf(dir))
  }

  private func mk(_ root: String, _ path: String) {
    try! FileManager.default.createDirectory(atPath: "\(root)/\(path)", withIntermediateDirectories: true)
  }

  private func link(_ path: String, _ target: String) {
    try! FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
  }

  func testGitRepositoriesUpToThreeLevelsUnderTheGivenFoldersNotInsideOneAnother() async {
    await withRoot { root in
      for p in ["a/.git", "a/sub/.git", "org/b/.git", "plain/x", ".hidden/c/.git", "1/2/3/.git", "4/5/6/7/.git"] {
        mk(root, p)
      }
      let want = ["\(root)/1/2/3", "\(root)/a", "\(root)/org/b"]
      let found = await terms().projects([root, "\(root)/nonexistent"])
      XCTAssertEqual(found, want)
      // Nested folders list a repository once.
      let nested = await terms().projects([root, "\(root)/org"])
      XCTAssertEqual(nested, want)
      let none = await terms().projects([])
      XCTAssertEqual(none, [])
    }
  }

  func testSymlinkedFoldersAreFollowedUnderTheirOwnPathALoopOrOneFolderByTwoPathsListsOnce() async {
    await withRoot { root in
      mk(root, "real/repo/.git")
      mk(root, "elsewhere/linked/.git")
      mk(root, "deep/x/y/z/.git")
      link("\(root)/projects", "\(root)/elsewhere")
      link("\(root)/real/loop", root)
      link("\(root)/real/again", "\(root)/real/repo")
      let found = await terms().projects([root])
      XCTAssertEqual(found, ["\(root)/projects/linked", "\(root)/real/repo"])
      let deep = await terms().projects(["\(root)/", "\(root)/deep"])
      XCTAssertEqual(
        deep, ["\(root)/deep/x/y/z", "\(root)/projects/linked", "\(root)/real/repo"],
        "a root inside another is walked to its own depth; a trailing slash changes nothing")
    }
  }

  func testCreateProjectMakesTheFolderUnderOneOfTheProjectFoldersOnce() async throws {
    try await withRoot { root in
      let t = terms()
      XCTAssertEqual(try t.createProject(root, " new ", roots: [root]), "\(root)/new")
      XCTAssertTrue(directoryExists("\(root)/new"))
      XCTAssertThrowsError(try t.createProject(root, "new", roots: [root])) {
        XCTAssertTrue(($0 as? TerminalException)?.message.contains("already") ?? false)
      }
      XCTAssertThrowsError(try t.createProject(root, "other", roots: [])) { XCTAssertTrue($0 is TerminalException) }
      for name in ["", "  ", "a/b", #"a\b"#, "C:x", ".x", "..", "a\u{0}b", "a\nb"] {
        XCTAssertThrowsError(try t.createProject(root, name, roots: [root]), name) { XCTAssertTrue($0 is TerminalException) }
      }
      // A Project folder deleted since it was added.
      XCTAssertThrowsError(try t.createProject("\(root)/gone", "x", roots: ["\(root)/gone"])) {
        XCTAssertTrue(($0 as? TerminalException)?.message.hasPrefix("No such folder") ?? false)
      }
    }
  }

  func testLaunchNewProjectTakesTheFolderBackWhenNoWindowOpensSoTryingAgainWorks() async {
    await withRoot { root in
      let t = terms()
      // kitty isn't listening here: the launch fails.
      for _ in 0..<2 {
        do {
          _ = try await t.launchNewProject(root, "demo", roots: [root], host: t.kitty!)
          XCTFail("no error")
        } catch let e as TerminalException {
          // The same failure again, not "already something named demo there".
          XCTAssertFalse(e.message.contains("already"), e.message)
        } catch {
          XCTFail("\(error)")
        }
        XCTAssertFalse(directoryExists("\(root)/demo"))
      }
    }
  }
}
#endif
