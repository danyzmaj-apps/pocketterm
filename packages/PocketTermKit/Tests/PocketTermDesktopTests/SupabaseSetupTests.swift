#if os(macOS)
import CryptoKit
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

/// The Management API of one Supabase account, in memory: two organizations, projects as created, SQL answered by
/// what it asks.
final class SupaFakeSupabase: @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [String] = []
  private var _bodies: [String: [Data]] = [:]

  /// Every request, `METHOD /path`.
  var requests: [String] { lock.withLock { _requests } }

  /// The bodies sent with [request] (`METHOD /path`).
  func bodies(_ request: String) -> [Data] { lock.withLock { _bodies[request] ?? [] } }

  var projects: [JSONObject] = [
    ["id": "hopjarref0000000", "name": "hopjar", "status": "ACTIVE_HEALTHY", "organization_id": "org-work"]
  ]

  /// Projects PocketTerm is on already.
  var ours: Set<String> = []

  /// Migrations the project has already.
  var applied: [String] = []

  /// What the next deploy answers with, once: a status and a message.
  var deployFails: (Int, String)?

  /// Times the signing key is refused before it's taken (Supabase's wait).
  var keyRefusals = 0
  private var keyTries = 0

  /// While true, POST /v1/projects is refused for the free plan's limit.
  var atLimit = false

  /// How many [requests] were [request] (`METHOD /path`).
  func count(_ request: String) -> Int { requests.filter { $0 == request }.count }

  lazy var transport: AdminTransport = { [unowned self] request, _ in self.answer(request) }

  private func answer(_ req: URLRequest) -> (Data, Int) {
    lock.lock()
    defer { lock.unlock() }
    let path = req.url!.path
    let method = req.httpMethod ?? "GET"
    _requests.append("\(method) \(path)")
    _bodies["\(method) \(path)", default: []].append(req.httpBody ?? Data())
    func json(_ body: JSON, _ status: Int = 200) -> (Data, Int) { (body.encodedData(), status) }
    let body = req.httpBody.flatMap { JSON.tryParse($0) }
    switch (method, path) {
    case ("GET", "/v1/organizations"):
      return json([["slug": "org-mine", "name": "Mine", "plan": "free"], ["slug": "org-work", "name": "Work", "plan": "pro"]])
    case ("GET", "/v1/projects"):
      return json(.array(projects.map(JSON.object)))
    case ("POST", "/v1/projects") where atLimit:
      return json(["message": "The maximum limit of 2 free projects has been reached"], 400)
    case ("POST", "/v1/projects"):
      let p: JSONObject = [
        "id": "newproject000000", "name": body?["name"] ?? .null, "status": "COMING_UP",
        "organization_id": body?["organization_slug"] ?? .null,
      ]
      projects.append(p)
      return json(.object(p), 201)
    default: break
    }
    let parts = path.components(separatedBy: "/")
    if parts.count >= 4 && parts[2] == "projects", let i = projects.firstIndex(where: { $0["id"]?.string == parts[3] }) {
      let ref = parts[3]
      switch (method, parts.dropFirst(4).joined(separator: "/")) {
      case ("GET", ""):
        projects[i]["status"] = "ACTIVE_HEALTHY"
        return json(.object(projects[i]))
      case ("POST", "database/query"):
        let sql = body?["query"]?.string ?? ""
        if sql.contains("to_regnamespace") { return json([["ours": .bool(ours.contains(ref))]]) }
        if sql.contains("to_regclass('realtime.messages')") { return json([["ready": true]]) }
        if sql.contains("select version from") { return json(.array(applied.map { ["version": .string($0)] })) }
        return json([])
      case ("GET", "secrets"): return json([])
      case ("POST", "secrets"): return json([:])
      case ("GET", "config/auth/signing-keys"): return json(["keys": []])
      case ("POST", "config/auth/signing-keys"): return json(["id": "key-1"], 201)
      case ("PATCH", "config/auth/signing-keys/key-1"):
        keyTries += 1
        if keyTries <= keyRefusals { return json(["message": "Wait before rotating again"], 400) }
        return json([:])
      case ("GET", "api-keys"): return json([["type": "publishable", "api_key": "sb_publishable_test"]])
      case ("PATCH", "config/realtime"): return json([:])
      case ("POST", "functions/deploy"):
        if let (status, message) = deployFails {
          deployFails = nil
          return json(["message": .string(message)], status)
        }
        return json(["id": "fn"], 201)
      default: break
      }
    }
    return json(["message": "Not found"], 404)
  }
}

