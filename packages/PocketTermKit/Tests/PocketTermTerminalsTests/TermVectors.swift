import CryptoKit
import Foundation
import PocketTermKit

/// tool/vectors/vectors.json, the frozen wire contract (tool/vectors/README.md), read from the repo.
enum TermVectors {
  static let root: JSON = {
    // Tests/PocketTermTerminalsTests/TermVectors.swift → the repo root is five levels up.
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let url = repo.appendingPathComponent("tool/vectors/vectors.json")
    do {
      return try JSON.parse(Data(contentsOf: url))
    } catch {
      fatalError("Can't read \(url.path): \(error)")
    }
  }()

  /// The value at `path` (`terminal`, `keyBytes`).
  static func at(_ path: String...) -> JSON {
    var v = root
    for p in path {
      guard let next = v[p] else { fatalError("vectors.json: \(path.joined(separator: ".")) missing") }
      v = next
    }
    return v
  }

  /// The cases at `path` (an array, or an object's `cases`).
  static func cases(_ path: String...) -> [JSON] {
    var v = root
    for p in path {
      guard let next = v[p] else { fatalError("vectors.json: \(path.joined(separator: ".")) missing") }
      v = next
    }
    if let a = v.array { return a }
    if let a = v["cases"]?.array { return a }
    fatalError("vectors.json: \(path.joined(separator: ".")) is not a list")
  }

  /// Expands the README's repeated inputs (`{"repeat": u, "times": n, "then"?, "prefix"?}`); any other
  /// string as it is.
  static func text(_ v: JSON?) -> String? {
    guard let v else { return nil }
    if let s = v.string { return s }
    guard let o = v.object, let u = o["repeat"]?.string, let n = o["times"]?.int else { return nil }
    return (o["prefix"]?.string ?? "") + String(repeating: u, count: n) + (o["then"]?.string ?? "")
  }

  /// Whether `s` is what a summary (`{codeUnits, utf8Bytes, sha256, head, tail}`) says.
  static func matches(_ s: String, summary: JSON) -> Bool {
    let scalars = Array(s.unicodeScalars)
    func str(_ part: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(part)) }
    let sha = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    return s.utf16.count == summary["codeUnits"]?.int && s.utf8.count == summary["utf8Bytes"]?.int
      && sha == summary["sha256"]?.string && str(scalars.prefix(40)) == summary["head"]?.string
      && str(scalars.suffix(40)) == summary["tail"]?.string
  }

  static func note(_ c: JSON) -> String { c["note"]?.string ?? "" }
}
