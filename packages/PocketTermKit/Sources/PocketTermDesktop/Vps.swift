#if os(macOS)
import Foundation
import Network
import PocketTermKit

/// The name a VPS's server answers at, from what the person typed: a domain as it is, an IPv4 address as its
/// sslip.io name (`203.0.113.7` → `203-0-113-7.sslip.io`, a name that resolves to that address), so Caddy can get a
/// certificate for it. Either [domain] or [error] is set.
public struct ServerAddress: Sendable, Equatable {
  private init(_ domain: String?, _ error: String?, _ host: String? = nil, _ user: String? = nil) {
    self.domain = domain
    self.error = error
    self.host = host
    self.user = user
  }

  public let domain: String?

  /// Why what was typed can't be used, for the person.
  public let error: String?

  /// What was typed, as SSH reaches the server: its IP address or domain, and the user, if one was typed with it.
  public let host: String?
  public let user: String?

  /// How to sign in to the server from here.
  public var ssh: String? { host.map { "ssh \(user.flatMap { $0.isEmpty ? nil : $0 } ?? "root")@\($0)" } }

  public static func parse(_ typed: String) -> ServerAddress {
    var s = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let scheme = s.range(of: "^[a-z]+://", options: .regularExpression) { s.removeSubrange(scheme) }
    if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
    // user@host, as an SSH line has it ("ssh ubuntu@203.0.113.7").
    var user: String?
    if let at = s.lastIndex(of: "@") {
      user = s[..<at].split(omittingEmptySubsequences: false, whereSeparator: { $0.isWhitespace }).last.map(String.init)
      s = String(s[s.index(after: at)...])
    }
    while s.hasSuffix(".") { s.removeLast() }
    if s.isEmpty { return ServerAddress(nil, "Enter your server’s IP address or domain name.") }
    let bare = s.hasPrefix("[") && s.hasSuffix("]") ? String(s.dropFirst().dropLast()) : s
    var v6 = in6_addr()
    if inet_pton(AF_INET6, bare, &v6) == 1 || s.hasPrefix("[") {
      return ServerAddress(
        nil,
        "Use the server’s IPv4 address (like 203.0.113.7) or a domain name. An IPv6-only server doesn’t work: "
          + "Docker gets the server from GitHub’s registry (ghcr.io), which has no IPv6, and many phone networks reach "
          + "only IPv4. Most providers add an IPv4 address for a small fee.")
    }
    var v4 = in_addr()
    if inet_pton(AF_INET, s, &v4) == 1 {
      let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
      // Loopback, link-local and the private ranges.
      if b[0] == 127 || (b[0] == 169 && b[1] == 254) || isPrivate(b) {
        return ServerAddress(
          nil, "That’s a private address. Use the public IP address your VPS provider shows for the server.")
      }
      return ServerAddress("\(s.replacingOccurrences(of: ".", with: "-")).sslip.io", nil, s, user)
    }
    if s.contains(":") { return ServerAddress(nil, "Leave out the port: the server answers on 443.") }
    let labels = s.components(separatedBy: ".")
    let label = "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"
    if labels.count < 2 || !labels.allSatisfy({ $0.range(of: label, options: .regularExpression) != nil })
      || labels.last!.range(of: "^[0-9]+$", options: .regularExpression) != nil
    {
      return ServerAddress(nil, "That isn’t an IP address or a domain name, like pocketterm.example.com.")
    }
    return ServerAddress(s, nil, s, user)
  }

  /// 10/8, 172.16/12, 192.168/16, 100.64/10 (carrier-grade NAT, Tailscale).
  private static func isPrivate(_ b: [UInt8]) -> Bool {
    b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168)
      || (b[0] == 100 && b[1] >= 64 && b[1] < 128) || b[0] == 0
  }
}

/// One command to run on the VPS, and what it does.
public struct VpsCommand: Sendable, Equatable {
  public let title: String
  public let command: String
}

/// The compose file the commands fetch: the repository's at release tag v[version], this app's version, so the VPS
/// runs what this release shipped (the file pins the image to the same version).
public func composeUrl(_ version: String) -> String {
  "https://raw.githubusercontent.com/danyzmaj-apps/pocketterm/v\(version)/apps/pocketterm-server/docker-compose.yml"
}

