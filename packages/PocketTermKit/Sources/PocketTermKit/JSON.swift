import Foundation

/// A JSON value as Dart's `jsonDecode` gives it: an int stays an int (`1`), a double a double
/// (`1.0`), objects are unordered. The ports use it wherever the Dart code used
/// `Map<String, dynamic>`, so fields, defaults and type checks map one to one.
public enum JSON: Sendable, Hashable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])
}

/// A JSON object: Dart's `Map<String, dynamic>`.
public typealias JSONObject = [String: JSON]

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: JSON...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

extension JSON {
  /// `value is String ? value : null`.
  public var string: String? { if case .string(let s) = self { s } else { nil } }
  /// `value is int ? value : null` (a double is not an int, as in Dart).
  public var int: Int? { if case .int(let i) = self { i } else { nil } }
  /// `value is bool ? value : null`.
  public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
  /// `value is num ? value.toDouble() : null`.
  public var number: Double? {
    switch self {
    case .int(let i): Double(i)
    case .double(let d): d
    default: nil
    }
  }
  public var array: [JSON]? { if case .array(let a) = self { a } else { nil } }
  public var object: JSONObject? { if case .object(let o) = self { o } else { nil } }
  public var isNull: Bool { if case .null = self { true } else { false } }

  /// `value is List ? value.whereType<String>()`: the strings in an array; null when not an array.
  public var strings: [String]? { array?.compactMap(\.string) }

  /// A member of an object; nil when this isn't one or it has no such key.
  public subscript(key: String) -> JSON? { object?[key] }

  /// An element of an array; nil when out of range or not an array.
  public subscript(index: Int) -> JSON? {
    guard let a = array, index >= 0, index < a.count else { return nil }
    return a[index]
  }

  /// [JSON] made from strings.
  public static func strings(_ list: [String]) -> JSON { .array(list.map(JSON.string)) }
}

extension JSON {
  /// A failed parse: not JSON.
  public struct ParseError: Error, Sendable, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON: \(reason) at \(offset)" }
  }

  /// Parses [text] as Dart's `jsonDecode` does.
  public static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }

  /// Parses UTF-8 [data] as Dart's `jsonDecode(utf8.decode(data))` does (invalid UTF-8 fails).
  public static func parse(_ data: Data) throws -> JSON {
    var p = Parser(bytes: [UInt8](data))
    p.skipSpace()
    let v = try p.value(depth: 0)
    p.skipSpace()
    if p.i != p.bytes.count { throw p.fail("trailing characters") }
    return v
  }

  /// [text] parsed, or nil when it isn't JSON.
  public static func tryParse(_ text: String) -> JSON? { try? parse(text) }
  public static func tryParse(_ data: Data) -> JSON? { try? parse(data) }
}

private struct Parser {
  let bytes: [UInt8]
  var i = 0

  func fail(_ reason: String) -> JSON.ParseError { .init(offset: i, reason: reason) }

  mutating func skipSpace() {
    while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
  }

