// The installed-app smoke's and the e2e run's hands and eyes: PocketTerm's
// windows and its menu-bar panel through macOS accessibility, as VoiceOver
// reaches them. tool/smoke/run.sh and tool/e2e compile it.
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
//   ax <pid> press-extra <label> presses its menu bar icon so labelled (as a left click: opens its panel)
//   ax <pid> panel              every element of the menu-bar panel, while it's open (as dump)
//   ax <pid> press-panel <label> presses the panel's element so labelled
//   ax <pid> panel-window       the panel's CGWindowID while it's open (screencapture -l)
//   ax <pid> has-id <id>        exit 0 when a window's element has that accessibility identifier
//   ax <pid> press-id <id>      presses the element with that identifier
//   ax <pid> ids                every identifier on screen: identifier, role, label (a line each)
//   ax <pid> texts-id <id>      the labels of that element and everything in it, one a line; exit 1 when none
//   ax <pid> value-id <id>      its value (a switch's 0 or 1, a field's text); exit 1 when none
//   ax <pid> enabled-id <id>    as enabled, by identifier
//   ax <pid> set-id <id> <text> its text (or the first text field in it) becomes <text>
//   ax <pid> press-in <id> <label> presses what can be pressed in it so labelled
//   ax <pid> pick-id <id> <label> opens the menu of that pop-up button (or the picker in it) and picks <label>
//   ax <pid> windows            its windows' titles, one a line
//   ax <pid> press-sheet <label> presses what's so labelled in an alert or sheet on a window (its buttons, not
//                               the window's own of the same name)
//   ax <pid> serve              reads commands from stdin, one JSON array a line (["press-id","x"]), and
//                               answers each with a JSON line {"code":0,"out":"…"}: one process for a whole run
//
// A label matches exactly, by its first line, or else by containing it;
// `#field` is the first text field, labelled or not. Menu bar icons and the
// panel's elements match the same way, among themselves.
import ApplicationServices
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let usageText =
  "usage: ax <pid> dump|texts|has <label>|enabled <label>|press <label>|set <label> <text>|window|close|extras|press-extra <label>|panel|press-panel <label>|panel-window|has-id <id>|press-id <id>|ids|texts-id <id>|value-id <id>|enabled-id <id>|set-id <id> <text>|press-in <id> <label>|pick-id <id> <label>|windows|press-sheet <label>|serve\n"
guard args.count >= 3, let pid = pid_t(args[1]) else {
  FileHandle.standardError.write(usageText.data(using: .utf8)!)
  exit(2)
}
/// What each command needs after `ax <pid> <command>`.
let operands = [
  "dump": 0, "texts": 0, "has": 1, "enabled": 1, "press": 1, "set": 2, "window": 0, "close": 0, "extras": 0,
  "press-extra": 1, "panel": 0, "press-panel": 1, "panel-window": 0, "has-id": 1, "press-id": 1, "ids": 0,
  "texts-id": 1, "value-id": 1, "enabled-id": 1, "set-id": 2, "press-in": 2, "pick-id": 2, "windows": 0, "serve": 0,
  "press-sheet": 1,
]
let app = AXUIElementCreateApplication(pid)
// A busy app (a SwiftUI update) answers late; a dead one never: a second at most for each question.
AXUIElementSetMessagingTimeout(app, 2)

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
func identifier(_ e: AXUIElement) -> String? { attr(e, "AXIdentifier") as? String }

/// What can be done to [e] (AXPress, AXShowMenu, …).
func actions(_ e: AXUIElement) -> [String] {
  var names: CFArray?
  return AXUIElementCopyActionNames(e, &names) == .success ? (names as? [String]) ?? [] : []
}

func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

/// [root] and everything in it, depth first, with its depth.
func walk(_ root: AXUIElement, _ depth: Int = 0) -> [(AXUIElement, Int)] {
  var out: [(AXUIElement, Int)] = []
  func go(_ e: AXUIElement, _ d: Int) {
    out.append((e, d))
    for c in children(e) { go(c, d + 1) }
  }
  go(root, depth)
  return out
}

func appWindows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

/// Every element of the windows, depth first, with its depth.
func all() -> [(AXUIElement, Int)] { appWindows().flatMap { walk($0) } }

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
  return children(bar)
}

/// The menu-bar panel (an NSPopover under its icon), depth first, while it's open.
func panel() -> [(AXUIElement, Int)] {
  extras().flatMap { children($0).filter { role($0) == "AXPopover" }.flatMap { walk($0) } }
}

