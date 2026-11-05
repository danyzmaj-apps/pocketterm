#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals
import ServiceManagement
import XCTest

@testable import PocketTermDesktop

/// apps/pocketterm-desktop/integrations in this checkout: what the app bundles.
let systemRepoIntegrations: String = {
  var url = URL(fileURLWithPath: #filePath)
  for _ in 0..<4 { url.deleteLastPathComponent() }  // <file>, PocketTermDesktopTests, Tests, PocketTermKit → packages
  return url.deletingLastPathComponent().appendingPathComponent("apps/pocketterm-desktop/integrations").path
}()

/// A fresh folder under the temp folder, removed by the test's teardown.
func systemScratchDir(_ test: XCTestCase, _ name: String) -> String {
  let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(name)-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  // Symlinks resolved (/var → /private/var), as paths read back from the file system are.
  let real = realPath(dir) ?? dir
  test.addTeardownBlock { try? FileManager.default.removeItem(atPath: real) }
  return real
}

/// The files under `dir`, by their path below it, hidden ones left out.
func systemFilesIn(_ dir: String) -> [String: String] {
  var out: [String: String] = [:]
  for sub in FileManager.default.subpaths(atPath: dir) ?? [] {
    let path = "\(dir)/\(sub)"
    guard fileKind(path, followLinks: true) == .file, !(sub as NSString).lastPathComponent.hasPrefix(".") else {
      continue
    }
    out[sub] = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
  }
  return out
}

func systemWrite(_ path: String, _ text: String, mode: Int? = nil) {
  try! FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try! text.write(toFile: path, atomically: false, encoding: .utf8)
  if let mode { try! FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
}

/// A `claude` that answers from `list` (its `plugin list --json`) and records what it's asked; `fail` makes that
/// command fail as `--json` reports it, `modsOff` has its `plugin test` refuse as with mods switched off.
final class SystemFakeClaude: @unchecked Sendable {
  init(_ path: String) { self.path = path }
  let path: String
  private let lock = NSLock()
  private var _version = "2.1.296 (Claude Code)"
  private var _list: [JSON] = []
  private var _fail: String?
  private var _modsOff = false
  private var _onPath: String?
  private var _calls: [String] = []
  private var _others: [String] = []

  private func with<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var version: String {
    get { with { _version } }
    set { with { _version = newValue } }
  }
  var list: [JSON] {
    get { with { _list } }
    set { with { _list = newValue } }
  }
  var fail: String? {
    get { with { _fail } }
    set { with { _fail = newValue } }
  }
  var modsOff: Bool {
    get { with { _modsOff } }
    set { with { _modsOff = newValue } }
  }
  /// What a login shell's `command -v claude` prints; nil: nothing found.
  var onPath: String? {
    get { with { _onPath } }
    set { with { _onPath = newValue } }
  }
  var calls: [String] {
    get { with { _calls } }
    set { with { _calls = newValue } }
  }
  /// Executables run that are neither the shell nor this claude.
  var others: [String] { with { _others } }

  var run: Integrations.Run { { [self] exe, args in self.answer(exe, args) } }

  private func answer(_ exe: String, _ args: [String]) -> ProcessResult {
    with {
      if exe == "/bin/zsh" { return ProcessResult(code: _onPath == nil ? 1 : 0, out: _onPath ?? "", err: "") }
      if exe != path { _others.append(exe) }
      let call = args.joined(separator: " ")
      _calls.append(call)
      if call == _fail {
        return ProcessResult(
          code: 1, out: "{\"outcome\":\"failed\",\"message\":\"Plugin \\\"pocketterm\\\" not found\"}\n", err: "✘ Failed")
      }
      if call == "--version" { return ProcessResult(code: 0, out: "\(_version)\n", err: "") }
      if args.prefix(2) == ["plugin", "test"] && _modsOff {
        return ProcessResult(
          code: 1, out: "",
          err: "claude plugin test: hooks modules are turned off in this process: the rollout switch was saved off "
            + "by an earlier session and is not refreshed yet.\n")
      }
      if call == "plugin list --json" { return ProcessResult(code: 0, out: JSON.array(_list).encoded(), err: "") }
      return ProcessResult(code: 0, out: "{\"outcome\":\"ok\"}\n", err: "")
    }
  }
}

/// A store kept as one file is: each write reads it whole, changes it and writes it back, with a wait in between,
/// so two writes at once lose one unless something serialises them.
final class SystemOneFile: SecureStore, @unchecked Sendable {
  private let lock = NSLock()
  private var _file: [String: Data] = [:]
  private var _failNext = false

  var file: [String: Data] {
    get { lock.withLock { _file } }
    set { lock.withLock { _file = newValue } }
  }
  var failNext: Bool {
    get { lock.withLock { _failNext } }
    set { lock.withLock { _failNext = newValue } }
  }

  private func change(_ body: (inout [String: Data]) -> Void) throws {
    var map = file
    usleep(2000)
    if lock.withLock({ () -> Bool in
      let fail = _failNext
      _failNext = false
      return fail
    }) {
      throw SecureStoreError(status: -25308, message: "locked")
    }
    body(&map)
    file = map
  }

  func data(_ account: String) throws -> Data? {
    usleep(500)
    return file[account]
  }
  func setData(_ account: String, _ value: Data) throws { try change { $0[account] = value } }
  func remove(_ account: String) throws { try change { $0[account] = nil } }
}

/// A login item macOS answers for as a test sets it: `after` is its status once registered or unregistered.
final class SystemFakeLoginItem: LoginItem {
  init(status: SMAppService.Status = .notRegistered) { self.status = status }
  var status: SMAppService.Status
  var after: SMAppService.Status?
  var refuse: Error?
  var calls: [String] = []

  func register() throws {
    calls.append("register")
    if let refuse { throw refuse }
    status = after ?? .enabled
  }

  func unregister() throws {
    calls.append("unregister")
    if let refuse { throw refuse }
    status = after ?? .notRegistered
  }
}
#endif
