import Foundation

// The agents' dialogs as their screens show them. The patterns are Dart's (JavaScript's) written for ICU:
// `[^\n\r\x{2028}\x{2029}]` for `.`, `\z` for `$`, ASCII digits for `\d` and `jsSpaceChars` for `\s`.

private let space = "[\(jsSpaceChars)]"
private let nonSpace = "[^\(jsSpaceChars)]"
private let anyChar = #"[^\n\r\x{2028}\x{2029}]"#

private let askFlat = TermRegex("[\(jsSpaceChars)*_`#>]+")

/// How to tell `ask` is `agent`'s dialog on the screen: some of its words in
/// the screen's text, compared without spacing or Markdown marks (the
/// terminal wraps and styles them).
public func askOnScreen(_ ask: LiveAsk, _ screen: String, agent: Agent = .omp) -> Bool {
  func flat(_ s: String) -> String { askFlat.replaceAll(s, "").lowercased() }
  let text = flat(screen)
  if ask.isPlan {
    return (agent == .omp && liveContains(text, "planmode-nextstep")) || parsePlanReview(screen, agent: agent) != nil
  }
  if ask.isMenu {
    guard let menu = parseMenu(screen) else { return false }
    return liveSame(menu.title, ask.title)
  }
  if ask.isApproval {
    switch agent {
    case .omp: return liveContains(text, "approve") && liveContains(text, "deny")
    // "Do you want to proceed?" (or "… to create notes.txt?") over "❯ 1. Yes".
    case .claude: return liveContains(text, "doyouwant") && liveContains(text, "❯1.yes")
    }
  }
  let q = flat(ask.questions!.first!.question)
  return liveContains(text, liveLength(q) > 24 ? liveSubstring(q, from: 0, to: 24) : q)
}

/// A plan review's options and the one its cursor (❯) is on.
public struct PlanReview: Sendable, Hashable {
  public var options: [String]
  public var current: Int
  public init(options: [String], current: Int) {
    self.options = options
    self.current = current
  }
}

/// `agent`'s plan review (the last step of plan mode), read off the plain
/// text of its screen: its options and the one its cursor (❯) is on. Nil
/// unless a review is up with its options focused.
public func parsePlanReview(_ screen: String, agent: Agent = .omp) -> PlanReview? {
  switch agent {
  case .omp: ompPlanReview(screen)
  case .claude: claudePlanReview(screen)
  }
}

