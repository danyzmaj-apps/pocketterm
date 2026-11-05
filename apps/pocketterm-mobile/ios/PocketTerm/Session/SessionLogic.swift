import Foundation
import PocketTermKit

// The conversation page's logic that isn't drawing: prompts on their way and how they come back, the queue as the
// phone shows it, and the answer's Markdown cut into blocks.

/// How long a just-launched agent may take to report before the page says so.
let sessionStartWait: TimeInterval = 20

/// A session's name, as its page's title.
func sessionTitle(_ s: LiveSummary) -> String { s.title.isEmpty ? baseName(s.cwd) : s.title }

/// Why [agent]'s slash commands can't be sent from here.
func noCommandsText(_ agent: Agent) -> String {
  "Slash commands are typed into \(agent.label)\u{2019}s terminal window, and PocketTerm can\u{2019}t reach this one: it "
    + "isn\u{2019}t in kitty, tmux, WezTerm, iTerm2 or Ghostty. Run them on the computer."
}

/// "⊕ 2 images" and the names of the files a prompt took along.
func attachedExtras(images: Int, files: [String] = []) -> [String] {
  (images > 0 ? ["\u{2295} \(images) image\(images == 1 ? "" : "s")"] : []) + files
}

// MARK: - Prompts on their way

/// A prompt sent from the page: shown as the person's message until its item comes back in the transcript, and
/// sent again as it is.
final class Outgoing: Identifiable {
  init(_ text: String, _ attachments: [ChatAttachment], followUp: Bool, transcript: LiveView?) {
    self.text = text
    self.attachments = attachments
    self.followUp = followUp
    epoch = transcript?.epoch
    let items = transcript?.items ?? []
    last = items.last?.order ?? -1
    seen = Set(items.filter { $0.kind == .user }.map(\.id))
  }

  let text: String
  let attachments: [ChatAttachment]

  /// Sent to wait for the run to end.
  let followUp: Bool

  /// On its way to the computer.
  var sending = true

  /// Why it wasn't sent, when it wasn't.
  var problem: String?

  /// The id it waits under in the session's queue on the computer, when it went there.
  var queued: String?

  /// The transcript when it went: the person's items there already aren't this one coming back.
  let epoch: String?
  let last: Int
  let seen: Set<String>

  /// Whether user item [i] of a transcript in [epoch] came after this went.
  func sentBefore(_ i: LiveItem, _ epoch: String) -> Bool {
    !seen.contains(i.id) && (epoch != self.epoch || i.order > last)
  }

  /// Accepted, but waiting for the run to end: stays dimmed until the queue strip or the agent shows it.
  var waiting: Bool { !sending && problem == nil && (followUp || queued != nil) }
}

