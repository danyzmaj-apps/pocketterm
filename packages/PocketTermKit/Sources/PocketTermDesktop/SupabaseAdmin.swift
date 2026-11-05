#if os(macOS)
import Foundation
import PocketTermKit

/// What went wrong talking to Supabase, worded for the person setting up.
public struct AdminException: Error, Sendable, Equatable, CustomStringConvertible {
  public init(_ message: String, status: Int? = nil) {
    self.message = message
    self.status = status
  }
  public let message: String
  public let status: Int?
  public var description: String { message }
}

public struct SupabaseOrg: Sendable, Equatable {
  public let slug: String
  public let name: String
  public let plan: String
}

public struct SupabaseProject: Sendable, Equatable {
  public let ref: String
  public let name: String
  public let status: String
  public let region: String
  public let org: String
}

/// Sends a request and gives its body and status; tests hand in a fake (Dart's http.Client). Throws
/// [TransportTimeout] when the answer takes too long, anything else when Supabase can't be reached.
public typealias AdminTransport = @Sendable (_ request: URLRequest, _ timeout: TimeInterval) async throws -> (
  Data, Int
)

/// The request took longer than its time limit.
public struct TransportTimeout: Error, Sendable {}

/// The Supabase Management API (api.supabase.com), with the personal access token the person pasted in the setup.
/// Only the calls the setup needs. The token is never stored: it lives as long as this object.
public final class SupabaseAdmin: Sendable {
  public init(_ token: String, transport: AdminTransport? = nil, base: URL? = nil) {
    self.token = token
    self.transport = transport ?? SupabaseAdmin.urlSession
    self.base = base ?? URL(string: "https://api.supabase.com")!
  }

  private let token: String
  private let transport: AdminTransport
  private let base: URL

  /// No connection is held between requests; kept for the callers that close it as Dart's did.
  public func close() {}

