import Foundation

/// What a saved server's `backend_kind` said in an app from before: `supabase` for PocketTerm set up on a
/// Supabase project, which this app no longer speaks (a device signed in to one is signed out on launch).
public let supabaseKind = "supabase"

/// Where a device keeps its server: a computer in its preferences ([PreferencesBackendStore]), a phone
/// where its native side reads it too (the App Group on iOS, PocketTermShared.swift).
public protocol BackendStore: AnyObject, Sendable {
  /// The kept URL and the kind an app from before saved with it (`supabase`, or nil for a PocketTerm
  /// server); [legacy]: an older app saved a Supabase project there (it came with a key). Nil: none.
  func loadBackend() -> (url: String, kind: String?, legacy: Bool)?

  /// Keeps [url] (a PocketTerm server); a nil [url] forgets it. Either way any kind or key an app from
  /// before kept goes.
  func saveBackend(url: String?, kind: String?)
}

/// A computer keeps its server in its preferences under `backend_url` and `backend_kind`; an app from
/// before kept a Supabase project's key under `backend_key`.
public final class PreferencesBackendStore: BackendStore, @unchecked Sendable {
  public let prefs: PreferenceStore
  public init(_ prefs: PreferenceStore) { self.prefs = prefs }

  static let urlKey = "backend_url"
  static let kindKey = "backend_kind"
  static let oldKeyKey = "backend_key"

  public func loadBackend() -> (url: String, kind: String?, legacy: Bool)? {
    guard let url = prefs.string(Self.urlKey) else { return nil }
    return (url, prefs.string(Self.kindKey), prefs.contains(Self.oldKeyKey))
  }

  public func saveBackend(url: String?, kind: String?) {
    if let url {
      prefs.setString(Self.urlKey, url)
      if let kind { prefs.setString(Self.kindKey, kind) } else { prefs.remove(Self.kindKey) }
    } else {
      prefs.remove(Self.urlKey)
      prefs.remove(Self.kindKey)
    }
    prefs.remove(Self.oldKeyKey)
  }
}

/// The server this device connects through (packages/pocketterm_server/PROTOCOL.md): the one built into a
/// computer's app, reached through Tailscale. A computer signs in with the server's setup link
/// (`pocketterm://setup?url=…&setup=…`, made by another computer's Add a computer…); a phone with a
/// computer's code, a setup link with a pairing code and that computer's key in it
/// (`pocketterm://setup?url=…&code=…&d=…&k=…`).
public struct Backend: Sendable, Hashable {
  public init(url: String) {
    self.url = url
  }

  /// The server's public URL, `https://my-mac.tail1234.ts.net`, without a trailing slash.
  public let url: String

  /// Where the REST paths of PROTOCOL.md start (`<api>/v1/health`, …).
  public var api: String { url }

