import Foundation
import PocketTermKit
import XCTest

/// The platform-neutral half of terminal.dart: vectors.json's `terminal`
/// section and the model round trips of `live.models`, then terminal_test.dart.
final class TerminalModelTests: XCTestCase {
  // ------------------------------------------------------------ vectors

  func testVectorWindowOfTerm() {
    let cases = TermVectors.cases("terminal", "windowOfTerm")
    XCTAssertFalse(cases.isEmpty)
    for c in cases {
      XCTAssertEqual(windowOfTerm(c["term"]?.object), c["window"]?.string, TermVectors.note(c))
    }
  }

  func testVectorTmuxSocketName() {
    for c in TermVectors.cases("terminal", "tmuxSocketName") {
      XCTAssertEqual(tmuxSocketName(c["name"]!.string!), c["ok"]!.bool!, c["name"]!.string!)
    }
  }

  func testVectorKeyBytes() {
    for c in TermVectors.cases("terminal", "keyBytes") {
      let name = c["name"]!.string!
      if let error = c["error"]?.string {
        XCTAssertThrowsError(try keyBytes(name), name) { XCTAssertEqual(($0 as? TerminalException)?.message, error) }
      } else {
        let bytes = try? keyBytes(name)
        XCTAssertEqual(bytes, c["bytes"]?.string, name)
        XCTAssertEqual(bytes.map { Data($0.utf8).map { String(format: "%02x", $0) }.joined() }, c["hex"]?.string, name)
      }
    }
  }

  func testVectorKeyRunsAndPhoneKeys() throws {
    for c in TermVectors.cases("terminal", "keyRuns") {
      XCTAssertEqual(try keyRuns(c["names"]!.strings!), c["runs"]!.strings!, TermVectors.note(c))
    }
    XCTAssertEqual(phoneKeys, Set(TermVectors.at("terminal", "phoneKeys").strings!))
  }

  func testVectorTextChunks() {
    for c in TermVectors.cases("terminal", "textChunks") {
      let chunks = textChunks(c["text"]!.string!, c["maxBytes"]!.int!)
      // By code units: Swift's == would take é and e + U+0301 for one.
      XCTAssertEqual(chunks.map { Array($0.utf16) }, c["chunks"]!.strings!.map { Array($0.utf16) }, TermVectors.note(c))
    }
  }

  func testVectorCleanTitle() {
    let v = TermVectors.at("terminal", "cleanTitle")
    XCTAssertEqual(titleRunes, v["titleRunes"]?.int)
    for c in v["cases"]!.array! {
      XCTAssertEqual(Array(cleanTitle(c["input"]!.string!).utf16), Array(c["title"]!.string!.utf16), TermVectors.note(c))
    }
  }

  func testVectorScreenLines() {
    let v = TermVectors.at("terminal", "screenLines")
    XCTAssertEqual(historyBytes, v["historyBytes"]?.int)
    for c in v["cases"]!.array! {
      XCTAssertEqual(
        screenLines(c["input"]!.string!).map { Array($0.utf16) }, c["lines"]!.strings!.map { Array($0.utf16) },
        TermVectors.note(c))
    }
    for c in v["long"]!.array! {
      let lines = screenLines(TermVectors.text(c["input"])!)
      let want = c["lines"]!.array!
      XCTAssertEqual(lines.count, want.count, TermVectors.note(c))
      for (line, w) in zip(lines, want) {
        if let s = w.string {
          XCTAssertEqual(Array(line.utf16), Array(s.utf16), TermVectors.note(c))
        } else {
          XCTAssertTrue(TermVectors.matches(line, summary: w), TermVectors.note(c))
        }
      }
    }
  }

