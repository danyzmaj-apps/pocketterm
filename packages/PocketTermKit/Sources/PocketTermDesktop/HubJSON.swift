#if os(macOS)
import Foundation
import PocketTermKit

// Dart's casts on decoded JSON (`m['x'] as String`), which the hub and the bridge rely on to skip a frame or refuse a
// request whose fields are of the wrong shape.

/// A failed Dart cast, worded as Dart's TypeError.
struct HubCastError: Error, CustomStringConvertible {
  let value: JSON?
  let type: String
  var description: String { "type '\(dartTypeName(value))' is not a subtype of type '\(type)' in type cast" }
}

/// Dart's runtime type name of a decoded JSON value.
func dartTypeName(_ v: JSON?) -> String {
  switch v {
  case nil, .null?: "Null"
  case .bool?: "bool"
  case .int?: "int"
  case .double?: "double"
  case .string?: "String"
  case .array?: "List<dynamic>"
  case .object?: "_Map<String, dynamic>"
  }
}

/// `v as String?`.
func castString(_ v: JSON?) throws -> String? {
  switch v {
  case nil, .null?: return nil
  case .string(let s)?: return s
  default: throw HubCastError(value: v, type: "String?")
  }
}

/// `v as String`.
func castRequiredString(_ v: JSON?) throws -> String {
  guard case .string(let s)? = v else { throw HubCastError(value: v, type: "String") }
  return s
}

/// `v as num?`.
func castNumber(_ v: JSON?) throws -> Double? {
  switch v {
  case nil, .null?: return nil
  case .int(let i)?: return Double(i)
  case .double(let d)?: return d
  default: throw HubCastError(value: v, type: "num?")
  }
}

/// `(v as num?)?.round()`.
func castRounded(_ v: JSON?) throws -> Int? {
  if case .int(let i)? = v { return i }
  return try castNumber(v).map { Int($0.rounded()) }
}

/// `(v as num?)?.toInt()`.
func castTruncated(_ v: JSON?) throws -> Int? {
  if case .int(let i)? = v { return i }
  return try castNumber(v).map { Int($0.rounded(.towardZero)) }
}

/// `v as List?`.
func castList(_ v: JSON?) throws -> [JSON]? {
  switch v {
  case nil, .null?: return nil
  case .array(let a)?: return a
  default: throw HubCastError(value: v, type: "List<dynamic>?")
  }
}

/// `v as Map?`.
func castMap(_ v: JSON?) throws -> JSONObject? {
  switch v {
  case nil, .null?: return nil
  case .object(let o)?: return o
  default: throw HubCastError(value: v, type: "Map<dynamic, dynamic>?")
  }
}

/// `'$v'`: a JSON value as Dart's string interpolation prints it.
func dartInterpolated(_ v: JSON?) -> String {
  switch v {
  case nil, .null?: return "null"
  case .bool(let b)?: return b ? "true" : "false"
  case .int(let i)?: return "\(i)"
  case .double(let d)?: return d == d.rounded() && abs(d) < 1e21 ? "\(Int(d)).0" : "\(d)"
  case .string(let s)?: return s
  case let other?: return other.encoded()
  }
}

/// Dart's `==` on two strings: code unit by code unit (Swift's compares canonically equivalent strings equal).
func sameText(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
#endif