  /// [url] as typed, or a reason it can't be used.
  public static func parse(_ url: String) -> (backend: Backend?, error: String?) {
    var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while u.hasSuffix("/") { u.removeLast() }
    // The API's own path works too.
    u = replaceFirst(u, #"/v1$"#, with: "")
    let uri = DartUri(u)
    guard !u.isEmpty, let uri, uri.scheme != nil, !uri.host.isEmpty else {
      return (nil, "Enter your server URL, like https://pocketterm.example.com.")
    }
    if uri.scheme != "https" && !(uri.scheme == "http" && isThisMachine(uri.host)) {
      return (nil, "The server URL must start with https://.")
    }
    if !uri.path.isEmpty || uri.query != nil || uri.fragment != nil {
      return (nil, "Use the server URL alone, without a path.")
    }
    return (Backend(url: u), nil)
  }

  /// A `pocketterm://setup?url=…` link (its pairing code, if any, is [pairingCode]'s; its setup token
  /// [setupToken]'s). A link carrying a `key` isn't one, nor one of a `kind` this app doesn't know (a
  /// Supabase project's, `kind=supabase`).
  public static func fromLink(_ link: URL) -> Backend? { fromLink(link.absoluteString) }

  public static func fromLink(_ link: String) -> Backend? {
    guard let uri = DartUri(link), uri.scheme == "pocketterm", uri.host == "setup" else { return nil }
    let q = uri.queryParameters
    if q["key"] != nil { return nil }
    switch q["kind"] {
    case nil, "", "pocketterm": break
    default: return nil
    }
    guard let url = q["url"] else { return nil }
    return parse(url).backend
  }

  /// The pairing code in a setup link (the computer's QR), if it has one: it signs a phone in.
  public static func pairingCode(_ link: URL) -> String? { param(link.absoluteString, "code") }
  public static func pairingCode(_ link: String) -> String? { param(link, "code") }

  /// The setup token in a server's setup link, if it has one: it signs a computer in.
  public static func setupToken(_ link: URL) -> String? { param(link.absoluteString, "setup") }
  public static func setupToken(_ link: String) -> String? { param(link, "setup") }

  private static func param(_ link: String, _ name: String) -> String? {
    guard fromLink(link) != nil, let uri = DartUri(link) else { return nil }
    let value = (uri.queryParameters[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// The computer and its channel key in a setup link (`d`, `k`: the computer's QR), if it has them. A
  /// link without them still signs in; that computer then stays locked on the phone.
  public static func computerKey(_ link: URL) -> ComputerKey? { computerKey(link.absoluteString) }

  public static func computerKey(_ link: String) -> ComputerKey? {
    guard fromLink(link) != nil, let uri = DartUri(link) else { return nil }
    let desktop = uri.queryParameters["d"] ?? ""
    guard let key = ChannelKey.tryParse(uri.queryParameters["k"]), isDesktopId(desktop) else { return nil }
    return ComputerKey(desktop: desktop, key: key)
  }

  private var whereParams: [(String, String)] { [("url", url)] }

  public var link: URL { setupLink(whereParams) }

  /// [link] with a computer's [setup] token: what signs another computer in. A secret: whoever has it can
  /// add a computer.
  public func linkWithSetup(_ setup: String) -> URL { setupLink(whereParams + [("setup", setup)]) }

  /// [link] with a pairing code and, from a computer, its [computer] key: what the computer's QR holds. A
  /// secret: whoever has it reads that computer's sessions.
  public func linkWithCode(_ code: String, computer: ComputerKey? = nil) -> URL {
    var params = whereParams + [("code", code)]
    if let computer { params += [("d", computer.desktop), ("k", computer.key.toBase64Url())] }
    return setupLink(params)
  }

  private func setupLink(_ params: [(String, String)]) -> URL {
    URL(string: "pocketterm://setup?" + params.map { "\(encodeQueryComponent($0))=\(encodeQueryComponent($1))" }
      .joined(separator: "&"))!
  }

  /// The host, for display.
  public var host: String { DartUri(url)?.host ?? "" }

  /// Reached through Tailscale (`tailscale serve` on a computer): only a device on that tailnet, with
  /// Tailscale on, can reach it.
  public var onTailnet: Bool { host.hasSuffix(".ts.net") }

  /// Why this device gets no answer from the server, worded for the person: a Tailscale address needs
  /// Tailscale on here.
  public var unreachable: String {
    onTailnet
      ? "Can't reach \(host). It's on your tailnet: open Tailscale on this device and connect."
      : "Can't reach \(host). Check your connection."
  }

  /// On this machine (`http://127.0.0.1:<port>`): the server built into this computer's app.
  public var onThisMachine: Bool { Self.isThisMachine(host) }

  /// Plain http only to this machine (a computer reaching the server built into it); everything else,
  /// Tailscale included (`tailscale serve` gives it a ts.net certificate), needs https.
  static func isThisMachine(_ host: String) -> Bool {
    host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
  }

  /// The protocol version this app speaks (GET /v1/health).
  public static let `protocol` = 1

  /// The oldest PocketTerm server this app works with (GET /v1/health's `version`).
  public static let minServer = "0.1.0"

  /// How far this device's clock may be off the server's before [clockWarning] speaks up, in seconds:
  /// each side drops sealed messages more than 5 minutes off its own clock, so two devices each within 2
  /// minutes stay within reach of each other.
  public static let clockTolerance: TimeInterval = 120

  /// Asks the server for its health: reachable, a PocketTerm server, one this app speaks to. Nil when all
  /// is well, else what's wrong.
  public func check() async -> String? { await health().error }

  /// GET /v1/health: `error` is nil when all is well, else what's wrong, worded for the person.
  /// `clockOffset` is how far the server's clock is ahead of this device's, in seconds (nil when it didn't
  /// say); see [clockWarning]. The answer has [wait] seconds to arrive.
  public func health(wait: TimeInterval = 10) async -> (error: String?, clockOffset: TimeInterval?) {
    func fail(_ error: String) -> (error: String?, clockOffset: TimeInterval?) { (error, nil) }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = wait
    config.timeoutIntervalForResource = wait * 2
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let redirects = RedirectCounter()
    let session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    guard let url = URL(string: "\(api)/v1/health") else { return fail(noServer) }
    let sent = Date()
    let data: Data
    let res: HTTPURLResponse
    do {
      let (d, r) = try await session.data(from: url)
      guard let h = r as? HTTPURLResponse else { return fail(noServer) }
      data = d
      res = h
    } catch let e as URLError {
      switch e.code {
      case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
        .clientCertificateRequired:
        return fail(
          "Couldn't make a secure connection to \(host): its HTTPS certificate isn't valid or isn't there yet. A "
            + "new server takes a minute to get one.")
      case .httpTooManyRedirects, .redirectToNonExistentLocation:
        return fail(
          "\(host) keeps redirecting to itself. If it is behind Cloudflare, set SSL/TLS to Full (strict) in "
            + "Cloudflare.")
      case .timedOut:
        return fail("\(host) took too long to answer.")
      default:
        // Refused, reset, or closed mid-answer, e.g. a captive portal or a proxy.
        return fail(onTailnet ? unreachable : "Couldn't reach \(host). Check the URL and your connection.")
      }
    } catch {
      return fail(onTailnet ? unreachable : "Couldn't reach \(host). Check the URL and your connection.")
    }
    let received = Date()
    // Dart's HttpClient gives up after 5 redirects: a loop, as far as anyone can tell.
    if redirects.exceeded {
      return fail(
        "\(host) keeps redirecting to itself. If it is behind Cloudflare, set SSL/TLS to Full (strict) in "
          + "Cloudflare.")
    }
    let status = res.statusCode
    if (520...530).contains(status)
      && (res.value(forHTTPHeaderField: "cf-ray") != nil
        || res.value(forHTTPHeaderField: "server")?.lowercased() == "cloudflare")
    {
      return fail(
        "Cloudflare answers for \(host) but can't reach your server (\(status)). Turn the orange cloud off for "
          + "this name (DNS only), or set SSL/TLS to Full (strict) in Cloudflare.")
    }
    if status == 502 || status == 503 || status == 504 {
      return fail(
        "\(host) answers, but the PocketTerm server behind it doesn't (\(status)). Check that PocketTerm runs on "
          + "the computer that serves it.")
    }
    if status == 404 { return fail(noServer) }
    if status != 200 { return fail("The server answered with an error (\(status)).") }
    guard let health = JSON.tryParse(data), let version = health["pocketterm"]?.int else { return fail(noServer) }
    if version > Self.protocol { return fail("Your server is newer than this app. Update PocketTerm, then retry.") }
    if let serverVersion = health["version"]?.string, Self.olderThan(serverVersion, Self.minServer) {
      return fail(
        "Your server runs PocketTerm server \(serverVersion); this app needs \(Self.minServer) or newer. Update "
          + "PocketTerm on the computer that runs it, then retry.")
    }
    let time = DartDate.tryParse(health["time"]?.string ?? "")
    // The server read its clock about halfway through the round trip.
    let here = sent.addingTimeInterval(received.timeIntervalSince(sent) / 2)
    return (nil, time.map { $0.timeIntervalSince(here) })
  }

  /// What to tell the person when this device's clock is [offset] seconds off the server's by more than
  /// [clockTolerance]; nil when it's close enough or unknown.
  public static func clockWarning(_ offset: TimeInterval?) -> String? {
    guard let offset, abs(offset) > clockTolerance else { return nil }
    let minutes = Int((Double(abs(Int(offset))) / 60).rounded())
    return "This device's clock is \(minutes) minutes \(offset < 0 ? "ahead of" : "behind") the server's, so "
      + "its messages to your other devices are dropped. Turn on Set time automatically in this device's date and "
      + "time settings."
  }

  var noServer: String { "No PocketTerm server answers at this URL." }

  /// Whether version [a] (`1.2.3`) comes before [b].
  static func olderThan(_ a: String, _ b: String) -> Bool {
    func parts(_ v: String) -> [Int] {
      (v.components(separatedBy: "-").first ?? "").components(separatedBy: ".").map { Int($0) ?? 0 }
    }
    let x = parts(a)
    let y = parts(b)
    for i in 0..<3 {
      let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
      if d != 0 { return d < 0 }
    }
    return false
  }

  /// The server this device was connected to, if any. One an app from before saved for a Supabase
  /// project (with a key, or with kind `supabase`) isn't one.
  public static func load(from store: BackendStore) -> Backend? {
    guard let saved = store.loadBackend(), !saved.legacy, saved.kind != supabaseKind else { return nil }
    return parse(saved.url).backend
  }

  public func save(to store: BackendStore) {
    store.saveBackend(url: url, kind: nil)
  }

  public static func clear(in store: BackendStore) { store.saveBackend(url: nil, kind: nil) }
}

/// A computer id: 8 characters, a-z and 0-9.
func isDesktopId(_ s: String) -> Bool {
  s.utf8.count == 8 && s.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
}

private func replaceFirst(_ s: String, _ pattern: String, with: String) -> String {
  let re = try! NSRegularExpression(pattern: pattern)
  let ns = s as NSString
  guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
  return ns.replacingCharacters(in: m.range, with: with)
}

/// Counts redirects so a loop fails as Dart's does (after 5), instead of following one forever.
private final class RedirectCounter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let count = Locked(0)
  var exceeded: Bool { count.get > 5 }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let n = count.with { c -> Int in
      c += 1
      return c
    }
    completionHandler(n > 5 ? nil : request)
  }
}

/// Dart's `Uri.encodeQueryComponent`: everything but `A-Za-z0-9-._~` percent-encoded (UTF-8), a space as `+`.
public func encodeQueryComponent(_ s: String) -> String {
  var out = ""
  for b in s.utf8 {
    switch b {
    case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: out.unicodeScalars.append(UnicodeScalar(b))
    case 0x20: out += "+"
    default: out += String(format: "%%%02X", b)
    }
  }
  return out
}

/// Dart's `Uri.decodeQueryComponent`: `+` as a space, `%xx` as UTF-8 bytes. Nil when malformed.
public func decodeQueryComponent(_ s: String) -> String? {
  var bytes = [UInt8]()
  var it = Array(s.utf8)[...]
  while let b = it.popFirst() {
    if b == 0x2B {
      bytes.append(0x20)
    } else if b == 0x25 {
      guard it.count >= 2, let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) else { return nil }
      bytes.append(v)
      it = it.dropFirst(2)
    } else {
      bytes.append(b)
    }
  }
  return String(bytes: bytes, encoding: .utf8)
}

/// The parts of a URI the way Dart's `Uri.parse` gives them: [host] without IPv6 brackets, [path] empty
/// when there is none, [queryParameters] with `+` read as a space (the last of a repeated name wins).
package struct DartUri {
  package let scheme: String?
  package let host: String
  package let port: Int?
  package let path: String
  package let query: String?
  package let fragment: String?

  package init?(_ text: String) {
    guard let c = URLComponents(string: text) else { return nil }
    scheme = c.scheme?.lowercased()
    var h = c.percentEncodedHost ?? ""
    if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
    host = h.lowercased()
    port = c.port
    path = c.percentEncodedPath
    query = c.percentEncodedQuery
    fragment = c.percentEncodedFragment
  }

  package var queryParameters: [String: String] {
    guard let query else { return [:] }
    var map = [String: String]()
    for element in query.components(separatedBy: "&") {
      if let eq = element.firstIndex(of: "=") {
        if eq == element.startIndex { continue }
        guard let k = decodeQueryComponent(String(element[..<eq])),
          let v = decodeQueryComponent(String(element[element.index(after: eq)...]))
        else { continue }
        map[k] = v
      } else if !element.isEmpty, let k = decodeQueryComponent(element) {
        map[k] = ""
      }
    }
    return map
  }
}
