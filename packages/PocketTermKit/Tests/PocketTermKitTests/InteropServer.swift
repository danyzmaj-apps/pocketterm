import Foundation
import XCTest

@testable import PocketTermKit

/// The real Dart server (apps/pocketterm-server), compiled once per test run and started per test on a
/// free loopback port in a temporary data folder. Only with `POCKETTERM_INTEROP=1`: it needs `fvm dart`.
final class InteropServer: @unchecked Sendable {
  static var enabled: Bool { ProcessInfo.processInfo.environment["POCKETTERM_INTEROP"] == "1" }

  static let repo: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  /// The compiled server, made on first use.
  private static let binary: Result<URL, Error> = {
    // One file, compiled anew each run (so it follows the server's code) over the last run's.
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm-server-interop")
    do {
      let (status, output) = try run(
        "/usr/bin/env",
        ["fvm", "dart", "compile", "exe", "apps/pocketterm-server/bin/pocketterm_server.dart", "-o", out.path],
        cwd: repo)
      guard status == 0 else { throw TerminalException("dart compile failed: \(output)") }
      return .success(out)
    } catch {
      return .failure(error)
    }
  }()

  @discardableResult
  static func run(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.pub-cache/bin:\(NSHomeDirectory())/fvm/default/bin"
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  let dir: URL
  let port: Int
  private let process: Process
  private let stdin: Pipe

  /// Starts a server; skips the test when interop is off.
  static func start() throws -> InteropServer {
    guard enabled else { throw XCTSkip("POCKETTERM_INTEROP=1 runs the tests against the real Dart server") }
    return try InteropServer(binary.get())
  }

  private init(_ exe: URL) throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm-interop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    process = Process()
    process.executableURL = exe
    process.arguments = ["serve", "--data", dir.path, "--address", "127.0.0.1", "--port", "0", "--exit-with-stdin"]
    stdin = Pipe()
    let out = Pipe()
    process.standardInput = stdin
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    // The one line `serve` writes once it listens.
    var line = Data()
    while true {
      let byte = out.fileHandleForReading.readData(ofLength: 1)
      if byte.isEmpty || byte == Data("\n".utf8) { break }
      line.append(byte)
    }
    guard let j = JSON.tryParse(line), j["event"] == "listening", let port = j["port"]?.int else {
      process.terminate()
      throw TerminalException("The server didn't start: \(String(decoding: line, as: UTF8.self))")
    }
    self.port = port
  }

  var url: String { "http://127.0.0.1:\(port)" }
  var backend: Backend { Backend(url: url) }

  /// `setup-link`: what signs a computer in.
  func setupLink() throws -> URL {
    let (status, output) = try Self.run(
      process.executableURL!.path, ["setup-link", "--data", dir.path, "--public-url", url])
    guard status == 0, let link = URL(string: output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw TerminalException("setup-link failed: \(output)")
    }
    return link
  }

  func stop() {
    try? stdin.fileHandleForWriting.close()
    process.terminate()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: dir)
  }

  /// A computer signed in with the setup link.
  func desktop(_ label: String = "MacBook Pro") async throws -> PocketTermServerClient {
    let c = PocketTermServerClient(backend, tokens: MemoryDeviceTokens())
    _ = try await c.redeemSetup(Backend.setupToken(try setupLink())!, label: label, platform: "macos")
    return c
  }

  /// A phone signed in with a code from [desktop].
  func phone(_ desktop: Server, _ label: String = "iPhone") async throws -> PocketTermServerClient {
    let c = PocketTermServerClient(backend, tokens: MemoryDeviceTokens())
    _ = try await c.redeemCode(try await desktop.createPairingCode(), label: label, platform: "ios")
    return c
  }
}