  func testVectorProcesses() {
    let v = TermVectors.at("terminal", "processes")
    let input = v["parsePs"]!["input"]!.string!
    let procs = parsePs(input)
    let want = v["parsePs"]!["procs"]!.array!
    XCTAssertEqual(procs.count, want.count)
    for (p, w) in zip(procs, want) {
      XCTAssertEqual(p.pid, w["pid"]?.int)
      XCTAssertEqual(p.ppid, w["ppid"]?.int)
      XCTAssertEqual(p.pgid, w["pgid"]?.int)
      XCTAssertEqual(p.tpgid, w["tpgid"]?.int)
      XCTAssertEqual(p.tty, w["tty"]?.string)
      XCTAssertEqual(p.stat, w["stat"]?.string)
      XCTAssertEqual(p.args, w["args"]?.string)
      XCTAssertEqual(p.program, w["program"]?.string)
    }
    for c in v["foreground"]!.array! {
      XCTAssertEqual(Procs(procs).foreground(c["tty"]!.string!)?.pid, c["pid"]?.int, c["tty"]!.string!)
    }
    for c in v["parseLsofCwd"]!.array! {
      let want = Dictionary(uniqueKeysWithValues: c["cwds"]!.object!.map { (Int($0.key)!, $0.value.string!) })
      XCTAssertEqual(parseLsofCwd(c["input"]!.string!), want, TermVectors.note(c))
    }
    for c in v["programOf"]!.array! {
      XCTAssertEqual(programOf(c["args"]!.string!), c["program"]!.string!, c["args"]!.string!)
    }
    for c in v["programOfTitle"]!.array! {
      XCTAssertEqual(programOfTitle(c["title"]!.string!), c["program"]!.string!, c["title"]!.string!)
    }
    for c in v["utf8Locale"]!.array! {
      let env = c["env"]!.object!.mapValues { $0.string! }
      XCTAssertEqual(utf8Locale(env), c["add"]!.object!.mapValues { $0.string! }, "\(env)")
    }
  }

  func testVectorShellQuote() {
    for c in TermVectors.cases("terminal", "shellQuote") {
      XCTAssertEqual(shellQuote(c["input"]!.string!), c["quoted"]!.string!)
    }
  }

  func testVectorCaps() {
    let v = TermVectors.at("terminal", "caps")
    XCTAssertEqual(TermCap.allCases.map(\.name), v["all"]!.strings!)
    XCTAssertEqual(TermCap.allCases.filter(allCaps.contains).map(\.name), v["allCaps"]!.strings!)
    XCTAssertEqual(TermState.allCases.map(\.name), v["termStates"]!.strings!)
    for p in v["placement"]!.array! {
      XCTAssertEqual(Placement(rawValue: p["name"]!.string!)?.describe, p["describe"]!.string!)
    }
    XCTAssertEqual(Placement.allCases.map(\.name), v["placement"]!.array!.map { $0["name"]!.string! })
  }

  func testVectorModels() {
    let models = TermVectors.at("live", "models")
    let windows = models["TermWindow"]!.array!
    XCTAssertFalse(windows.isEmpty)
    for c in windows {
      let w = TermWindow.fromJson(c["input"]!.object!)
      XCTAssertEqual(w.map { JSON.object($0.toJson()) }, c["output"], TermVectors.note(c))
      if let agent = c["agent"] { XCTAssertEqual(w?.agent?.name, agent.string, TermVectors.note(c)) }
    }
    for c in models["TermStatus"]!.array! {
      XCTAssertEqual(JSON.object(TermStatus(json: c["input"]!.object!).toJson()), c["output"], TermVectors.note(c))
    }
    for c in models["AgentIntegration"]!.array! {
      let input = c["input"]!
      // "null" stands for a value that isn't a map.
      let parsed = AgentIntegration.parseAll(input.string == "null" ? .null : input)
      XCTAssertEqual(JSON.object(AgentIntegration.toJsonAll(parsed)), c["output"], TermVectors.note(c))
    }
  }

  // ------------------------------------------------------------ terminal_test.dart

  /// `ps -Ao pid=,ppid=,pgid=,tpgid=,tty=,stat=,args=`: a terminal tab (login,
  /// then zsh in front), a Ghostty window attached to tmux (login, tmux client
  /// in front), omp running in a tab, and a daemon without a tty.
  private let ps = """
    98233 94784 98233 98234 ttys009  Ss   login -pf me
    98234 98233 98234 98234 ttys009  S+   -zsh
    97914 97159 97914 97914 ttys010  Ss+  /usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l '/opt/homebrew/bin/tmux' 'attach-session' '-t' '=pt-mv82o7z3'
    97915 97914 97914 97914 ttys010  S+   -/opt/homebrew/bin/tmux attach-session -t =pt-mv82o7z3
     5150  5149  5150  5249 ttys008  Ss   -zsh
     5249  5150  5249  5249 ttys008  Rl+  omp --no-extensions -e /Users/me/live.ts
     7885 95874  7885     -1 ?        Rsl  /opt/homebrew/Cellar/omp/18.4.2/bin/omp __omp_worker_daemon_broker

    """

