#if os(macOS)
import CryptoKit
import Foundation
import PocketTermKit

/// One migration: `supabase/migrations/<version>_<name>.sql`.
public struct Migration: Sendable, Equatable {
  public init(version: String, name: String, sql: String) {
    self.version = version
    self.name = name
    self.sql = sql
  }
  public let version: String
  public let name: String
  public let sql: String
}

/// What PocketTerm puts on a Supabase project, shipped with the app (the build copies
/// apps/pocketterm-desktop/supabase into its resources), so a downloaded app sets a project up without the repo or
/// the Supabase CLI.
public protocol SupabaseSource: Sendable {
  /// Oldest first.
  func migrations() async throws -> [Migration]

  /// The Edge Function `pocketterm` (supabase/functions/pocketterm/index.ts).
  func function() async throws -> String
}

/// The files in a `supabase/` folder: the app's `Resources/supabase` by default.
public struct BundledSupabaseSource: SupabaseSource {
  public init(directory: URL? = nil) {
    self.directory = directory ?? Bundle.main.resourceURL!.appendingPathComponent("supabase")
  }

  public let directory: URL

  public func migrations() async throws -> [Migration] {
    let folder = directory.appendingPathComponent("migrations")
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".sql") }
      .sorted()
    return try names.map {
      migrationFromFile($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8))
    }
  }

  public func function() async throws -> String {
    try String(
      contentsOf: directory.appendingPathComponent("functions/pocketterm/index.ts"), encoding: .utf8)
  }
}

/// `…/20261023000000_pocketterm.sql` → version `20261023000000`, name `pocketterm`.
public func migrationFromFile(_ path: String, _ sql: String) -> Migration {
  var file = path.components(separatedBy: "/").last ?? path
  if file.hasSuffix(".sql") { file.removeLast(4) }
  guard let cut = file.firstIndex(of: "_") else { return Migration(version: file, name: "", sql: sql) }
  return Migration(version: String(file[..<cut]), name: String(file[file.index(after: cut)...]), sql: sql)
}

/// A P-256 key pair as a private JWK (ES256) with a random `kid`: what the function signs live channel tokens with,
/// imported as the project's JWT signing key so Realtime takes those tokens.
public struct LiveSigningKey: Sendable, Equatable {
  public let kty: String
  public let crv: String
  public let alg: String
  public let kid: String
  public let x: String
  public let y: String
  public let d: String

  /// As a JSON object.
  public var json: JSON {
    [
      "kty": .string(kty), "crv": .string(crv), "alg": .string(alg), "kid": .string(kid), "x": .string(x),
      "y": .string(y), "d": .string(d),
    ]
  }

  /// The secret PT_REALTIME_JWK's text: Dart's jsonEncode of the map, in its order (kty, crv, alg, kid, x, y, d).
  /// Every value is base64url or plain ASCII, so nothing needs escaping.
  public var encoded: String {
    "{" + [("kty", kty), ("crv", crv), ("alg", alg), ("kid", kid), ("x", x), ("y", y), ("d", d)]
      .map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",") + "}"
  }
}

/// A new live channel key ([LiveSigningKey]).
public func newLiveSigningKey() -> LiveSigningKey {
  let key = P256.Signing.PrivateKey()
  // 04 || x || y.
  let point = key.publicKey.x963Representation
  func b64(_ d: Data) -> String { base64UrlEncode(d, padding: false) }
  let kid = randomBytes(16).map { String(format: "%02x", $0) }.joined()
  func cut(_ from: Int, _ to: Int) -> Substring {
    kid[kid.index(kid.startIndex, offsetBy: from)..<kid.index(kid.startIndex, offsetBy: to)]
  }
  return LiveSigningKey(
    kty: "EC", crv: "P-256", alg: "ES256",
    kid: "\(cut(0, 8))-\(cut(8, 12))-4\(cut(13, 16))-a\(cut(17, 20))-\(cut(20, 32))",
    x: b64(point.subdata(in: 1..<33)), y: b64(point.subdata(in: 33..<65)), d: b64(key.rawRepresentation))
}

