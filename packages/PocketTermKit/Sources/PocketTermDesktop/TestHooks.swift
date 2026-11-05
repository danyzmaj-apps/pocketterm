#if os(macOS)
import Foundation

/// A build made for tool/smoke or tool/e2e: a DEBUG build, or one compiled with `-D POCKETTERM_SMOKE`. Only such a
/// build reads the environment variables that point PocketTerm at stand-ins: `POCKETTERM_TAILSCALE` (the Tailscale
/// CLI), `POCKETTERM_CLI_JSON` (where the local API's port and token go), `POCKETTERM_KITTY_DIR` (kitty's sockets) and
/// `POCKETTERM_PROFILE` (secrets in memory, the accessibility tree on). A released build ignores them.
public var testBuild: Bool {
  #if DEBUG || POCKETTERM_SMOKE
    true
  #else
    false
  #endif
}

/// Where those variables are read from: this process's environment in a `testBuild`, none otherwise.
public func testHooks() -> [String: String] { testBuild ? ProcessInfo.processInfo.environment : [:] }
#endif
