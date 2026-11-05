#if os(macOS)
import Foundation

/// One extension's connection, whatever carries it (LocalApi): a WebSocket
/// (omp) or HTTP long polls (Claude Code).
@MainActor
public protocol LiveLink: AnyObject {
  /// A JSON frame to the extension.
  func send(_ frame: String)

  func close() async
}

/// What the local API hands each extension's connection to: the LiveHub.
@MainActor
public protocol LiveEndpoint: AnyObject {
  /// The orchestrator's working folder (`orchestrator` beside cli.json), set by the local API.
  var orchestratorDir: String? { get set }

  /// Reads `frames` from one extension until they end, answering over `link`.
  func accept(_ frames: AsyncStream<String>, _ link: LiveLink) async
}
#endif
