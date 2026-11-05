#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import XCTest

@testable import PocketTermDesktop

final class IntegrationsTests: XCTestCase {
  private var home = ""
  private let fm = FileManager.default

  override func setUp() {
    home = systemScratchDir(self, "pocketterm-integrations")
  }

  private func integrations(
    run: Integrations.Run? = nil, claudePaths: [String]? = nil, ompPaths: [String]? = nil,
    claudeTimeout: Duration = .seconds(60)
  ) -> Integrations {
    Integrations(
      home: home, bundled: systemRepoIntegrations, run: run, claudePaths: claudePaths, ompPaths: ompPaths,
      claudeTimeout: claudeTimeout)
  }

  private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

  private static let none = IntegrationState(installed: false, current: false, problem: nil)
  private static let current = IntegrationState(installed: true, current: true, problem: nil)
  private static let outdated = IntegrationState(installed: true, current: false, problem: nil)

  // ---------------------------------------------------------------- omp

  func testOmpInstallsTheExtensionAndTellsAnOutdatedCopyFromACurrentOne() async throws {
    let integrations = integrations(run: SystemFakeClaude("/nope").run)
    var state = try await integrations.state(.omp)
    XCTAssertEqual(state, Self.none)

    try await integrations.install(.omp)
    let dir = "\(home)/.omp/agent/extensions"
    XCTAssertEqual(systemFilesIn(dir), systemFilesIn("\(systemRepoIntegrations)/omp"))
    XCTAssertEqual(Array(systemFilesIn(dir).keys), ["pocketterm-live.ts"])
    state = try await integrations.state(.omp)
    XCTAssertEqual(state, Self.current)

    systemWrite("\(dir)/pocketterm-live.ts", "// older")
    state = try await integrations.state(.omp)
    XCTAssertEqual(state, Self.outdated)

    try fm.removeItem(atPath: "\(dir)/pocketterm-live.ts")
    state = try await integrations.state(.omp)
    XCTAssertFalse(state.installed)
  }

  func testOmpReplacesASymlinkedExtensionInsteadOfWritingThroughIt() async throws {
    let dir = "\(home)/.omp/agent/extensions"
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let source = "\(home)/checkout-live.ts"
    systemWrite(source, "// my checkout")
    try fm.createSymbolicLink(atPath: "\(dir)/pocketterm-live.ts", withDestinationPath: source)

    try await integrations(run: SystemFakeClaude("/nope").run).install(.omp)
    XCTAssertEqual(read(source), "// my checkout")
    XCTAssertEqual(fileKind("\(dir)/pocketterm-live.ts"), .file)
    XCTAssertEqual(read("\(dir)/pocketterm-live.ts"), read("\(systemRepoIntegrations)/omp/pocketterm-live.ts"))
    XCTAssertFalse(fm.fileExists(atPath: "\(dir)/pocketterm-live.ts.pocketterm-tmp"))
  }

