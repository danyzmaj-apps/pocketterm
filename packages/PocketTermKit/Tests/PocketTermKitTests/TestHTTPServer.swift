import Foundation
import Network

/// A loopback TCP server for tests (Dart's `HttpServer.bind` in the Dart tests): each connection's request
/// head goes to [handler], which answers with raw bytes (an HTTP response, half of one, or nothing) and says
/// whether to hang up. Requests can be held: [handler] runs on a background queue and may block.
final class TestHTTPServer: @unchecked Sendable {
  struct Request {
    let method: String
    let path: String
    let headers: [String: String]
  }

  enum Reply {
    /// A whole answer, then the connection closes.
    case http(status: Int, headers: [String: String] = [:], body: String = "")
    /// These bytes, then hang up.
    case raw(String)
    /// These bytes, then keep the connection open, saying nothing more.
    case stall(String)
  }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "test-http", attributes: .concurrent)
  private var connections: [NWConnection] = []
  private let lock = NSLock()
  private(set) var port = 0

  init(_ handler: @escaping @Sendable (Request) -> Reply) throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
    }
    let queue = queue
    listener.newConnectionHandler = { [weak self] conn in
      self?.lock.lock()
      self?.connections.append(conn)
      self?.lock.unlock()
      conn.start(queue: queue)
      Self.read(conn, Data(), handler)
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    port = Int(listener.port?.rawValue ?? 0)
  }

  var url: String { "http://127.0.0.1:\(port)" }

  private static func read(_ conn: NWConnection, _ had: Data, _ handler: @escaping @Sendable (Request) -> Reply) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
      var buffer = had
      if let data { buffer.append(data) }
      guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
        if done || error != nil { conn.cancel() } else { read(conn, buffer, handler) }
        return
      }
      let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
      let first = head[0].components(separatedBy: " ")
      var headers: [String: String] = [:]
      for line in head.dropFirst() {
        if let colon = line.firstIndex(of: ":") {
          headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
      }
      let request = Request(method: first[0], path: first.count > 1 ? first[1] : "/", headers: headers)
      switch handler(request) {
      case .http(let status, let extra, let body):
        var text = "HTTP/1.1 \(status) X\r\ncontent-length: \(body.utf8.count)\r\nconnection: close\r\n"
        if extra["content-type"] == nil { text += "content-type: application/json\r\n" }
        for (k, v) in extra { text += "\(k): \(v)\r\n" }
        text += "\r\n" + body
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in conn.cancel() })
      case .raw(let text):
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in conn.cancel() })
      case .stall(let text):
        conn.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
      }
    }
  }

  func stop() {
    listener.cancel()
    lock.lock()
    let all = connections
    connections = []
    lock.unlock()
    for c in all { c.cancel() }
  }
}