  mutating func value(depth: Int) throws -> JSON {
    guard depth < 512 else { throw fail("too deep") }
    guard i < bytes.count else { throw fail("unexpected end") }
    switch bytes[i] {
    case UInt8(ascii: "{"):
      i += 1
      var o = JSONObject()
      skipSpace()
      if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
        i += 1
        return .object(o)
      }
      while true {
        skipSpace()
        guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
        let k = try string()
        skipSpace()
        guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
        i += 1
        skipSpace()
        o[k] = try value(depth: depth + 1)
        skipSpace()
        guard i < bytes.count else { throw fail("unexpected end") }
        if bytes[i] == UInt8(ascii: ",") {
          i += 1
          continue
        }
        if bytes[i] == UInt8(ascii: "}") {
          i += 1
          return .object(o)
        }
        throw fail("expected , or }")
      }
    case UInt8(ascii: "["):
      i += 1
      var a = [JSON]()
      skipSpace()
      if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
        i += 1
        return .array(a)
      }
      while true {
        skipSpace()
        a.append(try value(depth: depth + 1))
        skipSpace()
        guard i < bytes.count else { throw fail("unexpected end") }
        if bytes[i] == UInt8(ascii: ",") {
          i += 1
          continue
        }
        if bytes[i] == UInt8(ascii: "]") {
          i += 1
          return .array(a)
        }
        throw fail("expected , or ]")
      }
    case UInt8(ascii: "\""):
      return .string(try string())
    case UInt8(ascii: "t"):
      try literal("true")
      return .bool(true)
    case UInt8(ascii: "f"):
      try literal("false")
      return .bool(false)
    case UInt8(ascii: "n"):
      try literal("null")
      return .null
    default:
      return try number()
    }
  }

  mutating func literal(_ word: String) throws {
    let w = Array(word.utf8)
    guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("unexpected character") }
    i += w.count
  }

  mutating func number() throws -> JSON {
    let start = i
    var isDouble = false
    if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
    guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw fail("unexpected character") }
    if bytes[i] == 0x30 {
      i += 1
    } else {
      while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
    }
    if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
      isDouble = true
      i += 1
      guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw fail("bad number") }
      while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
    }
    if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
      isDouble = true
      i += 1
      if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
      guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw fail("bad number") }
      while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
    }
    let text = String(decoding: bytes[start..<i], as: UTF8.self)
    if !isDouble, let n = Int(text) { return .int(n) }
    // Dart reads an integer too big for an int as a double.
    guard let d = Double(text) else { throw fail("bad number") }
    return .double(d)
  }

  mutating func string() throws -> String {
    i += 1  // the opening quote
    var units = [UInt16]()
    var run = i
    func flush(_ p: inout Parser, to end: Int) throws {
      if end > run {
        guard let s = String(bytes: p.bytes[run..<end], encoding: .utf8) else { throw p.fail("bad UTF-8") }
        units.append(contentsOf: s.utf16)
      }
    }
    while true {
      guard i < bytes.count else { throw fail("unterminated string") }
      let b = bytes[i]
      if b == UInt8(ascii: "\"") {
        try flush(&self, to: i)
        i += 1
        return String(decoding: units, as: UTF16.self)
      }
      if b < 0x20 { throw fail("control character in string") }
      if b == UInt8(ascii: "\\") {
        try flush(&self, to: i)
        i += 1
        guard i < bytes.count else { throw fail("unterminated string") }
        switch bytes[i] {
        case UInt8(ascii: "\""): units.append(0x22)
        case UInt8(ascii: "\\"): units.append(0x5C)
        case UInt8(ascii: "/"): units.append(0x2F)
        case UInt8(ascii: "b"): units.append(0x08)
        case UInt8(ascii: "f"): units.append(0x0C)
        case UInt8(ascii: "n"): units.append(0x0A)
        case UInt8(ascii: "r"): units.append(0x0D)
        case UInt8(ascii: "t"): units.append(0x09)
        case UInt8(ascii: "u"):
          guard i + 4 < bytes.count, let u = UInt16(String(decoding: bytes[i + 1...i + 4], as: UTF8.self), radix: 16)
          else { throw fail("bad \\u escape") }
          units.append(u)
          i += 4
        default: throw fail("bad escape")
        }
        i += 1
        run = i
        continue
      }
      i += 1
    }
  }
}

extension JSON {
  /// This value as Dart's `jsonEncode` writes it: no spaces, `/` and non-ASCII as they are, control
  /// characters escaped (`\b \t \n \f \r`, else `\u00xx`). Object keys come sorted, so the same value
  /// always gives the same text.
  public func encoded() -> String {
    var out = ""
    write(to: &out)
    return out
  }

  /// [encoded] as UTF-8.
  public func encodedData() -> Data { Data(encoded().utf8) }

  func write(to out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .int(let n): out += String(n)
    case .double(let d): out += JSON.dartDouble(d)
    case .string(let s): JSON.writeString(s, to: &out)
    case .array(let a):
      out += "["
      for (n, v) in a.enumerated() {
        if n > 0 { out += "," }
        v.write(to: &out)
      }
      out += "]"
    case .object(let o):
      out += "{"
      for (n, k) in o.keys.sorted().enumerated() {
        if n > 0 { out += "," }
        JSON.writeString(k, to: &out)
        out += ":"
        o[k]!.write(to: &out)
      }
      out += "}"
    }
  }

  /// A double as Dart prints it in JSON: `1.0`, `0.5`, `1e+21`; NaN and infinity aren't JSON (null).
  static func dartDouble(_ d: Double) -> String {
    guard d.isFinite else { return "null" }
    if d == d.rounded(), abs(d) < 1e21 { return String(format: "%.1f", d) }
    var s = "\(d)"
    if let e = s.firstIndex(of: "e"), s[s.index(after: e)] != "-" { s.insert("+", at: s.index(after: e)) }
    return s
  }

  static func writeString(_ s: String, to out: inout String) {
    out += "\""
    for u in s.unicodeScalars {
      switch u.value {
      case 0x22: out += "\\\""
      case 0x5C: out += "\\\\"
      case 0x08: out += "\\b"
      case 0x09: out += "\\t"
      case 0x0A: out += "\\n"
      case 0x0C: out += "\\f"
      case 0x0D: out += "\\r"
      case 0..<0x20: out += String(format: "\\u%04x", u.value)
      default: out.unicodeScalars.append(u)
      }
    }
    out += "\""
  }
}

extension JSON: CustomStringConvertible {
  public var description: String { encoded() }
}

extension Dictionary where Key == String, Value == JSON {
  /// This object as Dart's `jsonEncode` writes it ([JSON.encoded]).
  public func encoded() -> String { JSON.object(self).encoded() }
}