func randomBytes(_ count: Int) -> Data {
  var g = SystemRandomNumberGenerator()
  return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
}

/// A setup token: 32 random bytes, base64url without padding (43 characters).
public func newSetupToken() -> String { base64UrlEncode(randomBytes(32), padding: false) }

/// 32 random letters and digits: a new project's database password, which PocketTerm never needs again.
public func newDatabasePassword() -> String {
  let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
  var g = SystemRandomNumberGenerator()
  return String((0..<32).map { _ in chars.randomElement(using: &g)! })
}

/// The regions a new project can go to, nearest-sounding names for people, in the order the setup lists them.
public let supabaseRegions: KeyValuePairs<String, String> = [
  "us-east-1": "US East (N. Virginia)",
  "us-west-1": "US West (N. California)",
  "ca-central-1": "Canada (Central)",
  "sa-east-1": "South America (São Paulo)",
  "eu-central-1": "Europe (Frankfurt)",
  "eu-west-2": "Europe (London)",
  "ap-south-1": "Asia Pacific (Mumbai)",
  "ap-southeast-1": "Asia Pacific (Singapore)",
  "ap-northeast-1": "Asia Pacific (Tokyo)",
]

/// Where the person makes a personal access token.
public let supabaseTokensPage = URL(string: "https://supabase.com/dashboard/account/tokens")!

public enum SupabaseStep: String, Sendable, CaseIterable {
  case project, database, liveChannel, function, signIn

  public var label: String {
    switch self {
    case .project: "Starting the project"
    case .database: "Database"
    case .liveChannel: "Live channel key"
    case .function: "Server function"
    case .signIn: "Signing this computer in"
    }
  }
}

/// What the Supabase setup talks to: the Management API with the pasted access token, and the setup of one project.
/// Tests pass their own.
public struct SupabaseTools: Sendable {
  public init(
    admin: (@Sendable (String) -> SupabaseAdmin)? = nil,
    setup: (@Sendable (SupabaseAdmin, String) -> SupabaseSetup)? = nil
  ) {
    self.admin = admin ?? { SupabaseAdmin($0) }
    self.setup = setup ?? { SupabaseSetup(admin: $0, ref: $1) }
  }

  public let admin: @Sendable (String) -> SupabaseAdmin
  public let setup: @Sendable (SupabaseAdmin, String) -> SupabaseSetup

  /// The healthy project of organization [org] PocketTerm is on already, if any (best effort: one that can't be
  /// asked counts as not).
  public func existingProject(_ admin: SupabaseAdmin, org: String) async -> SupabaseProject? {
    do {
      for p in try await admin.projects() where p.org == org && p.status == "ACTIVE_HEALTHY" {
        do {
          if try await setup(admin, p.ref).hasPocketTerm() { return p }
        } catch {
          debugLog("PocketTerm: looking at Supabase project \(p.ref) failed: \(error)")
        }
      }
    } catch {
      debugLog("PocketTerm: listing Supabase projects failed: \(error)")
    }
    return nil
  }
}

/// Puts PocketTerm on a Supabase project (or updates it there): the migrations, the live channel's signing key, the
/// Edge Function, and a setup token for this computer. Every step can run again: applied migrations are skipped, a
/// project that has its live channel key keeps it, the function is deployed anew.
public final class SupabaseSetup: Sendable {
  public init(
    admin: SupabaseAdmin,
    ref: String,
    source: any SupabaseSource = BundledSupabaseSource(),
    poll: TimeInterval = 3,
    schemaWait: TimeInterval = 180,
    keyWait: TimeInterval = 480,
    wakeRealtime: (@Sendable (SupabaseSetup) async throws -> Void)? = nil,
    health: (@Sendable (Backend) async -> String?)? = nil
  ) {
    self.admin = admin
    self.ref = ref
    self.source = source
    self.poll = poll
    self.schemaWait = schemaWait
    self.keyWait = keyWait
    self.wakeRealtime = wakeRealtime ?? SupabaseSetup.connectRealtime
    self.health = health ?? { await $0.check() }
  }

