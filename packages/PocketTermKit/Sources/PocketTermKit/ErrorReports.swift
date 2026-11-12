import Foundation

// What an error report may say. The iPhone and Mac apps send crashes and errors to GlitchTip (Sentry's protocol)
// through the Sentry SDK in their app targets; every message and exception text passes through here first, so a
// report never names a computer, an address, a person or a large piece of a terminal. Kept free of the SDK so
// it's tested here and the package stays dependency-light.

/// [text] with what could identify someone taken out: the user's [home] folder becomes `~`, a URL keeps only its
/// scheme (`wss://<redacted>`), email addresses, IP addresses and tailnet/LAN host names become placeholders; then
/// at most 300 characters of it, so no long stretch of terminal output rides along.
public func scrubErrorReport(_ text: String, home: String? = nil) -> String {
  var s = text
  if let home, home.count > 1 {
    // The folder itself or a path in it, not a longer name that starts the same (/Users/dan vs /Users/daniel).
    s = replacing(s, NSRegularExpression.escapedPattern(for: home) + #"(?![^/\s"'])"#, with: "~")
  }
  for (pattern, template) in errorReportRules { s = replacing(s, pattern, with: template) }
  return s.count > errorReportLimit ? String(s.prefix(errorReportLimit)) : s
}

/// The longest text a report carries.
public let errorReportLimit = 300

/// In order: URLs first (they hold hosts, addresses and emails of their own), emails before the host names their
/// domains could look like, IPv4 before IPv6, whose rule takes in the `<ip>` an IPv4-mapped `::ffff:1.2.3.4` ends with.
private let errorReportRules: [(String, String)] = [
  (#"\b([A-Za-z][A-Za-z0-9+.-]*)://[^\s"'<>]*"#, "$1://<redacted>"),
  (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
  (#"(?i)\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ts\.net|local|lan)\b"#, "<host>"),
  (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
  // Eight groups, or fewer around a `::`; a clock time (12:34:56) or `Type::member` is neither.
  (#"(?<![\w:])(?:(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|(?=[0-9A-Fa-f:]*::)[0-9A-Fa-f:]{2,39})(?:<ip>)?(?![\w:])"#, "<ip>"),
]

private func replacing(_ s: String, _ pattern: String, with template: String) -> String {
  // The patterns are constants: one that doesn't compile is a programming error the tests catch.
  let re = try! NSRegularExpression(pattern: pattern)
  return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
}