/// What to run on a fresh VPS for a server at [domain], with this app's [version], in order: Docker, the compose
/// file, start it, its setup link. Each one stands alone (it changes to ~/pocketterm itself), so a new SSH session can
/// pick up where the last one left off. docs/SELF_HOSTING.md shows the same commands.
public func vpsCommands(_ domain: String, _ version: String) -> [VpsCommand] {
  [
    VpsCommand(title: "Install Docker", command: "curl -fsSL https://get.docker.com | sudo sh"),
    VpsCommand(
      title: "Get the server",
      command: "mkdir -p ~/pocketterm && cd ~/pocketterm && curl -fsSLO \(composeUrl(version))"),
    VpsCommand(
      title: "Start it", command: "cd ~/pocketterm && echo \"DOMAIN=\(domain)\" > .env && sudo docker compose up -d"),
    VpsCommand(
      title: "Print its setup link",
      command: "cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link"),
  ]
}

/// A server's answer to GET /v1/health ([Backend.health]): `error` is nil when it's a PocketTerm server this app
/// speaks to; `clockOffset`, in seconds, how far its clock is from this computer's ([Backend.clockWarning]).
public typealias ServerHealth = (error: String?, clockOffset: TimeInterval?)

/// What the setup looks at while a VPS is being set up: the name resolves, HTTPS answers on it (Caddy got its
/// certificate), the server is healthy. Tests hand in their own.
public protocol ServerChecks: Sendable {
  /// [domain] resolves to an IPv4 address (an A record: an IPv6-only name leaves out the phone networks that reach
  /// only IPv4).
  func resolves(_ domain: String) async -> Bool
  /// A TLS handshake with [domain] on 443 succeeds: a valid certificate.
  func https(_ domain: String) async -> Bool
  /// [backend]'s GET /v1/health, as [health] (a pasted setup link's server).
  func answers(_ backend: Backend) async -> ServerHealth
}

extension ServerChecks {
  /// The server at [domain]: `https://<domain>`.
  public func backendFor(_ domain: String) -> Backend { Backend(url: "https://\(domain)") }

  /// GET /v1/health of the server at [domain].
  public func health(_ domain: String) async -> ServerHealth { await answers(backendFor(domain)) }
}

/// The checks over the network.
public struct NetworkServerChecks: ServerChecks {
  public init() {}

  public func resolves(_ domain: String) async -> Bool {
    await withDeadline(8, fallback: false) {
      var hints = addrinfo()
      hints.ai_family = AF_INET
      hints.ai_socktype = SOCK_STREAM
      var found: UnsafeMutablePointer<addrinfo>?
      let r = getaddrinfo(domain, nil, &hints, &found)
      if let found { freeaddrinfo(found) }
      return r == 0 && found != nil
    }
  }

  public func https(_ domain: String) async -> Bool {
    let connection = NWConnection(host: NWEndpoint.Host(domain), port: 443, using: .tls)
    let result = await withDeadline(8, fallback: false) {
      await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
        let once = OnceFlag()
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready: if once.take() { done.resume(returning: true) }
          case .failed, .cancelled, .waiting: if once.take() { done.resume(returning: false) }
          default: break
          }
        }
        connection.start(queue: .global())
      }
    }
    connection.cancel()
    return result
  }

  public func answers(_ backend: Backend) async -> ServerHealth { await backend.health() }
}

/// True the first time only.
final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var taken = false
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if taken { return false }
    taken = true
    return true
  }
}

/// [body]'s answer, or [fallback] when it takes longer than [seconds] (it's left to finish on its own).
func withDeadline<T: Sendable>(
  _ seconds: TimeInterval, fallback: T, _ body: @escaping @Sendable () async -> T
) async -> T {
  await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
    let once = OnceFlag()
    Task.detached {
      let v = await body()
      if once.take() { done.resume(returning: v) }
    }
    Task.detached {
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      if once.take() { done.resume(returning: fallback) }
    }
  }
}
#endif