private let claudePlanHeader = TermRegex(#"Would you like to proceed\?|Exit plan mode\?"#)
private let claudeRow = TermRegex(#"^\#(space)*(❯\#(space)*)?([0-9]+)\.\#(space)+(\#(nonSpace)\#(anyChar)*?)\#(space)*\z"#)

/// Claude Code's plan review: the numbered rows under its last "Would you
/// like to proceed?" ("Exit plan mode?" when no plan was written). Lines
/// between them (a row's hint) are skipped; a number out of turn ends them.
private func claudePlanReview(_ screen: String) -> PlanReview? {
  let lines = liveSplitLines(screen)
  guard let header = lines.lastIndex(where: claudePlanHeader.hasMatch) else { return nil }
  var options: [String] = []
  var current = -1
  for l in lines[(header + 1)...] {
    guard let m = claudeRow.firstMatch(l) else { continue }
    // Dart's int.parse fails on a number past 64 bits; it isn't the next row either.
    guard let n = Int(m[2]!), n == options.count + 1 else { break }
    if m[1] != nil { current = options.count }
    options.append(m[3]!)
  }
  if current < 0 { return nil }
  return PlanReview(options: options, current: current)
}

private let planHeader = TermRegex(#"plan mode\#(space)*[-–—]\#(space)*next step"#, caseInsensitive: true)
// Dart's `\b` is an ASCII word boundary.
private let planHelp = TermRegex("(?<![A-Za-z0-9_])select(?![A-Za-z0-9_])", caseInsensitive: true)
private let leftEdge = TermRegex(#"^\#(space)*[│┃║|]"#)
private let rightEdge = TermRegex(#"\#(space)*[│┃║|]\#(space)*\z"#)
private let cursor = TermRegex(#"^(\#(space)*)[❯›>]\#(space)+(?=\#(nonSpace))"#)
private let rule = TermRegex(#"^[─━═┄┈╌\-+├┤┼┬┴╭╮╰╯]+\z"#)

/// The UTF-16 offset where `re`'s first match in `s` ends.
private func matchEnd(_ re: TermRegex, _ s: String) -> Int? {
  re.re.firstMatch(in: s, range: NSRange(location: 0, length: liveLength(s))).map { $0.range.location + $0.range.length }
}

/// omp's plan review, read off the plain text of its screen: the options
/// listed between its "Plan mode - next step" header and the help line
/// under them ("↑/↓ select · ⏎ confirm · …"), and the one its cursor (❯) is
/// on. The model slider above them ("continue with ◂ smol default slow ▸"
/// and its "↳ model" line) is skipped, and a row the terminal wrapped is
/// joined again. Nil unless a review is up with its options focused, the
/// only time ↑/↓ move between them.
private func ompPlanReview(_ screen: String) -> PlanReview? {
  let lines = liveSplitLines(screen)
  guard let header = lines.lastIndex(where: planHeader.hasMatch),
    let help = lines[(header + 1)...].firstIndex(where: planHelp.hasMatch)
  else { return nil }
  // Inside the review's box every row starts with its edge; a row too wide
  // for the terminal goes on, without one, on the next line.
  let boxed = leftEdge.hasMatch(lines[header])
  let rows = lines[(header + 1)..<help].map { l in
    (edge: leftEdge.hasMatch(l), text: rightEdge.replaceFirst(leftEdge.replaceFirst(l, ""), ""))
  }
  guard let at = rows.firstIndex(where: { cursor.hasMatch($0.text) }) else { return nil }
  // Where the labels start: past the cursor on its row, past the indent on the others.
  let column = matchEnd(cursor, rows[at].text)!

  var options: [String] = []
  var current = -1
  var afterOption = false
  for (i, r) in rows.enumerated() {
    let t = liveTrim(r.text)
    if t.isEmpty || rule.hasMatch(t) {
      afterOption = false
      continue
    }
    if boxed ? !r.edge : i != at && liveIndent(r.text) != column {
      if afterOption { options[options.count - 1] += boxed ? r.text : " \(r.text)" }
      continue
    }
    afterOption = false
    if liveHasPrefix(t, "↳") || liveContains(t, "continue with") || liveContains(t, "◂") || liveContains(t, "▸") {
      continue
    }
    if i == at {
      current = options.count
      options.append(liveSubstring(r.text, from: column))
    } else if liveIndent(r.text) == column {
      options.append(liveSubstring(r.text, from: column))
    } else {
      continue
    }
    afterOption = true
  }
  if current < 0 { return nil }
  return PlanReview(options: options.map { liveTrim(TermRegex.whitespace.replaceAll($0, " ")) }, current: current)
}

/// A picker as `parseMenu` reads it off the screen.
public struct ParsedMenu: Sendable, Hashable {
  public var title: String
  public var items: [MenuItem]
  public var current: Int
  public var filter: Bool
  public init(title: String, items: [MenuItem], current: Int, filter: Bool) {
    self.title = title
    self.items = items
    self.current = current
    self.filter = filter
  }
}

private let menuCursor = TermRegex(#"^\#(space)*❯ "#)

/// Claude Code's prompt line: ❯ and a no-break space. It shows only while no
/// picker is up; the `❯ ` rows above it are prompts in its transcript.
private let claudePrompt = TermRegex(#"^\#(space)*❯\x{00A0}"#)
private let menuLeft = TermRegex(#"^\#(space)*[│┃║]"#)
private let menuRight = TermRegex(#"(\#(space)*[│┃║█])+\#(space)*\z"#)
private let menuChrome = TermRegex(
  #"^[\#(jsSpaceChars)─━═╭╮┌┐╔╗├┤╰╯└┘]+|[\#(jsSpaceChars)─━═╭╮┌┐╔╗├┤╰╯└┘]+\z"#)
private let menuStatus = TermRegex(
  #"^(\([0-9]+/[0-9]+[^)]*\)\#(space)*)?(type to search|search:|no match|no items|no sessions)"#,
  caseInsensitive: true)
private let menuGap = TermRegex(#"\#(space){2,}"#)

/// A numbered row's number (Claude Code's pickers: `1.  Default`), whose gap
/// is part of the label, not the one before its detail.
private let menuNumber = TermRegex(#"^([0-9]+\.)\#(space)+"#)

/// A vertical rule inside a row: another pane beside the list.
private let paneSplit = TermRegex("[│┃║]")

/// A picker the agent's terminal UI shows (/resume, /model, /tree, a hook's
/// selector …), read off the plain text of its screen: the rows around the
/// last cursor (❯) at the cursor's label column, a `title` above them (its
/// box's top border, or a line of its own) and whether typing filters them
/// (a `>` search line above, or "Type to search" under them). Rows apart by
/// blank lines are one item each (first line its label, the rest its
/// detail); otherwise every line is one, with what's indented deeper or
/// set apart by a wide gap as its detail. Box edges, scrollbars, padding
/// and lone "…" lines are left out; a footer of keys ends the rows. Nil
/// for anything else: the plan review, or Claude Code's prompt under a
/// transcript whose prompts read `❯ …` too.
public func parseMenu(_ screen: String) -> ParsedMenu? {
  if planHeader.hasMatch(screen) { return nil }
  let lines = liveSplitLines(screen).map { menuRight.replaceFirst(menuLeft.replaceFirst($0, ""), "") }
  guard let at = lines.lastIndex(where: menuCursor.hasMatch),
    !lines[(at + 1)...].contains(where: claudePrompt.hasMatch)
  else { return nil }
  let column = matchEnd(menuCursor, lines[at])!
  var filter = false
  func inList(_ i: Int) -> Bool {
    let t = liveTrim(lines[i])
    if t.isEmpty || i == at { return true }
    if menuStatus.hasMatch(t) {
      filter = filter || liveContains(t.lowercased(), "search")
      return false
    }
    return liveIndent(lines[i]) >= column
  }

  var top = at
  while top > 0 && inList(top - 1) { top -= 1 }
  var bottom = at
  while bottom + 1 < lines.count && inList(bottom + 1) { bottom += 1 }
  let rows = (top...bottom).filter { !liveSame(liveTrim(lines[$0]), "…") }.map { (i: $0, text: lines[$0]) }
  func isItem(_ r: (i: Int, text: String)) -> Bool {
    r.i == at || (!liveTrim(r.text).isEmpty && liveIndent(r.text) == column)
  }
  let first = rows.firstIndex(where: isItem)!
  let last = rows.lastIndex(where: isItem)!
  let blocks = rows[first...last].contains { liveTrim($0.text).isEmpty }

  var items: [[String]] = []
  var current = -1
  var gap = true
  for r in rows {
    let t = liveTrim(r.text)
    if t.isEmpty {
      gap = true
      continue
    }
    if isItem(r) && (!blocks || gap || items.isEmpty) {
      let row = menuNumber.replaceFirstMapped(liveTrim(liveSubstring(r.text, from: column))) { "\($0[1]!) " }
      if let split = menuGap.re.firstMatch(in: row, range: NSRange(location: 0, length: liveLength(row)))?.range {
        items.append([
          liveSubstring(row, from: 0, to: split.location), liveSubstring(row, from: split.location + split.length),
        ])
      } else {
        items.append([row])
      }
    } else if !items.isEmpty {
      items[items.count - 1].append(t)
    } else {
      continue
    }
    if r.i == at { current = items.count - 1 }
    gap = false
  }
  if current < 0 { return nil }
  // Panes side by side (/model's providers | models): a list of the left pane
  // alone would mislead, so leave it to the screen.
  if rows.contains(where: { paneSplit.hasMatch(liveSubstring($0.text, from: Swift.min(column, liveLength($0.text)))) }) {
    return nil
  }

  // The title: the first line above the rows that isn't blank or the search line.
  var title = ""
  var i = top - 1
  while i >= 0 {
    defer { i -= 1 }
    let t = liveTrim(lines[i])
    if t.isEmpty { continue }
    if liveHasPrefix(t, ">") {
      filter = true
      continue
    }
    title = menuChrome.replaceAll(t, "")
    break
  }
  func flat(_ s: String) -> String { liveTrim(TermRegex.whitespace.replaceAll(s, " ")) }
  return ParsedMenu(
    title: flat(title),
    items: items.map { MenuItem(label: flat($0[0]), detail: $0.dropFirst().map(flat).joined(separator: " · ")) },
    current: current,
    filter: filter
  )
}