struct SupaSource: SupabaseSource {
  func migrations() async throws -> [Migration] {
    [Migration(version: "20261023000000", name: "pocketterm", sql: "select 1")]
  }
  func function() async throws -> String { "Deno.serve(() => new Response(\"ok\"));" }
}

/// Counts what a callback heard, from any thread.
final class SupaHeard: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ s: String) { lock.withLock { items.append(s) } }
  var all: [String] { lock.withLock { items } }
}

final class SupabaseSetupTests: XCTestCase {
  private func tools(_ fake: SupaFakeSupabase) -> SupabaseTools {
    SupabaseTools(
      admin: { SupabaseAdmin($0, transport: fake.transport) },
      setup: { admin, ref in
        SupabaseSetup(
          admin: admin, ref: ref, source: SupaSource(), poll: 0, wakeRealtime: { _ in }, health: { _ in nil })
      })
  }

  func testANewProjectInThePickedOrganizationAndRegionIsSetUpStepByStep() async throws {
    let fake = SupaFakeSupabase()
    fake.keyRefusals = 2
    let tools = tools(fake)
    let admin = tools.admin("sbp_secret")
    let orgs = try await admin.organizations()
    XCTAssertEqual(orgs.map(\.slug), ["org-mine", "org-work"])
    XCTAssertEqual(orgs[1].plan, "pro")
    // Another project there isn't PocketTerm's: it's only asked about, never offered.
    let existing = await tools.existingProject(admin, org: "org-work")
    XCTAssertNil(existing)
    XCTAssertEqual(fake.count("POST /v1/projects/hopjarref0000000/database/query"), 1)

    let password = newDatabasePassword()
    let project = try await admin.createProject(org: "org-work", name: "PocketTerm", region: "eu-west-2", dbPassword: password)
    XCTAssertEqual(project.ref, "newproject000000")
    let created = try JSON.parse(fake.bodies("POST /v1/projects").first!)
    XCTAssertEqual(
      created,
      [
        "organization_slug": "org-work", "name": "PocketTerm", "db_pass": .string(password),
        "region_selection": ["type": "specific", "code": "eu-west-2"],
      ])
    XCTAssertEqual(password.count, 32)
    XCTAssertNotNil(password.range(of: "^[a-zA-Z0-9]{32}$", options: .regularExpression))

    let steps = SupaHeard()
    let waits = SupaHeard()
    let link = try await tools.setup(admin, project.ref).run(
      onStep: { steps.add($0.rawValue) }, onWait: { waits.add("wait") })
    XCTAssertEqual(steps.all, ["project", "database", "liveChannel", "function", "signIn"])
    // Supabase made the signing key wait: said once.
    XCTAssertEqual(waits.all, ["wait"])
    XCTAssertEqual(Backend.fromLink(link), Backend(url: "https://newproject000000.supabase.co", kind: .supabase))
    let token = try XCTUnwrap(Backend.setupToken(link))
    XCTAssertEqual(token.count, 43)
    XCTAssertEqual(fake.count("POST /v1/projects/newproject000000/functions/deploy"), 1)

    // Only the token's SHA-256 went to the project.
    let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    let queries = fake.bodies("POST /v1/projects/newproject000000/database/query").compactMap {
      JSON.tryParse($0)?["query"]?.string
    }
    XCTAssertEqual(queries.last, "select pocketterm.set_setup_hash('\(hash)')")
    XCTAssertTrue(queries.contains { $0.contains("values ('20261023000000', 'pocketterm');\ncommit;") })

    // The function's secrets: the live channel key as Dart encoded it, then the publishable key.
    let secrets = fake.bodies("POST /v1/projects/newproject000000/secrets").compactMap { JSON.tryParse($0) }
    XCTAssertEqual(secrets.count, 2)
    XCTAssertEqual(secrets[0][0]?["name"], "PT_REALTIME_JWK")
    let jwkText = try XCTUnwrap(secrets[0][0]?["value"]?.string)
    XCTAssertTrue(jwkText.hasPrefix("{\"kty\":\"EC\",\"crv\":\"P-256\",\"alg\":\"ES256\",\"kid\":\""))
    XCTAssertEqual(secrets[1], [["name": "PT_PUBLISHABLE_KEY", "value": "sb_publishable_test"]])
    let imported = try JSON.parse(fake.bodies("POST /v1/projects/newproject000000/config/auth/signing-keys")[0])
    XCTAssertEqual(imported["algorithm"], "ES256")
    XCTAssertEqual(imported["private_jwk"], try JSON.parse(jwkText))
    XCTAssertEqual(fake.count("PATCH /v1/projects/newproject000000/config/realtime"), 1)

    // The deploy: the source as index.ts, its metadata as the setup sends it.
    let deploy = String(decoding: fake.bodies("POST /v1/projects/newproject000000/functions/deploy")[0], as: UTF8.self)
    XCTAssertTrue(deploy.contains(#"{"entrypoint_path":"index.ts","name":"pocketterm","verify_jwt":false}"#))
    XCTAssertTrue(deploy.contains("filename=\"index.ts\"\r\n\r\nDeno.serve(() => new Response(\"ok\"));\r\n"))
  }

  func testASupabaseErrorShowsItsMessageAndRetryPicksUpAtTheStepThatFailed() async throws {
    let fake = SupaFakeSupabase()
    fake.deployFails = (500, "Bundling the function failed.")
    let tools = tools(fake)
    let admin = tools.admin("sbp_secret")
    let project = try await admin.createProject(org: "org-mine", name: "PocketTerm", region: "us-east-1", dbPassword: "x")
    let steps = SupaHeard()
    do {
      _ = try await tools.setup(admin, project.ref).run(onStep: { steps.add($0.rawValue) })
      XCTFail("didn't fail")
    } catch let e as AdminException {
      XCTAssertEqual(e.message, "Bundling the function failed.")
      XCTAssertEqual(e.status, 500)
    }
    XCTAssertEqual(steps.all.last, "function")

    // Nothing done before runs again: one project, one migration, one signing key.
    let link = try await tools.setup(admin, project.ref).run(done: [.project, .database, .liveChannel])
    XCTAssertTrue(Backend.fromLink(link)!.isSupabase)
    XCTAssertEqual(fake.count("POST /v1/projects"), 1)
    XCTAssertEqual(fake.count("POST /v1/projects/newproject000000/config/auth/signing-keys"), 1)
    XCTAssertEqual(fake.count("POST /v1/projects/newproject000000/functions/deploy"), 2)
  }

  func testAProjectSupabaseWontCreateSaysWhy() async throws {
    let fake = SupaFakeSupabase()
    fake.atLimit = true
    let admin = tools(fake).admin("sbp_secret")
    do {
      _ = try await admin.createProject(org: "org-mine", name: "PocketTerm", region: "us-east-1", dbPassword: "x")
      XCTFail("created")
    } catch let e as AdminException {
      XCTAssertTrue(e.message.contains("already has the two active projects the free plan allows"))
      XCTAssertEqual(e.status, 400)
    }
    fake.atLimit = false
    _ = try await admin.createProject(org: "org-mine", name: "PocketTerm", region: "us-east-1", dbPassword: "x")
    XCTAssertEqual(fake.count("POST /v1/projects"), 2)
  }

  func testAnOrganizationPocketTermIsOnAlreadyOffersThatProject() async throws {
    let fake = SupaFakeSupabase()
    fake.projects.append([
      "id": "oldpocketterm000", "name": "PocketTerm", "status": "ACTIVE_HEALTHY", "organization_id": "org-mine",
    ])
    fake.ours.insert("oldpocketterm000")
    fake.applied = ["20261023000000"]
    let tools = tools(fake)
    let admin = tools.admin("sbp_secret")
    let existing = await tools.existingProject(admin, org: "org-mine")
    XCTAssertEqual(existing?.ref, "oldpocketterm000")
    let setup = tools.setup(admin, "oldpocketterm000")
    let hasIt = try await setup.hasPocketTerm()
    XCTAssertTrue(hasIt)
    // Its migration is there already: none runs again.
    let applied = try await setup.migrate()
    XCTAssertEqual(applied, 0)
    let link = try await setup.run()
    XCTAssertEqual(Backend.fromLink(link)?.url, "https://oldpocketterm000.supabase.co")
    XCTAssertEqual(fake.count("POST /v1/projects"), 0)
  }

  func testSupabasesRefusalsAreWordedForThePerson() {
    func message(_ status: Int, _ body: String) -> String? {
      do {
        _ = try SupabaseAdmin.decode((Data(body.utf8), status))
        return nil
      } catch {
        return (error as? AdminException)?.message
      }
    }
    XCTAssertEqual(message(401, "{}"), "Supabase refused that access token. Create a new one and paste it again.")
    XCTAssertEqual(message(403, #"{"message":"Forbidden resource"}"#), "That access token isn't allowed to do this: Forbidden resource")
    XCTAssertEqual(message(403, ""), "That access token isn't allowed to do this")
    XCTAssertEqual(message(429, "{}"), "Supabase is rate-limiting requests. Wait a minute, then retry.")
    XCTAssertEqual(message(500, "oops"), "oops")
    XCTAssertEqual(message(502, ""), "Supabase answered with an error (502).")
    XCTAssertEqual(message(400, #"{"msg":"bad"}"#), "bad")
    XCTAssertNil(message(200, "[]"))
  }

  func testUnreachableAndSlowSupabaseSaySo() async {
    let offline = SupabaseAdmin("t", transport: { _, _ in throw URLError(.notConnectedToInternet) })
    do {
      _ = try await offline.organizations()
      XCTFail()
    } catch {
      XCTAssertEqual((error as? AdminException)?.message, "Couldn't reach Supabase. Check your connection.")
    }
    let slow = SupabaseAdmin("t", transport: { _, _ in throw TransportTimeout() })
    do {
      try await slow.deployFunction("ref", "pocketterm", "", verifyJwt: false)
      XCTFail()
    } catch {
      XCTAssertEqual((error as? AdminException)?.message, "Deploying pocketterm took too long. Retry.")
    }
  }

  func testTheLiveChannelKeyIsAP256KeyPairItsKidAUuid() throws {
    let jwk = newLiveSigningKey()
    XCTAssertEqual([jwk.kty, jwk.crv, jwk.alg], ["EC", "P-256", "ES256"])
    func bytes(_ s: String) -> Data {
      var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      while b.count % 4 != 0 { b += "=" }
      return Data(base64Encoded: b)!
    }
    let (x, y, d) = (bytes(jwk.x), bytes(jwk.y), bytes(jwk.d))
    XCTAssertEqual([x.count, y.count, d.count], [32, 32, 32])
    // x and y are d·G.
    let key = try P256.Signing.PrivateKey(rawRepresentation: d)
    XCTAssertEqual(key.publicKey.x963Representation, Data([4]) + x + y)
    XCTAssertNotNil(
      jwk.kid.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
    XCTAssertNotEqual(newLiveSigningKey().kid, jwk.kid)
    XCTAssertEqual(try JSON.parse(jwk.encoded), jwk.json)
  }

  func testMigrationsAreReadFromTheirFileNames() {
    XCTAssertEqual(
      migrationFromFile("supabase/migrations/20261023000000_pocketterm.sql", "x"),
      Migration(version: "20261023000000", name: "pocketterm", sql: "x"))
    XCTAssertEqual(
      migrationFromFile("20261024000000_activity_refresh.sql", ""),
      Migration(version: "20261024000000", name: "activity_refresh", sql: ""))
    XCTAssertEqual(migrationFromFile("plain.sql", ""), Migration(version: "plain", name: "", sql: ""))
  }

  func testTheBundledFilesAreTheRepositorysSupabaseFolder() async throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "../../../../apps/pocketterm-desktop/supabase"
    ).standardized
    let source = BundledSupabaseSource(directory: dir)
    let migrations = try await source.migrations()
    XCTAssertEqual(migrations.first?.version, "20261023000000")
    XCTAssertEqual(migrations.map(\.version), migrations.map(\.version).sorted())
    XCTAssertFalse(migrations.contains { $0.sql.isEmpty })
    let function = try await source.function()
    XCTAssertFalse(function.isEmpty)
  }

  func testStepsAndRegionsAsTheSetupShowsThem() {
    XCTAssertEqual(SupabaseStep.allCases.map(\.label), [
      "Starting the project", "Database", "Live channel key", "Server function", "Signing this computer in",
    ])
    XCTAssertEqual(supabaseRegions.count, 9)
    XCTAssertEqual(supabaseRegions[5].key, "eu-west-2")
    XCTAssertEqual(supabaseRegions[5].value, "Europe (London)")
  }
}
#endif
