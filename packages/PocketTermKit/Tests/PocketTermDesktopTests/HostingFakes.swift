#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

/// A process that prints what it's given, then exits with its code, or keeps running until killed.
final class HostFakeProcess: RunningProcess, @unchecked Sendable {
  let output: AsyncStream<Data>
  private let sink: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var code: Int32?
  private var waiters: [CheckedContinuation<Int32, Never>] = []
  private var wasKilled = false

  private init(out: String, err: String) {
    (output, sink) = AsyncStream<Data>.makeStream()
    if !out.isEmpty { sink.yield(Data(out.utf8)) }
    if !err.isEmpty { sink.yield(Data(err.utf8)) }
  }

  static func done(_ code: Int32, out: String = "", err: String = "") -> HostFakeProcess {
    let p = HostFakeProcess(out: out, err: err)
    p.end(code)
    return p
  }

  static func waiting(out: String = "") -> HostFakeProcess { HostFakeProcess(out: out, err: "") }

  var killed: Bool { lock.withLock { wasKilled } }

  private func end(_ c: Int32) {
    sink.finish()
    let ready: [CheckedContinuation<Int32, Never>] = lock.withLock {
      guard code == nil else { return [] }
      code = c
      defer { waiters = [] }
      return waiters
    }
    for w in ready { w.resume(returning: c) }
  }

  func exitCode() async -> Int32 {
    await withCheckedContinuation { c in
      lock.lock()
      if let code {
        lock.unlock()
        c.resume(returning: code)
      } else {
        waiters.append(c)
        lock.unlock()
      }
    }
  }

  func kill() {
    lock.withLock { wasKilled = true }
    end(-15)
  }
}

/// A flag any thread reads.
final class HostFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false
  var value: Bool { lock.withLock { on } }
  func set(_ v: Bool) { lock.withLock { on = v } }
}

/// Opens once; everyone waiting goes on (Dart's Completer<void>).
@MainActor
final class HostGate {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if open { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func complete() {
    open = true
    for w in waiters { w.resume() }
    waiters = []
  }
}

/// Tailscale's CLI as a test sets it up, recording every command in [calls] (without the CLI's path). Not installed
/// by default.
@MainActor
final class HostFakeTailscale {
  init(
    installed: Bool = false, daemon: Bool = true, backendState: String = "Running",
    dnsName: String = "mac.tail1234.ts.net", https: Bool = true
  ) {
    installedFlag.set(installed)
    self.daemon = daemon
    self.backendState = backendState
    self.dnsName = dnsName
    self.https = https
  }

  /// Read off the main actor too (Tailscale finds its CLI wherever it runs).
  private let installedFlag = HostFlag()
  var installed: Bool {
    get { installedFlag.value }
    set { installedFlag.set(newValue) }
  }

  /// The Tailscale service runs (else the CLI can't reach it).
  var daemon: Bool
  var backendState: String
  var dnsName: String
  /// HTTPS certificates (and Serve) are on for the tailnet.
  var https: Bool

  static let enableLink = "https://login.tailscale.com/f/serve?node=nTEST123"

  /// What `tailscale serve status --json` prints: what Serve publishes now. `serve --bg` sets it, `serve
  /// --https=443 off` clears it.
  var serveConfig: JSONObject = [:]

  /// Serve publishing [proxy] on 443, as `tailscale serve --bg <proxy>` leaves it.
  func serving(_ proxy: String) {
    serveConfig = [
      "TCP": ["443": ["HTTPS": true]],
      "Web": .object(["\(dnsName):443": ["Handlers": ["/": ["Proxy": .string(proxy)]]]]),
    ]
  }

  var calls: [String] = []

  /// `tailscale serve status` fails (exits non-zero) while set.
  var statusFails = false

  /// `tailscale serve --bg` waits for this before it publishes, when set.
  var serveGate: HostGate?

  /// `serve` processes still running (one that asks for HTTPS waits until killed).
  var running: [HostFakeProcess] = []

  lazy var tailscale = Tailscale(
    start: { [self] exe, args in await self.start(exe, args) },
    locate: { [installedFlag] in installedFlag.value ? "/fake/bin/tailscale" : nil })