  public let admin: SupabaseAdmin
  public let ref: String
  public let source: any SupabaseSource

  /// How often waits look again, in seconds.
  public let poll: TimeInterval

  /// A new project says it's healthy before Realtime and Storage have made their tables, which the migrations add
  /// to. Realtime makes `realtime.messages` only once a client first connects, so [migrate] connects
  /// ([wakeRealtime]) and waits up to this long.
  public let schemaWait: TimeInterval

  /// How long [liveChannel] waits for Supabase to take a new signing key: it allows a signing key change only every
  /// few minutes.
  public let keyWait: TimeInterval

  public let wakeRealtime: @Sendable (SupabaseSetup) async throws -> Void

  /// The function's GET /v1/health once deployed (nil: it answers).
  public let health: @Sendable (Backend) async -> String?

  public var url: String { "https://\(ref).supabase.co" }

  public var backend: Backend { Backend(url: url, kind: .supabase) }

  private func sleep(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
  }

  private static let connectRealtime: @Sendable (SupabaseSetup) async throws -> Void = { s in
    let key = try await s.admin.publishableKey(s.ref)
    let url = URL(
      string:
        "wss://\(s.ref).supabase.co/realtime/v1/websocket?apikey=\(encodeQueryComponent(key))&vsn=1.0.0")!
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let ws = session.webSocketTask(with: url)
    ws.resume()
    defer { ws.cancel(with: .normalClosure, reason: nil) }
    let join = JSON.object([
      "topic": "realtime:pocketterm-setup", "event": "phx_join", "payload": .object([:]), "ref": "1",
    ]).encoded()
    let answered = await withDeadline(15, fallback: false) {
      do {
        try await ws.send(.string(join))
        _ = try await ws.receive()
        return true
      } catch {
        return false
      }
    }
    if !answered { throw AdminException("Realtime didn't answer.") }
  }

  /// Whether PocketTerm is on this project already (an update).
  public func hasPocketTerm() async throws -> Bool {
    try await admin.query(ref, "select to_regnamespace('pocketterm') is not null as ours").first?["ours"]
      == .bool(true)
  }

  /// Applies the migrations the project hasn't had yet, each in its own transaction, recorded where the Supabase
  /// CLI keeps them. How many.
  @discardableResult
  public func migrate() async throws -> Int {
    try await waitForSchemas()
    _ = try await admin.query(
      ref,
      "create schema if not exists supabase_migrations;\n"
        + "create table if not exists supabase_migrations.schema_migrations "
        + "(version text primary key, statements text[], name text);")
    let applied = Set(
      try await admin.query(ref, "select version from supabase_migrations.schema_migrations").compactMap {
        $0["version"]?.string
      })
    var count = 0
    for m in try await source.migrations() where !applied.contains(m.version) {
      _ = try await admin.query(
        ref,
        "begin;\n\(m.sql)\n;\n"
          + "insert into supabase_migrations.schema_migrations (version, name) "
          + "values ('\(m.version)', '\(m.name.replacingOccurrences(of: "'", with: "''"))');\ncommit;")
      count += 1
    }
    return count
  }

  private func waitForSchemas() async throws {
    let deadline = Date().addingTimeInterval(schemaWait)
    var woken = false
    while true {
      let r = try await admin.query(
        ref,
        "select to_regclass('realtime.messages') is not null and to_regclass('storage.buckets') is not null as ready")
      if r.first?["ready"] == .bool(true) { return }
      if Date() > deadline {
        throw AdminException("Supabase is still starting the project. Wait a minute, then retry.")
      }
      if !woken {
        woken = true
        do {
          try await wakeRealtime(self)
        } catch {
          debugLog("PocketTerm: waking Realtime failed: \(error)")
        }
      }
      await sleep(poll)
    }
  }

