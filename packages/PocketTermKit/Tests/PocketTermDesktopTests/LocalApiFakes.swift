#if os(macOS)
import Foundation
import PocketTermKit
@testable import PocketTermDesktop

/// A hub that records each connection's frames and keeps its link.
@MainActor
final class ApiFakeEndpoint: LiveEndpoint {
  var orchestratorDir: String?
  var links: [LiveLink] = []
  var frames: [String] = []
  /// Connections whose frames haven't ended yet.
  var open = 0

  func accept(_ frames: AsyncStream<String>, _ link: LiveLink) async {
    links.append(link)
    open += 1
    for await f in frames { self.frames.append(f) }
    open -= 1
  }
}

/// Waits until `check` holds (requests are served asynchronously).
@MainActor
func apiPumpUntil(_ check: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
  for _ in 0..<250 where !check() { try? await Task.sleep(nanoseconds: 20_000_000) }
  return check()
}

/// A raw TCP connection to 127.0.0.1 (blocking; use off the main actor).
final class ApiRawSocket: @unchecked Sendable {
  let fd: Int32

  init?(host: String = "127.0.0.1", port: Int) {
    fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    inet_pton(AF_INET, host, &addr.sin_addr)
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let r = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if r != 0 {
      Darwin.close(fd)
      return nil
    }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  @discardableResult
  func send(_ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
      var off = 0
      while off < raw.count {
        let n = Darwin.send(fd, raw.baseAddress! + off, raw.count - off, 0)
        if n <= 0 { return false }
        off += n
      }
      return true
    }
  }

  /// The status code of the response, read up to its headers' end.
  func status() -> Int? {
    var got = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while !got.contains("\r\n\r\n".data(using: .utf8)!) {
      let n = recv(fd, &buf, buf.count, 0)
      if n <= 0 { break }
      got.append(buf, count: n)
    }
    let line = String(decoding: got, as: UTF8.self).split(separator: "\r\n").first ?? ""
    let parts = line.split(separator: " ")
    return parts.count > 1 ? Int(parts[1]) : nil
  }

  func close() { Darwin.close(fd) }
}

/// This computer's IPv4 addresses but loopback.
func apiOtherAddresses() -> [String] {
  var list: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&list) == 0 else { return [] }
  defer { freeifaddrs(list) }
  var out: [String] = []
  var p = list
  while let i = p {
    defer { p = i.pointee.ifa_next }
    guard let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET) else { continue }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
    let s = String(cString: host)
    if !s.hasPrefix("127.") { out.append(s) }
  }
  return out
}
#endif