  private func start(_ exe: String, _ args: [String]) async -> any RunningProcess {
    calls.append(args.joined(separator: " "))
    if args.first == "status" {
      if !daemon {
        return HostFakeProcess.done(1, err: "failed to connect to local Tailscale service; is Tailscale running?\n")
      }
      let status: JSON = [
        "BackendState": .string(backendState),
        "Self": ["DNSName": .string("\(dnsName)."), "TailscaleIPs": ["100.101.102.103"]],
        "CertDomains": https ? [.string(dnsName)] : .null,
      ]
      return HostFakeProcess.done(0, out: status.encoded())
    }
    if args.prefix(2) == ["serve", "status"] {
      if statusFails { return HostFakeProcess.done(1, err: "failed to connect to local Tailscale service\n") }
      return HostFakeProcess.done(0, out: serveConfig.isEmpty ? "null\n" : JSON.object(serveConfig).encoded())
    }
    if args.first == "serve" && args.last != "off" && !https {
      // What the CLI prints, then it waits for HTTPS to be turned on.
      let p = HostFakeProcess.waiting(
        out: "Serve is not enabled on your tailnet.\nTo enable, visit:\n\n         \(Self.enableLink)\n\n")
      running.append(p)
      return p
    }
    if args.first == "serve" && args.last != "off" {
      await serveGate?.wait()
      serving(args.last!)
      return HostFakeProcess.done(
        0, out: "Available within your tailnet:\n\nhttps://\(dnsName)/\n|-- proxy \(args.last!)\n")
    }
    if args.first == "serve" { serveConfig = [:] }
    return HostFakeProcess.done(0)
  }
}

/// The sidecar in this process: each server a real listening socket on 127.0.0.1 (so ports are taken and freed as
/// the real one's), its setup token kept in the data folder's `setup-token` as the real one keeps it.
final class HostFakeSidecar: ServerSidecar, @unchecked Sendable {
  private let lock = NSLock()
  private var started: [HostFakeServer] = []

  /// Every server it started, oldest first.
  var servers: [HostFakeServer] { lock.withLock { started } }

  func serve(dataDir: URL, port: Int, relay: URL?, relayKey: Data?) async throws(ServerStartError)
    -> any RunningServer
  {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if bound != 0 {
      let why = errno
      close(fd)
      if why == EADDRINUSE { throw .portTaken("Port \(port) on 127.0.0.1 is taken") }
      throw .failed(String(cString: strerror(why)))
    }
    listen(fd, 16)
    var got = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &got) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let server = HostFakeServer(fd: fd, port: Int(UInt16(bigEndian: got.sin_port)))
    lock.withLock { started.append(server) }
    return server
  }

  func setupLink(dataDir: URL, publicUrl: String) async throws -> URL {
    let file = dataDir.appendingPathComponent("setup-token")
    let token: String
    if let kept = try? String(contentsOf: file, encoding: .utf8) {
      token = kept
    } else {
      token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      try token.write(to: file, atomically: true, encoding: .utf8)
    }
    var url = publicUrl
    while url.hasSuffix("/") { url.removeLast() }
    return Backend(url: url).linkWithSetup(token)
  }
}

final class HostFakeServer: RunningServer, @unchecked Sendable {
  init(fd: Int32, port: Int) {
    self.fd = fd
    self.port = port
  }

  private let lock = NSLock()
  private var fd: Int32
  private var waiters: [CheckedContinuation<Int32, Never>] = []
  let port: Int

  func exitCode() async -> Int32 {
    await withCheckedContinuation { c in
      lock.lock()
      if fd < 0 {
        lock.unlock()
        c.resume(returning: 0)
      } else {
        waiters.append(c)
        lock.unlock()
      }
    }
  }

  func stop() async {
    let ready: [CheckedContinuation<Int32, Never>] = lock.withLock {
      if fd >= 0 { close(fd) }
      fd = -1
      defer { waiters = [] }
      return waiters
    }
    for w in ready { w.resume(returning: 0) }
  }
}

/// Whether anything answers on 127.0.0.1:[port].
func hostListening(_ port: Int) -> Bool {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  defer { close(fd) }
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = in_port_t(UInt16(port).bigEndian)
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  return withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  } == 0
}

/// A socket listening on 127.0.0.1:[port] (0: any), standing in for whatever else took that port; its port.
func hostOccupy(_ port: Int = 0) -> (fd: Int32, port: Int) {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = in_port_t(UInt16(port).bigEndian)
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  _ = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  listen(fd, 4)
  var got = sockaddr_in()
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &got) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
  }
  return (fd, Int(UInt16(bigEndian: got.sin_port)))
}

/// A fresh temporary folder, removed after the test.
func hostTempDir(_ test: XCTestCase) -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm-host-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
  return dir
}
#endif
