// The installed-app smoke's hands and eyes: PocketTerm's window through
// macOS accessibility, as VoiceOver reaches it (the app turns its tree on
// for a POCKETTERM_PROFILE). tool/smoke/run.sh compiles it.
//
//   ax <pid> dump               every element: role, label (indented)
//   ax <pid> texts              the labels, one a line
//   ax <pid> has <label>        exit 0 when an element is so labelled
//   ax <pid> enabled <label>    exit 0 when it's enabled, 1 when disabled, 3 when nothing is so labelled
//   ax <pid> press <label>      presses it (AXPress: no mouse, the pointer stays put)
//   ax <pid> set <label> <text> types <text> into the text field so labelled
//   ax <pid> window             the window's CGWindowID (screencapture -l); exit 1 when none is on screen
//   ax <pid> close              presses the window's close button (the red one)
//   ax <pid> extras             the labels of its menu bar icons, one a line
//   ax <pid> press-extra <label> presses its menu bar icon so labelled (as a left click)
//
// A label matches exactly, by its first line, or else by containing it;
// `#field` is the first text field, labelled or not. Menu bar icons match
// the same way, among themselves.
import ApplicationServices
import CoreGraphics
import Foundation

let args = CommandLine.arguments
func usage() -> Never {
  FileHandle.standardError.write(
    "usage: ax <pid> dump|texts|has <label>|enabled <label>|press <label>|set <label> <text>|window|close|extras|press-extra <label>\n"
      .data(using: .utf8)!)
  exit(2)
}
guard args.count >= 3, let pid = pid_t(args[1]) else { usage() }
/// What each command needs after `ax <pid> <command>`.
let operands = [
  "dump": 0, "texts": 0, "has": 1, "enabled": 1, "press": 1, "set": 2, "window": 0, "close": 0, "extras": 0,
  "press-extra": 1,
]
if let n = operands[args[2]], args.count < 3 + n { usage() }
let app = AXUIElementCreateApplication(pid)

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
  var v: AnyObject?
  return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

/// [v] as an element, when it is one.
func element(_ v: AnyObject?) -> AXUIElement? {
  guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
  return (v as! AXUIElement)
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

/// The first of [elements] labelled [want]: exactly, by a line, or else by containing it.
func match(_ want: String, in elements: [AXUIElement]) -> AXUIElement? {
  let labelled = elements.map { ($0, label($0)) }.filter { !$0.1.isEmpty }
  func lines(_ l: String) -> [String] {
    l.components(separatedBy: " | ").flatMap { $0.components(separatedBy: "\n") }.map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }
  if let e = labelled.first(where: { $0.1 == want }) { return e.0 }
  if let e = labelled.first(where: { lines($0.1).contains(want) }) { return e.0 }
  return labelled.first(where: { $0.1.contains(want) })?.0
}

func find(_ want: String) -> AXUIElement? {
  if want == "#field" { return all().first { role($0.0) == "AXTextField" }?.0 }
  return match(want, in: all().map { $0.0 })
}

/// Its menu bar icons (NSStatusItem), right of the menus.
func extras() -> [AXUIElement] {
  guard let bar = element(attr(app, "AXExtrasMenuBar")) else { return [] }
  return (attr(bar, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func press(_ e: AXUIElement) -> Never {
  let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
  print(r == .success ? "pressed \(label(e).components(separatedBy: "\n")[0])" : "couldn't press it (\(r.rawValue))")
  exit(r == .success ? 0 : 1)
}

switch args[2] {
case "dump":
  for (e, d) in all() { print(String(repeating: " ", count: d) + role(e) + " " + label(e).replacingOccurrences(of: "\n", with: " ⏎ ")) }
case "texts":
  for (e, _) in all() where !label(e).isEmpty { print(label(e)) }
case "has":
  exit(find(args[3]) == nil ? 1 : 0)
case "enabled":
  guard let e = find(args[3]) else { print("nothing labelled \"\(args[3])\""); exit(3) }
  let on = attr(e, kAXEnabledAttribute) as? Bool ?? true
  print(on ? "enabled" : "disabled")
  exit(on ? 0 : 1)
case "press":
  guard let e = find(args[3]) else { print("nothing labelled \"\(args[3])\""); exit(1) }
  press(e)
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
case "close":
  let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
  let main = element(attr(app, kAXMainWindowAttribute))
  guard let button = ([main].compactMap { $0 } + windows).lazy.compactMap({ element(attr($0, kAXCloseButtonAttribute)) }).first
  else { print("no window with a close button"); exit(1) }
  press(button)
case "extras":
  for e in extras() { print(label(e)) }
case "press-extra":
  guard let e = match(args[3], in: extras()) else { print("no menu bar icon labelled \"\(args[3])\""); exit(1) }
  press(e)
default:
  print("unknown command \(args[2])"); exit(2)
}
