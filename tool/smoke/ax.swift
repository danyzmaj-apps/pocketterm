// The installed-app smoke's hands and eyes: PocketTerm's window through
// macOS accessibility, as VoiceOver reaches it (the app turns its tree on
// for a POCKETTERM_PROFILE). tool/smoke/run.sh compiles it.
//
//   ax <pid> dump               every element: role, label (indented)
//   ax <pid> texts              the labels, one a line
//   ax <pid> has <label>        exit 0 when an element is so labelled
//   ax <pid> press <label>      presses it (AXPress: no mouse, the pointer stays put)
//   ax <pid> set <label> <text> types <text> into the text field so labelled
//   ax <pid> window             the window's CGWindowID (screencapture -l)
//
// A label matches exactly, by its first line, or else by containing it.
import ApplicationServices
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
  FileHandle.standardError.write("usage: ax <pid> dump|texts|has|press|set|window …\n".data(using: .utf8)!)
  exit(2)
}
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
  var v: AnyObject?
  return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func label(_ e: AXUIElement) -> String {
  var parts: [String] = []
  for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
    if let s = attr(e, a) as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !parts.contains(s) {
      parts.append(s)
    }
  }
  return parts.joined(separator: " | ")
}

func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }

/// Every element of the window, depth first, with its depth.
func all() -> [(AXUIElement, Int)] {
  var out: [(AXUIElement, Int)] = []
  func walk(_ e: AXUIElement, _ d: Int) {
    out.append((e, d))
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
  }
  for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
  return out
}

func find(_ want: String) -> AXUIElement? {
  let labelled = all().map { ($0.0, label($0.0)) }.filter { !$0.1.isEmpty }
  func lines(_ l: String) -> [String] {
    l.components(separatedBy: " | ").flatMap { $0.components(separatedBy: "\n") }.map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }
  if let e = labelled.first(where: { $0.1 == want }) { return e.0 }
  if let e = labelled.first(where: { lines($0.1).contains(want) }) { return e.0 }
  return labelled.first(where: { $0.1.contains(want) })?.0
}

switch args[2] {
case "dump":
  for (e, d) in all() { print(String(repeating: " ", count: d) + role(e) + " " + label(e).replacingOccurrences(of: "\n", with: " ⏎ ")) }
case "texts":
  for (e, _) in all() where !label(e).isEmpty { print(label(e)) }
case "has":
  exit(find(args[3]) == nil ? 1 : 0)
case "press":
  guard let e = find(args[3]) else { print("nothing labelled \"\(args[3])\""); exit(1) }
  let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
  print(r == .success ? "pressed \(label(e).components(separatedBy: "\n")[0])" : "couldn't press it (\(r.rawValue))")
  exit(r == .success ? 0 : 1)
case "set":
  guard let e = find(args[3]) else { print("nothing labelled \"\(args[3])\""); exit(1) }
  AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[4] as CFString)
  print(r == .success ? "set" : "couldn't set it (\(r.rawValue))")
  exit(r == .success ? 0 : 1)
case "window":
  let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
  let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
  func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
  }
  guard let w = mine.max(by: { area($0) < area($1) }), let n = w[kCGWindowNumber as String] as? Int else {
    print("no window on screen"); exit(1)
  }
  print(n)
default:
  print("unknown command \(args[2])"); exit(2)
}