/// [s] with its runs of whitespace as single spaces, trimmed: how a prompt and the agent's copy of it compare.
func plainPrompt(_ s: String) -> String {
  s.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Which of [outgoing] (oldest first) have come back in transcript [v]: each is the first of the person's items
/// since it went, in order, whose text holds its own (the computer may add to it: files named as @path).
func cameBack(_ outgoing: [Outgoing], _ v: LiveView) -> Set<ObjectIdentifier> {
  guard !outgoing.isEmpty else { return [] }
  let items = v.items
  // From just after the oldest went; from the start once the transcript started over.
  var start = 0
  if outgoing.allSatisfy({ $0.epoch == v.epoch }) {
    let last = outgoing.map(\.last).min()!
    start = items.count
    while start > 0 && items[start - 1].order > last { start -= 1 }
  }
  var back = Set<ObjectIdentifier>()
  var next = start
  for o in outgoing {
    let want = plainPrompt(o.text)
    for j in next..<max(next, items.count) {
      let i = items[j]
      if i.kind != .user || !o.sentBefore(i, v.epoch) || !plainPrompt(i.text).contains(want) { continue }
      back.insert(ObjectIdentifier(o))
      next = j + 1
      break
    }
  }
  return back
}

/// What's left of [outgoing] to show: those whose item came back in [view] show as it, in their place; queued
/// ones show in the queue strip once [summary] lists them, and one that left it at rest went to the agent.
func stillOutgoing(_ outgoing: [Outgoing], view: LiveView?, summary s: LiveSummary?) -> [Outgoing] {
  var left = outgoing
  if let view, !left.isEmpty {
    let back = cameBack(left, view)
    left.removeAll { back.contains(ObjectIdentifier($0)) }
  }
  if let s, !left.isEmpty {
    let waiting = Set(s.queue.map(\.id))
    let atRest = !s.busy && s.ask == nil
    left.removeAll { o in o.queued.map { waiting.contains($0) || atRest } ?? false }
  }
  return left
}

// MARK: - The queue

/// A session's queue as the phone shows it: the computer's, with the moves and deletes made here ahead of it until
/// the computer's queue says the same.
final class QueueView {
  /// The order set here (ids), until the computer's queue has it.
  private(set) var order: [String]?

  /// Deleted or sent from here, until the computer's queue no longer has them.
  var gone: Set<String> = []

  /// The computer's [queue] in the order set here, and of those the ones that show.
  func items(_ queue: [LiveQueued]) -> (all: [LiveQueued], shown: [LiveQueued]) {
    let ids = queue.map(\.id)
    gone = gone.filter(ids.contains)
    if let o = order, ids.filter(o.contains) == o.filter(ids.contains) { order = nil }
    var byId: [String: LiveQueued] = [:]
    for q in queue where byId[q.id] == nil { byId[q.id] = q }
    let all: [LiveQueued] = order.map { o in o.compactMap { byId[$0] } + queue.filter { !o.contains($0.id) } } ?? queue
    return (all, all.filter { !gone.contains($0.id) })
  }

  /// Shows [id] at place [to] among [all] from now on; its place.
  @discardableResult
  func put(_ all: [LiveQueued], _ id: String, _ to: Int) -> Int {
    var o = all.map(\.id)
    o.removeAll { $0 == id }
    o.insert(id, at: min(max(to, 0), o.count))
    order = o
    return to
  }

  /// Shows the one shown at [from] at [to] (its place among [shown] once moved) from now on; its place among [all],
  /// those going too: before the one it now sits above, else after the one below.
  func drop(_ all: [LiveQueued], _ shown: [LiveQueued], _ from: Int, _ to: Int) -> Int {
    let id = shown[from].id
    var seen = shown.map(\.id)
    seen.remove(at: from)
    seen.insert(id, at: to)
    var o = all.map(\.id)
    o.removeAll { $0 == id }
    let at: Int
    if to + 1 < seen.count, let below = o.firstIndex(of: seen[to + 1]) {
      at = below
    } else if to > 0, let above = o.firstIndex(of: seen[to - 1]) {
      at = above + 1
    } else {
      at = min(to, o.count)
    }
    o.insert(id, at: at)
    order = o
    return o.firstIndex(of: id)!
  }

  /// The computer's order again: a move it refused.
  func forgetOrder() { order = nil }
}

/// Where SwiftUI's `onMove` destination (an index among the rows before the move) puts the row at [from], as its
/// place once moved.
func movedPlace(from: Int, destination: Int) -> Int { destination > from ? destination - 1 : destination }

/// Whether [q] can go into [s]'s queue again from here (a copy, an undo): only its text can be sent again, it isn't
/// a command (those are typed into the agent at once), and only a working agent queues it.
func requeueable(_ q: LiveQueued, in s: LiveSummary?) -> Bool {
  let text = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let s else { return false }
  return q.images == 0 && q.files.isEmpty && !q.cut && !text.isEmpty && !text.hasPrefix("/") && (s.busy || s.ask != nil)
}

// MARK: - Markdown

/// One item of a Markdown list: its marker ("•", "3."), its text (inline Markdown) and how deep it's nested.
struct MdListItem: Equatable {
  let marker: String
  var text: String
  let depth: Int
}

/// A block of an answer's Markdown, as the transcript draws it; the text in each is inline Markdown.
enum MdBlock: Equatable {
  case paragraph(String)
  case heading(level: Int, text: String)
  case code(language: String, text: String)
  case list([MdListItem])
  case quote(String)
  case table(header: [String], rows: [[String]])
  case rule
}

private let headingLine = /^(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$/
private let listLine = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/
private let ruleLine = /^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/
private let tableRule = /^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/

/// The cells of a table row: `| a | b |` as ["a", "b"].
private func tableCells(_ line: String) -> [String] {
  var s = line.trimmingCharacters(in: .whitespaces)
  if s.hasPrefix("|") { s.removeFirst() }
  if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
  return s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
}

/// The opening of a fenced code block: its fence (``` or ~~~, as long as written) and language.
private func fence(_ trimmed: String) -> (fence: String, language: String)? {
  for c in ["`", "~"] where trimmed.hasPrefix(c + c + c) {
    let marks = trimmed.prefix { String($0) == c }
    let language = trimmed.dropFirst(marks.count).trimmingCharacters(in: .whitespaces)
    // An inline run of backticks isn't a fence.
    if c == "`" && language.contains("`") { return nil }
    return (String(marks), language)
  }
  return nil
}

private func indentWidth(_ line: Substring) -> Int {
  line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
}

/// [text]'s Markdown cut into blocks: paragraphs (their line breaks kept, as the agent's terminal shows them),
/// headings, fenced code, lists, quotes, tables and rules. Anything else stays text.
func markdownBlocks(_ text: String) -> [MdBlock] {
  let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
  var blocks: [MdBlock] = []
  var paragraph: [Substring] = []
  var list: [MdListItem] = []
  var quote: [Substring] = []

  func flushParagraph() {
    if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
    paragraph = []
  }
  func flushList() {
    if !list.isEmpty { blocks.append(.list(list)) }
    list = []
  }
  func flushQuote() {
    if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
    quote = []
  }
  func flushAll() {
    flushParagraph()
    flushList()
    flushQuote()
  }

  var i = 0
  while i < lines.count {
    let line = lines[i]
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if let f = fence(trimmed) {
      flushAll()
      let indent = indentWidth(line)
      var code: [String] = []
      i += 1
      while i < lines.count {
        let l = lines[i]
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(f.fence) && t.allSatisfy({ String($0) == String(f.fence.first!) }) { break }
        var drop = 0
        for ch in l.prefix(indent) where ch == " " { drop += 1 }
        code.append(String(l.dropFirst(drop)))
        i += 1
      }
      i += 1
      blocks.append(.code(language: f.language, text: code.joined(separator: "\n")))
      continue
    }
    if trimmed.isEmpty {
      flushAll()
      i += 1
      continue
    }
    // A line of = or - under a paragraph makes it a heading.
    if !paragraph.isEmpty, list.isEmpty, quote.isEmpty, !trimmed.isEmpty,
      trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" })
    {
      let level = trimmed.first == "=" ? 1 : 2
      let text = paragraph.joined(separator: " ")
      paragraph = []
      blocks.append(.heading(level: level, text: text))
      i += 1
      continue
    }
    if let m = trimmed.wholeMatch(of: headingLine) {
      flushAll()
      blocks.append(.heading(level: m.1.count, text: String(m.2)))
      i += 1
      continue
    }
    if line.wholeMatch(of: ruleLine) != nil {
      flushAll()
      blocks.append(.rule)
      i += 1
      continue
    }
    if trimmed.hasPrefix(">") {
      flushParagraph()
      flushList()
      var rest = trimmed.dropFirst()
      if rest.first == " " { rest = rest.dropFirst() }
      quote.append(rest)
      i += 1
      continue
    }
    if let m = line.wholeMatch(of: listLine) {
      flushParagraph()
      flushQuote()
      let mark = String(m.2)
      let marker = mark.first!.isNumber ? String(mark.dropLast()) + "." : "\u{2022}"
      list.append(MdListItem(marker: marker, text: String(m.3), depth: indentWidth(m.1) / 2))
      i += 1
      continue
    }
    if line.contains("|"), i + 1 < lines.count, lines[i + 1].wholeMatch(of: tableRule) != nil,
      lines[i + 1].contains("-")
    {
      flushAll()
      let header = tableCells(String(line))
      var rows: [[String]] = []
      i += 2
      while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
        rows.append(tableCells(String(lines[i])))
        i += 1
      }
      blocks.append(.table(header: header, rows: rows))
      continue
    }
    if !list.isEmpty && indentWidth(line) > 0 {
      // An item's own next line.
      list[list.count - 1].text += "\n" + trimmed
    } else if !quote.isEmpty {
      quote.append(Substring(trimmed))
    } else {
      flushList()
      paragraph.append(line)
    }
    i += 1
  }
  flushAll()
  return blocks
}

/// [s]'s inline Markdown (emphasis, code, links), its line breaks kept; as it is when it doesn't parse.
func inlineMarkdown(_ s: String) -> AttributedString {
  let options = AttributedString.MarkdownParsingOptions(
    allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
    failurePolicy: .returnPartiallyParsedIfPossible)
  return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
}
