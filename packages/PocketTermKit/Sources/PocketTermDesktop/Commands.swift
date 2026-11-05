#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals

/// How a command went: its exit code (nil when it was stopped) and what it printed, both streams.
public struct CommandResult: Sendable, Equatable {
  public init(code: Int32?, output: String) {
    self.code = code
    self.output = output
  }
  public let code: Int32?
  public let output: String
}

/// Runs a program with its arguments, [environment] added to this process's; tests hand in a fake.
public typealias RunCommand = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String])
  async throws -> CommandResult

/// The installs the setup offers to run for the person (`brew install tmux`, `brew install --cask tailscale-app`),
/// each only after they confirmed it, never on its own.
public final class Commands: Sendable {
  public init(
    run: RunCommand? = nil, brew: (@Sendable () -> String?)? = nil, macPorts: (@Sendable () -> String?)? = nil
  ) {
    self.runner = run ?? Commands.runProcess
    self.findBrew = brew ?? { Commands.findBrew() }
    self.findMacPorts = macPorts ?? { Commands.findMacPorts() }
  }

  private let runner: RunCommand
  private let findBrew: @Sendable () -> String?
  private let findMacPorts: @Sendable () -> String?

  /// What the setup installs Tailscale with.
  public static let tailscaleInstall = ["brew", "install", "--cask", "tailscale-app"]

  /// Why macOS asks for the password while Homebrew installs Tailscale (its installer runs with sudo).
  public static let tailscalePassword =
    "Homebrew is installing Tailscale for PocketTerm. Enter your Mac password to allow it."

  /// What the setup installs tmux with.
  public static let tmuxInstall = ["brew", "install", "tmux"]

  /// Homebrew's `brew`, when it's on this Mac.
  public var brew: String? { findBrew() }

  /// MacPorts' `port`, when it's on this Mac. Its installs need sudo in a terminal, so the setup only shows its line.
  public var macPorts: String? { findMacPorts() }

  /// Where Homebrew lives on Apple silicon and on Intel Macs.
  public static func findBrew(exists: ((String) -> Bool)? = nil) -> String? {
    let isFile = exists ?? { FileManager.default.fileExists(atPath: $0) }
    return ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: isFile)
  }

  /// Where MacPorts puts `port`.
  public static func findMacPorts(exists: ((String) -> Bool)? = nil) -> String? {
    let path = "/opt/local/bin/port"
    return (exists ?? { FileManager.default.fileExists(atPath: $0) })(path) ? path : nil
  }

  /// Runs [argv] (`brew` first stands for [brew]). [password]: why macOS asks for the person's password, should the
  /// command need it (a package Homebrew installs with sudo): macOS's own dialog asks.
  public func run(_ argv: [String], password: String? = nil) async throws -> CommandResult {
    guard let exe = argv.first == "brew" ? brew : argv.first else {
      return CommandResult(code: 127, output: "Homebrew isn’t installed.")
    }
    // Deleted once the command is done.
    let askpass = try password.map(Commands.askpass)
    defer { if let askpass { try? FileManager.default.removeItem(at: askpass.deletingLastPathComponent()) } }
    var env = [
      // A GUI app's PATH is short: Homebrew's own folder first.
      "PATH": [(exe as NSString).deletingLastPathComponent, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(
        separator: ":"),
      "HOMEBREW_NO_ENV_HINTS": "1",
    ]
    if let askpass { env["SUDO_ASKPASS"] = askpass.path }
    return try await runner(exe, Array(argv.dropFirst()), env)
  }

  /// A script sudo runs for the password (sudo -A, which Homebrew uses when SUDO_ASKPASS is set): macOS's dialog,
  /// saying [why]. In a folder of its own, which goes with it.
  static func askpass(_ why: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pocketterm-askpass\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("askpass.sh")
    let prompt = why.filter { !"\"'\\".contains($0) }
    try (
      "#!/bin/sh\n"
        + "exec /usr/bin/osascript -e 'text returned of (display dialog \"\(prompt)\" default answer \"\" "
        + "with hidden answer with title \"PocketTerm\" with icon caution)'\n"
    ).write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
  }

  /// Both streams in the order they came, as Dart's `forEach(out.write)` on each gathered them.
  private static let runProcess: RunCommand = { exe, args, env in
    let output = Guarded(Data())
    let process = try Subprocess.start(exe, args, environment: env) { _, chunk in
      output.with { $0.append(chunk) }
    }
    let code = await process.exitCode()
    // Both streams have ended once their reads gave all they had.
    _ = await process.stdout()
    _ = await process.stderr()
    return CommandResult(code: code, output: String(decoding: output.get, as: UTF8.self))
  }
}
#endif
