import Foundation

/// Dates as Dart's `DateTime.tryParse` reads them and `toIso8601String` writes them, so what the server
/// and the other ports send round-trips exactly.
public enum DartDate {
  private static let pattern = try! NSRegularExpression(
    pattern:
      #"^([+-]?\d{4,6})-?(\d\d)-?(\d\d)(?:[T ](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?\s*(Z|z|[+-]\d\d(?::?\d\d)?)?)?$"#
  )

  /// [text] as an ISO-8601 date (Dart's subset): `2026-10-22T12:00:00.000Z`, `2026-10-22 14:00:00+02:00`,
  /// a date alone; without a zone it is local time. Nil when it isn't one.
  public static func tryParse(_ text: String?) -> Date? {
    guard let text else { return nil }
    let ns = text as NSString
    guard let m = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    func group(_ i: Int) -> String? {
      let r = m.range(at: i)
      return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
    var c = DateComponents()
    c.year = Int(group(1)!)
    c.month = Int(group(2)!)
    c.day = Int(group(3)!)
    c.hour = group(4).flatMap { Int($0) } ?? 0
    c.minute = group(5).flatMap { Int($0) } ?? 0
    c.second = group(6).flatMap { Int($0) } ?? 0
    var fraction = 0.0
    if let f = group(7) {
      // Dart reads up to microseconds and drops the rest.
      let digits = String(f.prefix(6)).padding(toLength: 6, withPad: "0", startingAt: 0)
      fraction = Double(Int(digits) ?? 0) / 1_000_000
    }
    var calendar = Calendar(identifier: .gregorian)
    if let zone = group(8) {
      var offset = 0
      if zone != "Z" && zone != "z" {
        let sign = zone.hasPrefix("-") ? -1 : 1
        let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
        let h = Int(digits.prefix(2)) ?? 0
        let mm = digits.count > 2 ? Int(digits.suffix(2)) ?? 0 : 0
        offset = sign * (h * 3600 + mm * 60)
      }
      calendar.timeZone = TimeZone(secondsFromGMT: offset)!
    } else {
      calendar.timeZone = .current
    }
    guard let month = c.month, (1...12).contains(month), let day = c.day, (1...31).contains(day),
      let date = calendar.date(from: c)
    else { return nil }
    return date.addingTimeInterval(fraction)
  }

  /// [date] in UTC as Dart's `toUtc().toIso8601String()` writes it: milliseconds always, microseconds
  /// when there are any (`2026-10-22T12:00:00.000Z`).
  public static func utcIso8601(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let micros = Int((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
    let whole = Date(timeIntervalSince1970: Double(micros.floorDiv(1_000_000)))
    let rest = micros - micros.floorDiv(1_000_000) * 1_000_000
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
    var s = String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!,
      rest / 1000)
    if rest % 1000 != 0 { s += String(format: "%03d", rest % 1000) }
    return s + "Z"
  }
}

extension Int {
  /// Division rounding toward negative infinity.
  func floorDiv(_ d: Int) -> Int { self >= 0 ? self / d : -((-self + d - 1) / d) }
}