  func testParsePsReadsEveryLineAMissingTtyAsEmpty() {
    let procs = parsePs(ps)
    XCTAssertEqual(procs.map(\.pid), [98233, 98234, 97914, 97915, 5150, 5249, 7885])
    let daemon = procs.last!
    XCTAssertEqual(daemon.ppid, 95874)
    XCTAssertEqual(daemon.pgid, 7885)
    XCTAssertEqual(daemon.tpgid, -1)
    XCTAssertEqual(daemon.tty, "")
    XCTAssertEqual(daemon.stat, "Rsl")
    XCTAssertEqual(procs[5].args, "omp --no-extensions -e /Users/me/live.ts")
  }

  func testTheForegroundProgramOfATtyIsTheLeaderOfItsForegroundGroup() {
    let procs = Procs(parsePs(ps))
    XCTAssertEqual(procs.foreground("ttys009")?.program, "zsh")
    XCTAssertEqual(procs.foreground("/dev/ttys008")?.program, "omp")
    XCTAssertEqual(procs.foreground("ttys008")?.pid, 5249)
    XCTAssertNil(procs.foreground("ttys099"))
    XCTAssertNil(procs.foreground(""))
  }

  func testProgramOfNamesTheProgram() {
    XCTAssertEqual(programOf("-zsh"), "zsh")
    XCTAssertEqual(programOf("/opt/homebrew/Cellar/omp/18.4.2/bin/omp __omp_worker_daemon_broker"), "omp")
    XCTAssertEqual(programOf("-/opt/homebrew/bin/tmux attach-session -t =x"), "tmux")
    XCTAssertEqual(programOf("node --no-warnings /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"), "cli")
    XCTAssertEqual(programOf("bun /Users/me/bin/omp.ts --continue"), "omp")
    XCTAssertEqual(programOf("python3 -u server.py"), "server")
    XCTAssertEqual(programOf("claude"), "claude")
    XCTAssertEqual(programOf("   "), "")
  }

  func testParseLsofCwdMapsEachPidToItsFolder() {
    let out = "p98234\nfcwd\nn/private/tmp/dzt/cap-terminal\np1129\nfcwd\nn/Users/me/Dev/x y\n"
    XCTAssertEqual(parseLsofCwd(out), [98234: "/private/tmp/dzt/cap-terminal", 1129: "/Users/me/Dev/x y"])
    XCTAssertEqual(parseLsofCwd(""), [:])
  }

  func testUtf8LocaleAddsAUtf8CtypeOnlyWhenTheFirstLocaleSetIsNone() {
    let add = ["LC_CTYPE": "UTF-8"]
    XCTAssertEqual(utf8Locale([:]), add)
    XCTAssertEqual(utf8Locale(["LANG": ""]), add)
    XCTAssertEqual(utf8Locale(["LANG": "C"]), add)
    XCTAssertEqual(utf8Locale(["LANG": "hr_HR.UTF-8"]), [:])
    XCTAssertEqual(utf8Locale(["LANG": "C", "LC_CTYPE": "de_DE.utf8"]), [:])
  }

  func testKeyBytesSendsWhatATerminalSends() throws {
    XCTAssertEqual(try keyBytes("enter"), "\r")
    XCTAssertEqual(try keyBytes("esc"), "\u{1b}")
    XCTAssertEqual(try keyBytes("shift+enter"), "\u{1b}\r")
    XCTAssertEqual(try keyBytes("ctrl+c"), "\u{03}")
    XCTAssertEqual(try keyBytes("ctrl+a"), "\u{01}")
    XCTAssertEqual(try keyBytes("3"), "3")
    XCTAssertThrowsError(try keyBytes("ctrl+shift+x")) { XCTAssertTrue($0 is TerminalException) }
  }