  private static let urlSession: AdminTransport = { request, timeout in
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let task = Task { try await session.data(for: request) }
    let result: (Data, URLResponse)? = try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
      group.addTask { try await task.value }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return nil
      }
      let first = try await group.next()!
      group.cancelAll()
      return first
    }
    guard let (data, response) = result else {
      task.cancel()
      throw TransportTimeout()
    }
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  private func url(_ path: String, query: [(String, String)]? = nil) -> URL {
    var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    c.path = path
    if let query { c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
    return c.url!
  }

  private func list(_ path: String, query: [(String, String)]? = nil) async throws -> [JSONObject] {
    let json = try await send("GET", path, query: query)
    let items = json?["keys"]?.array ?? json?.array ?? []
    return items.compactMap(\.object)
  }

  private func map(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSONObject {
    guard let o = try await send(method, path, body: body)?.object else {
      throw AdminException("Supabase sent an unexpected answer.")
    }
    return o
  }

  @discardableResult
  private func send(_ method: String, _ path: String, body: JSON? = nil, query: [(String, String)]? = nil)
    async throws -> JSON?
  {
    var req = URLRequest(url: url(path, query: query))
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    if let body { req.httpBody = body.encodedData() }
    return try SupabaseAdmin.decode(try await exchange(req, timeout: 60) {
      AdminException("Supabase took too long to answer. Try again.")
    })
  }

  private func exchange(_ req: URLRequest, timeout: TimeInterval, tooLong: () -> AdminException) async throws -> (
    Data, Int
  ) {
    do {
      return try await transport(req, timeout)
    } catch is TransportTimeout {
      throw tooLong()
    } catch {
      throw AdminException("Couldn't reach Supabase. Check your connection.")
    }
  }

  static func decode(_ res: (Data, Int)) throws -> JSON? {
    let (data, status) = res
    let text = String(decoding: data, as: UTF8.self)
    let json = text.isEmpty ? nil : JSON.tryParse(data)
    if status >= 200 && status < 300 { return json }
    var detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let o = json?.object {
      let said = [o["message"], o["msg"], o["error"]].compactMap { $0 }.first { $0 != .null }
      detail = said.map { $0.string ?? $0.encoded() } ?? ""
    }
    let message =
      switch status {
      case 401: "Supabase refused that access token. Create a new one and paste it again."
      case 403: "That access token isn't allowed to do this\(detail.isEmpty ? "" : ": \(detail)")"
      case 429: "Supabase is rate-limiting requests. Wait a minute, then retry."
      default: detail.isEmpty ? "Supabase answered with an error (\(status))." : detail
      }
    throw AdminException(message, status: status)
  }

  private static func project(_ p: JSONObject) -> SupabaseProject {
    SupabaseProject(
      ref: p["id"]?.string ?? p["ref"]?.string ?? "",
      name: p["name"]?.string ?? "",
      status: p["status"]?.string ?? "",
      region: p["region"]?.string ?? "",
      org: p["organization_slug"]?.string ?? p["organization_id"]?.string ?? "")
  }

  public func organizations() async throws -> [SupabaseOrg] {
    try await list("/v1/organizations").map {
      SupabaseOrg(
        slug: $0["slug"]?.string ?? $0["id"]?.string ?? "", name: $0["name"]?.string ?? "",
        plan: $0["plan"]?.string ?? "")
    }
  }

  /// The organization in full (its plan: `free`, `pro`, …).
  public func organization(_ slug: String) async throws -> SupabaseOrg {
    let o = try await map("GET", "/v1/organizations/\(slug)")
    return SupabaseOrg(
      slug: o["slug"]?.string ?? slug, name: o["name"]?.string ?? "", plan: o["plan"]?.string ?? "")
  }

  public func projects() async throws -> [SupabaseProject] {
    try await list("/v1/projects").map(SupabaseAdmin.project)
  }

  public func project(_ ref: String) async throws -> SupabaseProject {
    SupabaseAdmin.project(try await map("GET", "/v1/projects/\(ref)"))
  }

  /// A new project; it takes a minute or two to come up ([waitUntilReady]). [dbPassword] is the database's;
  /// PocketTerm never needs it again.
  public func createProject(org: String, name: String, region: String, dbPassword: String) async throws
    -> SupabaseProject
  {
    do {
      return SupabaseAdmin.project(
        try await map(
          "POST", "/v1/projects",
          body: [
            "organization_slug": .string(org),
            "name": .string(name),
            "db_pass": .string(dbPassword),
            "region_selection": ["type": "specific", "code": .string(region)],
          ]))
    } catch let e as AdminException {
      let m = e.message.lowercased()
      // 429 is "rate-limiting", not the plan.
      if e.status != 429 && (m.contains("limit") || m.contains("maximum")) {
        throw AdminException(
          "This Supabase account already has the two active projects the free plan allows. Pause or delete one "
            + "you don't need (at supabase.com/dashboard), or choose an organization on a paid plan, then try again.",
          status: e.status)
      }
      throw e
    }
  }

  /// Polls until the project is up, or fails after [timeout] seconds. False when the task is cancelled first
  /// (Dart's `stop`).
  public func waitUntilReady(_ ref: String, timeout: TimeInterval = 360, poll: TimeInterval = 5) async throws
    -> Bool
  {
    let end = Date().addingTimeInterval(timeout)
    while !Task.isCancelled {
      let status = try await project(ref).status
      if Task.isCancelled { break }
      if status == "ACTIVE_HEALTHY" { return true }
      if status.contains("FAILED") || status == "INACTIVE" || status == "PAUSED" {
        throw AdminException("The project is \(status). Restore it in the Supabase dashboard, then retry.")
      }
      if Date() >= end {
        throw AdminException("The project is still starting. Give it another minute, then continue.")
      }
      try? await Task.sleep(nanoseconds: UInt64(max(0, poll) * 1_000_000_000))
    }
    return false
  }

  /// Runs SQL as the database owner; the rows of the last statement.
  public func query(_ ref: String, _ sql: String) async throws -> [JSONObject] {
    let rows = try await send("POST", "/v1/projects/\(ref)/database/query", body: ["query": .string(sql)])
    return (rows?.array ?? []).compactMap(\.object)
  }

  /// The key apps use: the publishable one, else the legacy anon key.
  public func publishableKey(_ ref: String) async throws -> String {
    let keys = try await list("/v1/projects/\(ref)/api-keys", query: [("reveal", "false")])
    let key =
      keys.first { $0["type"]?.string == "publishable" }?["api_key"]?.string
      ?? keys.first { $0["name"]?.string == "anon" }?["api_key"]?.string
    guard let key else { throw AdminException("The project has no publishable key. Create one under API Keys.") }
    return key
  }

  /// The project's JWT signing keys: `id`, `algorithm`, `status` (`in_use`, `standby`, `previously_used`,
  /// `revoked`).
  public func signingKeys(_ ref: String) async throws -> [JSONObject] {
    try await list("/v1/projects/\(ref)/config/auth/signing-keys")
  }

  /// Imports [privateJwk] as a standby JWT signing key; its id.
  public func addSigningKey(_ ref: String, _ privateJwk: LiveSigningKey) async throws -> String {
    let key = try await map(
      "POST", "/v1/projects/\(ref)/config/auth/signing-keys",
      body: ["algorithm": .string(privateJwk.alg), "private_jwk": privateJwk.json])
    guard let id = key["id"]?.string else { throw AdminException("Supabase sent an unexpected answer.") }
    return id
  }

  /// Moves signing key [id] to [status] (`in_use` rotates to it).
  public func setSigningKeyStatus(_ ref: String, _ id: String, _ status: String) async throws {
    try await send("PATCH", "/v1/projects/\(ref)/config/auth/signing-keys/\(id)", body: ["status": .string(status)])
  }

  /// Sets the Edge Functions' secrets (replacing those of the same names), in the order given.
  public func setSecrets(_ ref: String, _ secrets: KeyValuePairs<String, String>) async throws {
    try await send(
      "POST", "/v1/projects/\(ref)/secrets",
      body: .array(secrets.map { ["name": .string($0.key), "value": .string($0.value)] }))
  }

  /// The names of the Edge Functions' secrets (their values never come back).
  public func secretNames(_ ref: String) async throws -> Set<String> {
    Set(try await list("/v1/projects/\(ref)/secrets").compactMap { $0["name"]?.string })
  }

  /// Realtime takes only private channels (every join checked against RLS).
  public func realtimePrivateOnly(_ ref: String) async throws {
    try await send("PATCH", "/v1/projects/\(ref)/config/realtime", body: ["private_only": true])
  }

  /// Deploys one Edge Function from its source; Supabase bundles it.
  public func deployFunction(_ ref: String, _ slug: String, _ source: String, verifyJwt: Bool) async throws {
    let boundary = "dart-http-boundary-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    var req = URLRequest(url: url("/v1/projects/\(ref)/functions/deploy", query: [("slug", slug)]))
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
    let metadata = JSON.object([
      "entrypoint_path": "index.ts", "name": .string(slug), "verify_jwt": .bool(verifyJwt),
    ]).encoded()
    var body = ""
    body += "--\(boundary)\r\ncontent-disposition: form-data; name=\"metadata\"\r\n\r\n\(metadata)\r\n"
    body += "--\(boundary)\r\ncontent-type: text/plain; charset=utf-8\r\n"
    body += "content-disposition: form-data; name=\"file\"; filename=\"index.ts\"\r\n\r\n\(source)\r\n"
    body += "--\(boundary)--\r\n"
    req.httpBody = Data(body.utf8)
    _ = try SupabaseAdmin.decode(try await exchange(req, timeout: 120) {
      AdminException("Deploying \(slug) took too long. Retry.")
    })
  }
}
#endif
