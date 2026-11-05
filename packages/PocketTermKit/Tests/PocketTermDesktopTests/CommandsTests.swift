#if os(macOS)
import Foundation
import XCTest

@testable import PocketTermDesktop

final class CommandsTests: XCTestCase {
  private struct Gone: Error {}

  func testSudosPasswordScriptIsThereWhileTheCommandRunsAndGoneAfterAlsoWhenItThrows() async throws {
    final class Seen: @unchecked Sendable {
      let lock = NSLock()
      var paths: [String] = []
      var scripts: [String] = []
      var envs: [[String: String]] = []
      var fail = false
    }
    let seen = Seen()
    let mac = Commands(
      run: { exe, args, env in
        let askpass = env["SUDO_ASKPASS"]!
        let script = try String(contentsOfFile: askpass, encoding: .utf8)
        let mode = try FileManager.default.attributesOfItem(atPath: askpass)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        let fail = seen.lock.withLock {
          seen.paths.append(askpass)
          seen.scripts.append(script)
          seen.envs.append(env)
          return seen.fail
        }
        if fail { throw Gone() }
        return CommandResult(code: 0, output: "")
      },
      brew: { "/opt/homebrew/bin/brew" }, macPorts: { nil })
    _ = try await mac.run(["brew", "install", "tmux"], password: "Homebrew needs your \"password\"")
    seen.lock.withLock { seen.fail = true }
    do {
      _ = try await mac.run(["brew", "install", "tmux"], password: "again")
      XCTFail("didn't throw")
    } catch is Gone {}
    XCTAssertEqual(seen.paths.count, 2)
    for path in seen.paths {
      XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }
    // macOS's dialog, its quotes taken out of what it says.
    XCTAssertEqual(
      seen.scripts[0],
      "#!/bin/sh\nexec /usr/bin/osascript -e 'text returned of (display dialog \"Homebrew needs your password\" "
        + "default answer \"\" with hidden answer with title \"PocketTerm\" with icon caution)'\n")
    XCTAssertEqual(seen.envs[0]["PATH"], "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    XCTAssertEqual(seen.envs[0]["HOMEBREW_NO_ENV_HINTS"], "1")
  }

  func testWithoutHomebrewABrewInstallSaysSo() async throws {
    let mac = Commands(run: { _, _, _ in XCTFail("ran"); return CommandResult(code: 0, output: "") }, brew: { nil })
    let result = try await mac.run(Commands.tmuxInstall)
    XCTAssertEqual(result, CommandResult(code: 127, output: "Homebrew isn’t installed."))
  }

  func testHomebrewAndMacPortsAreFoundWhereTheyLive() {
    XCTAssertEqual(Commands.findBrew(exists: { $0 == "/usr/local/bin/brew" }), "/usr/local/bin/brew")
    XCTAssertEqual(
      Commands.findBrew(exists: { ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"].contains($0) }),
      "/opt/homebrew/bin/brew")
    XCTAssertNil(Commands.findBrew(exists: { _ in false }))
    XCTAssertEqual(Commands.findMacPorts(exists: { _ in true }), "/opt/local/bin/port")
    XCTAssertNil(Commands.findMacPorts(exists: { _ in false }))
  }

  func testACommandRunsWithBothStreamsAndItsCode() async throws {
    let result = try await Commands().run(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"])
    XCTAssertEqual(result.code, 3)
    XCTAssertTrue(result.output.contains("out\n"))
    XCTAssertTrue(result.output.contains("err\n"))
  }
}
#endif