  func testOmpGoesIntoEveryProfileTooAndCountsAsInstalledOnlyWhereEachHasIt() async throws {
    try fm.createDirectory(atPath: "\(home)/.omp/profiles/personal", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(home)/.omp/profiles/Bad", withIntermediateDirectories: true)
    systemWrite("\(home)/.omp/profiles/notes.txt", "")
    let integrations = integrations(run: SystemFakeClaude("/nope").run)
    XCTAssertEqual(integrations.ompProfiles(), ["personal"])

    try await integrations.install(.omp)
    let live = "pocketterm-live.ts"
    XCTAssertTrue(fm.fileExists(atPath: "\(home)/.omp/agent/extensions/\(live)"))
    XCTAssertTrue(fm.fileExists(atPath: "\(home)/.omp/profiles/personal/agent/extensions/\(live)"))
    XCTAssertFalse(fm.fileExists(atPath: "\(home)/.omp/profiles/Bad/agent"))
    var state = try await integrations.state(.omp)
    XCTAssertEqual(state, Self.current)

    systemWrite("\(home)/.omp/profiles/personal/agent/extensions/\(live)", "// older")
    state = try await integrations.state(.omp)
    XCTAssertEqual(state, Self.outdated)

    try fm.removeItem(atPath: "\(home)/.omp/profiles/personal/agent/extensions/\(live)")
    state = try await integrations.state(.omp)
    XCTAssertFalse(state.installed)
  }

  func testNoProfilesFolderNoProfiles() {
    XCTAssertEqual(integrations(run: SystemFakeClaude("/nope").run).ompProfiles(), [])
  }

  func testOmpIsFoundByItsFolderOrItsExecutable() async throws {
    let shell = SystemFakeClaude("/nope")
    let omp = "\(home)/bin/omp"
    var found = await integrations(run: shell.run, ompPaths: [omp]).found(.omp)
    XCTAssertFalse(found)
    systemWrite(omp, "")
    found = await integrations(run: shell.run, ompPaths: [omp]).found(.omp)
    XCTAssertTrue(found)
    try fm.removeItem(atPath: omp)
    try fm.createDirectory(atPath: "\(home)/.omp", withIntermediateDirectories: true)
    found = await integrations(run: shell.run, ompPaths: [omp]).found(.omp)
    XCTAssertTrue(found)
  }

  // ---------------------------------------------------------------- Claude Code

  private var claude: SystemFakeClaude!
  private var dir: String { "\(home)/.config/pocketterm/claude-plugin" }

  private func claudeSetUp() -> Integrations {
    claude = SystemFakeClaude("\(home)/bin/claude")
    systemWrite(claude.path, "")
    return integrations(run: claude.run, claudePaths: ["\(home)/nope/claude", claude.path])
  }

  private func listed(from: String, enabled: Bool = true) -> JSON {
    ["id": "pocketterm@pocketterm", "enabled": .bool(enabled), "readFromFolder": .string("\(from)/plugins/pocketterm")]
  }

  func testAFirstInstallCopiesTheMarketplaceWithoutItsTestsAddsItAndInstallsThePlugin() async throws {
    let integrations = claudeSetUp()
    systemWrite("\(dir)/plugins/pocketterm/hooks/gone.ts", "")

    try await integrations.install(.claude)
    let expected = systemFilesIn("\(systemRepoIntegrations)/claude").filter {
      !$0.key.hasPrefix("plugins/pocketterm/tests/")
    }
    XCTAssertEqual(systemFilesIn(dir), expected)
    XCTAssertEqual(
      read("\(dir)/.claude-plugin/marketplace.json"),
      read("\(systemRepoIntegrations)/claude/.claude-plugin/marketplace.json"))
    XCTAssertTrue(fm.fileExists(atPath: "\(dir)/plugins/pocketterm/.claude-plugin/plugin.json"))
    XCTAssertFalse(fm.fileExists(atPath: "\(dir)/plugins/pocketterm/tests"))
    XCTAssertEqual(
      claude.calls,
      [
        "--version",
        "plugin list --json",
        "plugin marketplace add \(dir) --json",
        "plugin install pocketterm@pocketterm --json",
      ])

    claude.list = [listed(from: dir)]
    var state = try await integrations.state(.claude)
    XCTAssertEqual(state, Self.current)
    systemWrite("\(dir)/plugins/pocketterm/hooks/hooks.json", "{}")
    state = try await integrations.state(.claude)
    XCTAssertEqual(state, Self.outdated)
    XCTAssertEqual(claude.others, [])
  }

  func testAnExtraFileInTheCopyMakesItOutdated() async throws {
    let integrations = claudeSetUp()
    try await integrations.install(.claude)
    claude.list = [listed(from: dir)]
    systemWrite("\(dir)/plugins/pocketterm/hooks/extra.ts", "")
    let state = try await integrations.state(.claude)
    XCTAssertEqual(state, Self.outdated)
  }

  func testUpdatingRefreshesTheMarketplaceAndThePluginAndTurnsADisabledOneBackOn() async throws {
    let integrations = claudeSetUp()
    claude.list = [listed(from: dir, enabled: false)]
    let state = try await integrations.state(.claude)
    XCTAssertFalse(state.installed)
    claude.calls = []

    try await integrations.install(.claude)
    XCTAssertEqual(
      claude.calls,
      [
        "--version",
        "plugin list --json",
        "plugin marketplace update pocketterm --json",
        "plugin update pocketterm@pocketterm --json",
        "plugin enable pocketterm@pocketterm --json",
      ])
  }

  func testAPockettermPluginLoadingFromElsewhereIsMovedOverToTheCopy() async throws {
    let integrations = claudeSetUp()
    claude.list = [listed(from: "\(home)/Dev/pocketterm/apps/pocketterm-desktop/integrations/claude")]
    let state = try await integrations.state(.claude)
    XCTAssertFalse(state.installed)
    claude.calls = []

    try await integrations.install(.claude)
    XCTAssertEqual(
      Array(claude.calls.dropFirst(2)),
      ["plugin marketplace add \(dir) --json", "plugin update pocketterm@pocketterm --json"])
  }

  func testAMissingClaudeIsSaidPlainlyAndNothingIsRunOrCopied() async throws {
    let integrations = claudeSetUp()
    try fm.removeItem(atPath: claude.path)
    let state = try await integrations.state(.claude)
    XCTAssertEqual(state, IntegrationState(installed: false, current: false, problem: "Claude Code isn't installed"))
    do {
      try await integrations.install(.claude)
      XCTFail("installed")
    } catch let e as IntegrationException {
      XCTAssertEqual(e.message, "Claude Code isn't installed")
    }
    XCTAssertEqual(claude.calls, [])
    XCTAssertFalse(fm.fileExists(atPath: dir))
    let found = await integrations.found(.claude)
    XCTAssertFalse(found)
  }

  func testAClaudeThatNeverAnswersIsSaidPlainlyInsteadOfKeepingSettingsChecking() async throws {
    _ = claudeSetUp()
    let fake = claude!
    let hung = integrations(
      run: { exe, args in
        if args.first == "plugin" {
          try await Task.sleep(for: .seconds(3600))
        }
        return try await fake.run(exe, args)
      },
      claudePaths: [fake.path], claudeTimeout: .milliseconds(50))
    let state = try await hung.state(.claude)
    XCTAssertEqual(state, IntegrationState(installed: false, current: false, problem: Integrations.noAnswer))
    let modsOff = await hung.claudeModsOff()
    XCTAssertFalse(modsOff)
    do {
      try await hung.install(.claude)
      XCTFail("installed")
    } catch let e as IntegrationException {
      XCTAssertEqual(e.message, Integrations.noAnswer)
    }
  }

  func testAClaudeProcessThatHangsIsStoppedAtTheTimeout() async throws {
    let script = "\(home)/hangs/claude"
    systemWrite(script, "#!/bin/sh\nexec sleep 30\n", mode: 0o755)
    let hangs = Integrations(
      home: home, bundled: systemRepoIntegrations, claudePaths: [script], claudeTimeout: .milliseconds(300))
    let clock = ContinuousClock.now
    let state = try await hangs.state(.claude)
    XCTAssertEqual(state.problem, Integrations.noAnswer)
    XCTAssertLessThan(ContinuousClock.now - clock, .seconds(10))
  }

  func testClaudeFoundOnlyByTheLoginShellsPathIsUsed() async throws {
    _ = claudeSetUp()
    try fm.moveItem(atPath: claude.path, toPath: "\(home)/claude")
    let onPath = SystemFakeClaude("\(home)/claude")
    onPath.onPath = "\(home)/claude\n"
    let found = integrations(run: onPath.run, claudePaths: [claude.path])
    let state = try await found.state(.claude)
    XCTAssertEqual(state, Self.none)
    XCTAssertEqual(onPath.calls, ["--version", "plugin list --json"])
  }

  func testAProfileThatPrintsSomethingBeforeTheShellsAnswerDoesntHideClaude() async throws {
    _ = claudeSetUp()
    try fm.moveItem(atPath: claude.path, toPath: "\(home)/claude")
    let onPath = SystemFakeClaude("\(home)/claude")
    onPath.onPath = "Welcome back!\n\u{1b}[1mbanner\u{1b}[0m\n\(home)/claude\n"
    let found = integrations(run: onPath.run, claudePaths: [claude.path])
    let state = try await found.state(.claude)
    XCTAssertEqual(state, Self.none)
  }

  func testFromFinderClaudeInstalledWithNvmNewestNodeFirstIsFoundWithoutAShell() async throws {
    for v in ["v9.11.2", "v20.10.0", "v18.19.1"] { systemWrite("\(home)/.nvm/versions/node/\(v)/bin/claude", "") }
    let nvm = SystemFakeClaude("\(home)/.nvm/versions/node/v20.10.0/bin/claude")
    let shell = SystemFakeClaude("/nope")
    shell.onPath = "/somewhere/claude\n"
    let run: Integrations.Run = { exe, args in
      if exe == "/bin/zsh" { shell.calls.append(args.joined(separator: " ")) }
      return try await nvm.run(exe, args)
    }
    let state = try await integrations(run: run).state(.claude)
    XCTAssertNil(state.problem)
    XCTAssertEqual(shell.calls, [])
    XCTAssertEqual(nvm.others, [])
  }

  func testFromFinderClaudeInstalledWithNpmRunsOnTheNodeItWasInstalledWith() async throws {
    // npm's claude: a `#!/usr/bin/env node` script in the global prefix; the Node it was installed with in nvm.
    systemWrite(
      "\(home)/.nvm/versions/node/v20.10.0/bin/node",
      """
      #!/bin/sh
      case "$*" in
        *--version*) echo '2.1.400 (Claude Code)' ;;
        *"plugin list"*) echo '[]' ;;
      esac

      """, mode: 0o755)
    let script = "\(home)/.npm-global/bin/claude"
    systemWrite(script, "#!/usr/bin/env node\nconsole.log(\"not this node\");\n", mode: 0o755)
    let npm = Integrations(home: home, bundled: systemRepoIntegrations, claudePaths: [script])
    let state = try await npm.state(.claude)
    XCTAssertEqual(state, Self.none)
  }

  func testAClaudeCodeOlderThanModsIsTooOld() async throws {
    let integrations = claudeSetUp()
    claude.version = "2.1.286 (Claude Code)"
    var state = try await integrations.state(.claude)
    XCTAssertEqual(state.problem, "Claude Code 2.1.286 is too old: update it to 2.1.287 or later")
    claude.version = "2.2.0 (Claude Code)"
    state = try await integrations.state(.claude)
    XCTAssertNil(state.problem)
    claude.version = "3.0.0 (Claude Code)"
    state = try await integrations.state(.claude)
    XCTAssertNil(state.problem)
    claude.version = "2.1.287 (Claude Code)"
    state = try await integrations.state(.claude)
    XCTAssertNil(state.problem)
  }

  func testModsSwitchedOffAreNoticedThroughClaudePluginTest() async throws {
    let integrations = claudeSetUp()
    var off = await integrations.claudeModsOff()
    XCTAssertFalse(off)
    claude.modsOff = true
    off = await integrations.claudeModsOff()
    XCTAssertTrue(off)
    let last = claude.calls.last ?? ""
    XCTAssertTrue(last.hasPrefix("plugin test "))
    // The empty directory it tests is gone again.
    XCTAssertFalse(fm.fileExists(atPath: String(last.dropFirst("plugin test ".count))))

    try fm.removeItem(atPath: claude.path)
    off = await integrations.claudeModsOff()
    XCTAssertFalse(off)
  }

  func testAFailingClaudeCommandFailsTheInstallWithWhatItSaid() async throws {
    let integrations = claudeSetUp()
    claude.fail = "plugin install pocketterm@pocketterm --json"
    do {
      try await integrations.install(.claude)
      XCTFail("installed")
    } catch let e as IntegrationException {
      XCTAssertEqual(e.message, "Plugin \"pocketterm\" not found")
    }
  }

  func testAFailedRunWithoutAJsonLineSaysItsStderrElseItsExitCode() {
    XCTAssertEqual(Integrations.message(ProcessResult(code: 2, out: "plain\n", err: "  boom \n")), "boom")
    XCTAssertEqual(Integrations.message(ProcessResult(code: 3, out: "", err: "")), "exit code 3")
  }

  func testWhatThePhoneHearsOfACheck() {
    func check(_ installed: Bool, _ current: Bool, _ problem: String? = nil, modsOff: Bool = false) -> AgentCheck {
      AgentCheck(state: IntegrationState(installed: installed, current: current, problem: problem), modsOff: modsOff)
    }
    XCTAssertEqual(integrationOf(check(false, false)), .missing)
    XCTAssertEqual(integrationOf(check(true, true, "too old")), .missing)
    XCTAssertEqual(integrationOf(check(true, false, modsOff: true)), .outdated)
    XCTAssertEqual(integrationOf(check(true, true, modsOff: true)), .off)
    XCTAssertEqual(integrationOf(check(true, true)), .installed)
  }
}
#endif
