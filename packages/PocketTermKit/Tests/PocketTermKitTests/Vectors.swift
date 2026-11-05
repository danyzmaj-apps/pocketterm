import Foundation
import XCTest

@testable import PocketTermKit

/// tool/vectors/vectors.json, the frozen wire contract (tool/vectors/README.md), read from the repo.
enum Vectors {
  static let root: JSON = {
    // Tests/PocketTermKitTests/Vectors.swift → the repo root is four levels up.
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let url = repo.appendingPathComponent("tool/vectors/vectors.json")
    do {
      return try JSON.parse(Data(contentsOf: url))
    } catch {
      fatalError("Can't read \(url.path): \(error)")
    }
  }()

  /// One top-level section (`crypto`, `live`, …).
  static func section(_ name: String) -> JSON {
    guard let s = root[name] else { fatalError("vectors.json has no section \(name)") }
    return s
  }

  /// The cases at [path] in [section] (an array, or an object's `cases`).
  static func cases(_ section: String, _ path: String...) -> [JSON] {
    var v = Self.section(section)
    for p in path {
      guard let next = v[p] else { fatalError("vectors.json: \(section).\(path.joined(separator: ".")) missing") }
      v = next
    }
    if let a = v.array { return a }
    if let a = v["cases"]?.array { return a }
    fatalError("vectors.json: \(section).\(path.joined(separator: ".")) is not a list")
  }

  /// Bytes from standard base64 with padding.
  static func bytes(_ v: JSON?) -> Data {
    guard let s = v?.string, let d = Data(base64Encoded: s) else { fatalError("not base64: \(String(describing: v))") }
    return d
  }

  /// Bytes from hex.
  static func hex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
      let j = s.index(i, offsetBy: 2)
      d.append(UInt8(s[i..<j], radix: 16)!)
      i = j
    }
    return d
  }

  /// Expands the README's repeated inputs (`{"repeat": u, "times": n, "then"?, "prefix"?}`); any other
  /// string as it is.
  static func text(_ v: JSON?) -> String? {
    guard let v else { return nil }
    if let s = v.string { return s }
    guard let o = v.object, let u = o["repeat"]?.string, let n = o["times"]?.int else { return nil }
    return (o["prefix"]?.string ?? "") + String(repeating: u, count: n) + (o["then"]?.string ?? "")
  }
}

extension Data {
  var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