  /// The live channel's key: a new ES256 key, imported as the project's JWT signing key and put to use (Realtime
  /// then takes tokens it signs), and given to the function as its secret PT_REALTIME_JWK with the publishable key
  /// (PT_PUBLISHABLE_KEY). Realtime takes private channels only. A project that has its key already keeps it.
  /// [onWait] hears when Supabase makes it wait (a signing key changes every few minutes at most).
  public func liveChannel(onWait: (@Sendable () -> Void)? = nil) async throws {
    let secrets = try await admin.secretNames(ref)
    if !secrets.contains("PT_REALTIME_JWK") {
      let jwk = newLiveSigningKey()
      // A standby key the project made itself would refuse a second one; it never signed anything.
      for k in try await admin.signingKeys(ref) where k["status"]?.string == "standby" {
        if let id = k["id"]?.string { try await admin.setSigningKeyStatus(ref, id, "previously_used") }
      }
      let id = try await admin.addSigningKey(ref, jwk)
      let deadline = Date().addingTimeInterval(keyWait)
      var told = false
      while true {
        do {
          try await admin.setSigningKeyStatus(ref, id, "in_use")
          break
        } catch let e as AdminException {
          if Date() > deadline || e.status == 401 || e.status == 403 { throw e }
          debugLog("PocketTerm: signing key not in use yet: \(e)")
          if !told { onWait?() }
          told = true
          await sleep(poll * 10)
        }
      }
      try await admin.setSecrets(ref, ["PT_REALTIME_JWK": jwk.encoded])
    }
    try await admin.setSecrets(ref, ["PT_PUBLISHABLE_KEY": try await admin.publishableKey(ref)])
    do {
      try await admin.realtimePrivateOnly(ref)
    } catch let e as AdminException {
      // Every channel PocketTerm opens is private anyway.
      debugLog("PocketTerm: Realtime private-only not set: \(e)")
    }
  }

  /// Deploys the function and waits for it to answer.
  public func deploy() async throws {
    try await admin.deployFunction(ref, "pocketterm", try await source.function(), verifyJwt: false)
    var problem: String?
    for _ in 0..<20 {
      problem = await health(backend)
      if problem == nil { return }
      await sleep(poll)
    }
    throw AdminException("The PocketTerm function on Supabase doesn’t answer yet: \(problem ?? "")")
  }

  /// A new setup token for this project (only its SHA-256 goes there); the link this computer signs in with. The
  /// one before stops working.
  public func setupLink() async throws -> URL {
    let token = newSetupToken()
    let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    _ = try await admin.query(ref, "select pocketterm.set_setup_hash('\(hash)')")
    return backend.linkWithSetup(token)
  }

  /// Everything, in order; [onStep] hears each step as it starts, [onWait] when Supabase makes the live channel key
  /// wait. Steps in [done] are skipped (a retry picks up where it stopped). The setup link this computer signs in
  /// with.
  public func run(
    onStep: (@Sendable (SupabaseStep) -> Void)? = nil, onWait: (@Sendable () -> Void)? = nil,
    done: Set<SupabaseStep> = []
  ) async throws -> URL {
    func step(_ s: SupabaseStep, _ work: () async throws -> Void) async throws {
      if done.contains(s) { return }
      onStep?(s)
      try await work()
    }
    let poll = poll
    try await step(.project) { _ = try await admin.waitUntilReady(ref, poll: poll) }
    try await step(.database) { try await migrate() }
    try await step(.liveChannel) { try await liveChannel(onWait: onWait) }
    try await step(.function) { try await deploy() }
    onStep?(.signIn)
    return try await setupLink()
  }
}
#endif