/// The first element of a window or the panel with accessibility identifier [id] (SwiftUI's accessibilityIdentifier).
func byId(_ id: String) -> AXUIElement? {
  (all() + panel()).first { identifier($0.0) == id }?.0
}

func pressable(_ e: AXUIElement) -> Bool { actions(e).contains(kAXPressAction as String) }

func press(_ e: AXUIElement) -> (Int32, String) {
  let name = label(e).components(separatedBy: "\n")[0]
  let r = AXUIElementPerformAction(e, kAXPressAction as CFString)
  if r == .success { return (0, "pressed \(name)") }
  // An alert's button closes the alert as it's pressed: the answer comes back "can't complete", the element gone.
  if r == .cannotComplete && attr(e, kAXRoleAttribute) == nil { return (0, "pressed \(name) (it went away)") }
  return (1, "couldn't press it (\(r.rawValue))")
}

func setText(_ e: AXUIElement, _ text: String) -> (Int32, String) {
  let field = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role(e))
    ? e : walk(e).first { ["AXTextField", "AXTextArea", "AXComboBox"].contains(role($0.0)) }?.0
  guard let field else { return (1, "no text field there") }
  AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
  let r = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString)
  return r == .success ? (0, "set") : (1, "couldn't set it (\(r.rawValue))")
}

func dumpLine(_ e: AXUIElement, _ d: Int) -> String {
  let id = identifier(e).map { " #\($0)" } ?? ""
  return String(repeating: " ", count: d) + role(e) + id + " " + label(e).replacingOccurrences(of: "\n", with: " ⏎ ")
}

