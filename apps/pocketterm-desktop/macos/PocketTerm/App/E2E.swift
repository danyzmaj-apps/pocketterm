#if DEBUG || POCKETTERM_SMOKE
import AppKit
import CryptoKit
import Foundation
import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals

/// tool/e2e's hold on a test build (tool/e2e/lib/mac_app.dart starts it with `POCKETTERM_E2E_DIR`): what the
/// Flutter app's integration test reached in-process, reached here through a folder instead. With the variable
/// set, the app keeps its secrets in a file there (so a restarted app is still signed in), never adds a login item,
/// never keeps the Mac awake, picks `POCKETTERM_E2E_FOLDER` for Add folder…, calls itself `POCKETTERM_E2E_DEVICE`,
/// finds omp at `POCKETTERM_E2E_OMP` and never Claude Code, records the pairing links it makes and the
/// notifications meant for the phones, and answers the run's requests (`E2EControl`). A released build has none of
/// this: the file is compiled only into test builds, and only a test build reads `testHooks()`.
enum E2E {
  /// The run's folder for this app (under its throwaway work folder, never the artifacts: the secrets are there).
  static let dir: String? = testHooks()["POCKETTERM_E2E_DIR"].flatMap { $0.isEmpty ? nil : $0 }

  static func env(_ key: String) -> String? { testHooks()[key].flatMap { $0.isEmpty ? nil : $0 } }

  /// The controller for an e2e run: the real one with the run's stand-ins, as integration_test/e2e/app.dart had it.
  static func controller(prefs: PreferenceStore, device: String, host: MacHost, serverDir: (() -> URL)?)
    -> AppController?
  {
    guard let dir else { return nil }
    return E2EAppController(
      prefs: prefs, device: env("POCKETTERM_E2E_DEVICE") ?? device, host: E2EHost(host),
      integrations: Integrations(claudePaths: [], ompPaths: env("POCKETTERM_E2E_OMP").map { [$0] } ?? []),
      secrets: FileSecrets(path: "\(dir)/secrets.json"), serverDir: serverDir)
  }
}

/// The controller, recording what the run checks afterwards: every pairing link made (the phone's hand-off
/// files) and every notification meant for the phones, whether it went or not (none goes while someone uses
/// the Mac).
final class E2EAppController: AppController {
  private(set) var pairingLinks: [URL] = []
  private(set) var phoneNotices: [(title: String, body: String)] = []

  override func pairingLink() async throws -> URL {
    let link = try await super.pairingLink()
    pairingLinks.append(link)
    return link
  }

  override func notifyPhone(_ title: String, _ body: String, session: String? = nil, activity: String? = nil) async
    -> Bool
  {
    phoneNotices.append((title, body))
    return await super.notifyPhone(title, body, session: session, activity: activity)
  }
}

/// The Mac's host minus what would reach past the run: launch at login only in memory (a login item would
/// register the test build), no keeping awake, the folder picker answering with the run's projects folder.
final class E2EHost: DesktopHost {
  init(_ mac: MacHost) { self.mac = mac }
  private let mac: MacHost
  private var loginItem = false

  func start(onEvent: @escaping @MainActor (String) async -> Void) async { await mac.start(onEvent: onEvent) }
  func showMain() async { await mac.showMain() }
  func hideMain() async { await mac.hideMain() }
  func quit() async { await mac.quit() }
  func deviceName() async -> String {
    if let name = E2E.env("POCKETTERM_E2E_DEVICE") { return name }
    return await mac.deviceName()
  }
  func idleSeconds() async -> Int { await mac.idleSeconds() }
  func launchAtLogin() async -> Bool { loginItem }
  func setLaunchAtLogin(on: Bool) async throws { loginItem = on }
  func pickFolders() async -> [String] { E2E.env("POCKETTERM_E2E_FOLDER").map { [$0] } ?? [] }
  func setKeepAwake(on: Bool) async {}
  func setAppIcon(_ icon: String) async { await mac.setAppIcon(icon) }
}

/// Secrets in a file of the run's (base64 values, owner-only): the person's Keychain is never touched, and they
/// outlive the app, as the Flutter test's one MemorySecrets outlived its restarted app.
final class FileSecrets: SecureStore, @unchecked Sendable {
  init(path: String) { self.path = path }
  private let path: String
  private let lock = NSLock()

  private func load() -> [String: String] {
    guard let d = FileManager.default.contents(atPath: path),
      let o = try? JSONSerialization.jsonObject(with: d) as? [String: String]
    else { return [:] }
    return o
  }