  func testTextChunksCutsBetweenCharactersWithinTheLimitKeepingEveryByteInOrder() {
    let text = "ab漢👍🏽e\u{0301}" + String(repeating: "x", count: 20)
    let chunks = textChunks(text, 5)
    XCTAssertEqual(Array(chunks.joined().utf16), Array(text.utf16))
    for c in chunks {
      XCTAssertFalse(c.isEmpty)
      XCTAssertLessThanOrEqual(c.utf8.count, 5, c)
    }
    // A surrogate pair (an emoji) is never split.
    XCTAssertTrue(chunks.contains { Array($0.utf16) == Array("👍".utf16) })
    XCTAssertEqual(textChunks("", 5), [])
    XCTAssertEqual(textChunks("short", 100), ["short"])
  }

  func testANewestLineLongerThanTheHistoryBudgetComesAsItsEnd() {
    // kitty's history joins a wrapped line's rows: `cat` of a minified file.
    let long = "\u{1b}[38:2:1:2:3m" + String(repeating: "é", count: historyBytes)
    let lines = screenLines("older\n\(long)\n\n")
    XCTAssertEqual(lines.count, 1)
    XCTAssertLessThan(lines[0].utf8.count, historyBytes)
    XCTAssertTrue(lines[0].hasSuffix(String(repeating: "é", count: 100)))
    // A cut inside an escape starts after it, so none of its bytes show.
    let colored = String(repeating: "\u{1b}[31mx", count: historyBytes / 4)
    let line = screenLines(colored)[0]
    XCTAssertNotNil(line.range(of: "^(\u{1b}\\[31m)?x(\u{1b}\\[31mx)*$", options: .regularExpression), line.prefix(20).debugDescription)
  }

  func testTitlesDropControlsEscapesAndBidiOverrides() {
    XCTAssertEqual(cleanTitle("x\ty\nz\u{1b}[31m red\u{07}\u{01}"), "x y z red")
    XCTAssertEqual(cleanTitle("\u{1b}]0;inner\u{07}omp \u{202e}evil"), "omp evil")
    XCTAssertEqual(cleanTitle("漢字 👍🏽 é שלום zero\u{200b}width"), "漢字 👍🏽 é שלום zero\u{200b}width")
  }

  func testAVeryLongTitleIsCutToTitleRunesNeverInsideAnEmoji() {
    let t = cleanTitle(String(repeating: "👍", count: 1000))
    XCTAssertEqual(t.unicodeScalars.count, titleRunes)
    XCTAssertTrue(t.hasSuffix("\u{2026}"))
  }

  func testWindowOfTermTmuxWinsOverTheTerminalShowingIt() {
    XCTAssertEqual(
      windowOfTerm([
        "TERM_PROGRAM": "tmux", "TMUX": "/private/tmp/tmux-501/default,123,0", "TMUX_PANE": "%14",
        "KITTY_WINDOW_ID": "3", "KITTY_PID": "501",
      ]), "tmux:default/14")
    XCTAssertNil(windowOfTerm(nil))
    XCTAssertNil(windowOfTerm([:]))
    XCTAssertNil(windowOfTerm(["TERM_PROGRAM": "vscode", "tty": "/dev/ttys003"]))
  }

  func testAnOlderMacsWindowIsKittysAbleToDoEverything() {
    let w = TermWindow.fromJson(["key": "kitty-1/2", "title": "t", "program": "claude"])!
    XCTAssertEqual(w.app, "kitty")
    XCTAssertEqual(w.caps, allCaps)
    XCTAssertEqual(w.agent, .claude)
  }

  func testCapsAndViaSurviveTheTripToThePhoneUnknownCapsAreDropped() {
    let w = TermWindow(
      key: "tmux:default/0", title: "x", tab: "s:w", cwd: "/x", program: "zsh", app: "tmux", caps: [.type, .keys],
      via: "Ghostty")
    var json = w.toJson()
    json["caps"] = .array(json["caps"]!.array! + ["teleport"])
    let back = TermWindow.fromJson(json)!
    XCTAssertEqual(back.app, "tmux")
    XCTAssertEqual(back.via, "Ghostty")
    XCTAssertEqual(back.caps, [.type, .keys])
  }
}