func run(_ a: [String]) -> (Int32, String) {
  guard a.count >= 1, let n = operands[a[0]], a.count >= 1 + n else { return (2, usageText) }
  switch a[0] {
  case "dump":
    return (0, all().map { dumpLine($0.0, $0.1) }.joined(separator: "\n"))
  case "texts":
    return (0, all().map { label($0.0) }.filter { !$0.isEmpty }.joined(separator: "\n"))
  case "has":
    return (find(a[1]) == nil ? 1 : 0, "")
  case "enabled":
    guard let e = find(a[1]) else { return (3, "nothing labelled \"\(a[1])\"") }
    let on = attr(e, kAXEnabledAttribute) as? Bool ?? true
    return (on ? 0 : 1, on ? "enabled" : "disabled")
  case "press":
    // Among what can be pressed: a Settings window is titled after its tab, and the title isn't the tab's button.
    guard let e = a[1] == "#field" ? find(a[1]) : match(a[1], in: all().map { $0.0 }.filter(pressable)) else {
      return (1, "nothing labelled \"\(a[1])\"")
    }
    return press(e)
  case "set":
    guard let e = find(a[1]) else { return (1, "nothing labelled \"\(a[1])\"") }
    return setText(e, a[2])
  case "window", "panel-window":
    // The window: the largest of its normal-level windows; the panel: the largest above them (the menu bar
    // icon's own window is a sliver).
    let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let normal = a[0] == "window"
    let mine = list.filter {
      ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && (($0[kCGWindowLayer as String] as? Int) == 0) == normal
    }
    func area(_ w: [String: Any]) -> Double {
      let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
      return (b["Width"] ?? 0) * (b["Height"] ?? 0)
    }
    guard let w = mine.max(by: { area($0) < area($1) }), let n = w[kCGWindowNumber as String] as? Int else {
      return (1, normal ? "no window on screen" : "no panel on screen")
    }
    return (0, "\(n)")
  case "close":
    let main = element(attr(app, kAXMainWindowAttribute))
    guard
      let button = ([main].compactMap { $0 } + appWindows()).lazy.compactMap({
        element(attr($0, kAXCloseButtonAttribute))
      }).first
    else { return (1, "no window with a close button") }
    return press(button)
  case "extras":
    return (0, extras().map(label).joined(separator: "\n"))
  case "press-extra":
    guard let e = match(a[1], in: extras()) else { return (1, "no menu bar icon labelled \"\(a[1])\"") }
    return press(e)
  case "panel":
    return (0, panel().map { dumpLine($0.0, $0.1) }.joined(separator: "\n"))
  case "press-panel":
    guard let e = match(a[1], in: panel().map { $0.0 }) else {
      return (1, "nothing in the panel labelled \"\(a[1])\"")
    }
    return press(e)
  case "has-id":
    return (byId(a[1]) == nil ? 1 : 0, "")
  case "press-id":
    guard let e = byId(a[1]) else { return (1, "nothing with the identifier \"\(a[1])\"") }
    // A container so marked (a row, a card): the first thing in it that can be pressed.
    if pressable(e) { return press(e) }
    guard let inner = walk(e).first(where: { pressable($0.0) })?.0 else { return (1, "nothing to press in it") }
    return press(inner)
  case "ids":
    return (
      0,
      (all() + panel()).compactMap { e, _ in
        identifier(e).map { "\($0)\t\(role(e))\t\(label(e).replacingOccurrences(of: "\n", with: " ⏎ "))" }
      }.joined(separator: "\n")
    )
  case "texts-id":
    guard let e = byId(a[1]) else { return (1, "nothing with the identifier \"\(a[1])\"") }
    return (0, walk(e).map { label($0.0) }.filter { !$0.isEmpty }.joined(separator: "\n"))
  case "value-id":
    guard let e = byId(a[1]) else { return (1, "nothing with the identifier \"\(a[1])\"") }
    // A switch inside a row so marked has the value.
    let v = attr(e, kAXValueAttribute) ?? walk(e).lazy.compactMap { attr($0.0, kAXValueAttribute) }.first
    return (0, v.map { "\($0)" } ?? "")
  case "enabled-id":
    guard let e = byId(a[1]) else { return (3, "nothing with the identifier \"\(a[1])\"") }
    let target = pressable(e) ? e : (walk(e).first { pressable($0.0) }?.0 ?? e)
    let on = attr(target, kAXEnabledAttribute) as? Bool ?? true
    return (on ? 0 : 1, on ? "enabled" : "disabled")
  case "set-id":
    guard let e = byId(a[1]) else { return (1, "nothing with the identifier \"\(a[1])\"") }
    return setText(e, a[2])
  case "press-in":
    guard let e = byId(a[1]) else { return (1, "nothing with the identifier \"\(a[1])\"") }
    guard let p = match(a[2], in: walk(e).map { $0.0 }.filter(pressable)) else {
      return (1, "nothing in \(a[1]) labelled \"\(a[2])\"")
    }
    return press(p)
  case "pick-id":
    guard let e = byId(a[1]) else { return (1, "nothing with the identifier \"\(a[1])\"") }
    let popup = role(e) == "AXPopUpButton" ? e : walk(e).first { role($0.0) == "AXPopUpButton" }?.0
    guard let popup else {
      // Radio buttons or a segmented control: the choice itself.
      guard let c = match(a[2], in: walk(e).map { $0.0 }.filter(pressable)) else {
        return (1, "no choice \"\(a[2])\" in \(a[1])")
      }
      return press(c)
    }
    AXUIElementPerformAction(popup, kAXPressAction as CFString)
    for _ in 0..<20 {
      let items = walk(popup).map { $0.0 }.filter { role($0) == "AXMenuItem" }
      if let item = match(a[2], in: items) { return press(item) }
      usleep(100_000)
    }
    AXUIElementPerformAction(popup, kAXCancelAction as CFString)
    return (1, "no item \"\(a[2])\" in the menu of \(a[1])")
  case "press-sheet":
    func showing() -> [AXUIElement] {
      let sheets = all().map { $0.0 }.filter {
        role($0) == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains(attr($0, kAXSubroleAttribute) as? String ?? "")
      }
      return sheets.flatMap { walk($0).map { $0.0 } }.filter(pressable)
    }
    guard let b = match(a[1], in: showing()) else {
      return (1, "no alert or sheet with \"\(a[1])\"")
    }
    let r = press(b)
    if r.0 == 0 { return r }
    // A SwiftUI alert's button may answer an error while its action runs and the alert closes under it: pressed
    // once it's gone (a retry would find no alert, and the press must not be repeated).
    for _ in 0..<20 {
      if match(a[1], in: showing()) == nil { return (0, "pressed \(a[1]) (it went away; \(r.1))") }
      usleep(100_000)
    }
    return r
  case "windows":
    return (0, appWindows().map { attr($0, kAXTitleAttribute) as? String ?? "" }.joined(separator: "\n"))
  default:
    return (2, "unknown command \(a[0])")
  }
}

if args[2] == "serve" {
  while let line = readLine() {
    let cmd = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String] ?? []
    let (code, out) = run(cmd)
    let answer = try! JSONSerialization.data(withJSONObject: ["code": Int(code), "out": out])
    FileHandle.standardOutput.write(answer + Data("\n".utf8))
  }
  exit(0)
}
let (code, out) = run(Array(args.dropFirst(2)))
if !out.isEmpty { print(out) }
if code == 2 { FileHandle.standardError.write(usageText.data(using: .utf8)!) }
exit(code)