  private func save(_ values: [String: String]) throws {
    let d = try JSONSerialization.data(withJSONObject: values)
    try d.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  func data(_ account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return load()[account].flatMap { Data(base64Encoded: $0) }
  }

  func setData(_ account: String, _ value: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    var v = load()
    v[account] = value.base64EncodedString()
    try save(v)
  }

  func remove(_ account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var v = load()
    v[account] = nil
    try save(v)
  }
}

/// The run's requests: `<dir>/req/<n>.json` (`{"cmd": …, …}`, written whole by a rename), answered in
/// `<dir>/res/<n>.json` (`{"ok": …}` or `{"error": …}`), one at a time as they come. What the Flutter test asked
/// the controller, the terminals and the server directly.
final class E2EControl {
  init(_ app: AppController, dir: String) {
    self.app = app
    self.dir = dir
  }

  private let app: AppController
  private let dir: String
  private var timer: Timer?
  private var busy = Set<String>()

  /// The second computer on the server (the phone lists it locked), signed in until the end of the run.
  private var spare: Server?

  func start() {
    for d in ["req", "res"] {
      try? FileManager.default.createDirectory(atPath: "\(dir)/\(d)", withIntermediateDirectories: true)
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  private func poll() {
    let req = "\(dir)/req"
    for name in (try? FileManager.default.contentsOfDirectory(atPath: req)) ?? [] {
      guard name.hasSuffix(".json"), !busy.contains(name) else { continue }
      let path = "\(req)/\(name)"
      guard let d = FileManager.default.contents(atPath: path), case .object(let r)? = JSON.tryParse(d) else {
        continue
      }
      busy.insert(name)
      try? FileManager.default.removeItem(atPath: path)
      Task {
        let answer: JSONObject
        do {
          answer = ["ok": try await handle(r)]
        } catch {
          answer = ["error": .string("\(error)")]
        }
        let out = URL(fileURLWithPath: "\(dir)/res/\(name)")
        try? Data(JSON.object(answer).encoded().utf8).write(to: out, options: .atomic)
        busy.remove(name)
      }
    }
  }

  private func arg(_ r: JSONObject, _ k: String) throws -> String {
    guard let v = r[k]?.string else { throw E2EError("\(r["cmd"]?.string ?? "?"): no \(k)") }
    return v
  }

  private func handle(_ r: JSONObject) async throws -> JSON {
    let terms = app.terminals
    switch r["cmd"]?.string ?? "" {
    case "state": return .object(await state())
    case "windows": return .array(await terms.windows().map { .object(Self.window($0)) })
    case "statuses":
      return .array(
        await terms.statuses().map {
          ["id": .string($0.id), "label": .string($0.label), "state": .string($0.state.rawValue), "note": .string($0.note),
           "usable": .bool($0.usable)]
        })
    case "unreported":
      return .array(app.unreportedAgentWindows(await terms.windows()).map { .object(Self.window($0)) })
    case "opens-in":
      let h = await terms.opensIn(app.terminalApp)
      return ["id": .string(h.id), "label": .string(h.label), "describe": .string(terms.describe(h))]
    case "apps": return .array(terms.apps.map { ["id": .string($0.id), "label": .string($0.label)] })
    case "press-keys":
      try await terms.pressKeys(try arg(r, "window"), r["keys"]?.strings ?? [])
    case "send":
      try await terms.send(try arg(r, "window"), try arg(r, "text"), enter: r["enter"]?.bool ?? true)
    case "close": try await terms.close(try arg(r, "window"))
    case "plain-screen": return .string(try await terms.plainScreen(try arg(r, "window")))
    case "ghostty-launch":
      guard let g = terms.ghostty else { throw E2EError("no Ghostty host") }
      return .string(try await g.launch(try arg(r, "dir"), command: nil, into: nil))
    case "live":
      guard let s = app.live[try arg(r, "key")] else { return .null }
      var o = s.summary.toJson()
      o["items"] = .array(s.log.items.map { .object($0.toJson()) })
      return .object(o)
    case "check-agents":
      await app.checkAgents()
    case "server-devices":
      return .array(try await app.serverDevices().map { .object($0.toJson()) })
    case "revoke": try await app.revokeServerDevice(try arg(r, "id"))
    case "computer-setup-link": return (await app.computerSetupLink()).map { .string($0.absoluteString) } ?? .null
    case "supabase-setup-link":
      guard let s = app.server as? SupabaseServerClient else { throw E2EError("not on Supabase") }
      return .string(try await s.newSetupLink().absoluteString)
    case "spare":
      // A second computer that no phone link names (_handOff): the phone lists it locked.
      let link = try arg(r, "link")
      guard let backend = Backend.fromLink(link), let token = Backend.setupToken(link) else {
        throw E2EError("not a setup link")
      }
      let s = Servers.make(backend, tokens: MemoryDeviceTokens())
      let label = try arg(r, "label")
      _ = try await s.redeemSetup(token, label: label, platform: "macos")
      try await s.putDesktop(try arg(r, "id"), name: label, platform: "macos")
      spare = s
    case "spare-devices":
      guard let s = spare else { throw E2EError("no spare computer") }
      return .array(try await s.devices().map { .object($0.toJson()) })
    case "spare-leave":
      try? await spare?.leave()
      spare?.close()
      spare = nil
    case "leave":
      try await app.server?.leave()
    case "hosting-stop":
      guard let h = app.hosting else { throw E2EError("no built-in server") }
      await h.stop()
    case "hosting-start":
      guard let h = app.hosting else { throw E2EError("no built-in server") }
      try await h.start(port: r["port"]?.int ?? h.port)
    case "open-main": await app.openMain()
    case "quit":
      // After the answer is out.
      Task { try? await Task.sleep(for: .milliseconds(200)); NSApp.terminate(nil) }
    default: throw E2EError("unknown request \(r["cmd"]?.string ?? "")")
    }
    return .null
  }

  private static func window(_ w: TermWindow) -> JSONObject {
    ["key": .string(w.key), "title": .string(w.title), "tab": .string(w.tab), "cwd": .string(w.cwd),
     "program": .string(w.program), "app": .string(w.app), "via": .string(w.via), "tty": .string(w.tty),
     "osWindow": .string(w.osWindow), "tabId": .string(w.tabId), "profile": .string(w.profile),
     "agent": w.agent.map { .string($0.name) } ?? .null]
  }

  private func state() async -> JSONObject {
    let env = ProcessInfo.processInfo.environment
    var o: JSONObject = [
      "env": .object(
        Dictionary(
          uniqueKeysWithValues: ["PATH", "HOME", "TERM", "TERM_PROGRAM", "LANG", "LC_ALL", "LC_CTYPE", "ZDOTDIR"]
            .compactMap { k in env[k].map { (k, JSON.string($0)) } })),
      "device": .string(app.device),
      "terminalOn": .bool(app.terminalOn),
      "terminalApp": .string(app.terminalApp),
      "projectRoots": .strings(app.projectRoots),
      "getReadyDone": .bool(app.getReadyDone),
      "ompProfiles": .strings(app.ompProfiles),
      "launchAtLogin": app.launchAtLogin.map(JSON.bool) ?? .null,
      "hostLaunchAtLogin": .bool(await app.host.launchAtLogin()),
      "authError": app.authError.map(JSON.string) ?? .null,
      "backend": app.backend.map { .string($0.url) } ?? .null,
      "backendHost": app.backend.map { .string($0.host) } ?? .null,
      "sessions": .array(app.live.sessions.map { .object($0.summary.toJson()) }),
    ]
    if let user = app.user {
      o["user"] = ["id": .string(user.id), "device": .string(user.device.id)]
      o["desktopId"] = .string(app.desktopId(user.id))
      if let key = try? await app.channelKey() {
        o["channelKey"] = .string(SHA256.hash(data: key.bytes).map { String(format: "%02x", $0) }.joined())
      }
    }
    if let h = app.hosting {
      o["hosting"] = ["port": .int(h.port), "running": .bool(h.running),
                      "publicUrl": h.publicUrl.map { .string($0.absoluteString) } ?? .null]
    }
    if let agents = app.agents {
      o["agents"] = .object(
        Dictionary(
          uniqueKeysWithValues: agents.map { (a, c) in
            (a.name, JSON.object(["integration": .string(integrationOf(c).rawValue),
                                  "problem": c.state.problem.map(JSON.string) ?? .null]))
          }))
    }
    if let e2e = app as? E2EAppController {
      o["pairingLinks"] = .strings(e2e.pairingLinks.map(\.absoluteString))
      o["notices"] = .array(e2e.phoneNotices.map { ["title": .string($0.title), "body": .string($0.body)] })
    }
    return o
  }
}

struct E2EError: Error, CustomStringConvertible {
  init(_ description: String) { self.description = description }
  let description: String
}
#endif
