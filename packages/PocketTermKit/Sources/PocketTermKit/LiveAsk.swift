import Foundation

/// One question the agent asks (omp's `ask` tool, Claude Code's
/// AskUserQuestion).
public struct LiveQuestion: Sendable, Hashable {
  public let id: String
  public let question: String
  public let header: String
  public let options: [String]
  public let multi: Bool
  public let recommended: Int?

  public init(
    id: String, question: String, options: [String], header: String = "", multi: Bool = false,
    recommended: Int? = nil
  ) {
    self.id = id
    self.question = question
    self.options = options
    self.header = header
    self.multi = multi
    self.recommended = recommended
  }

  /// Nil where Dart's casts would throw (a field of the wrong type).
  public init?(json j: JSONObject) {
    guard let q = try? LiveQuestion(reading: j) else { return nil }
    self = q
  }

  init(reading j: JSONObject) throws {
    self.init(
      id: try liveString(j["id"]) ?? "",
      question: try liveString(j["question"]) ?? "",
      options: (try liveList(j["options"]) ?? []).map { o in liveDartString(o.object != nil ? o["label"] : o) },
      header: try liveString(j["header"]) ?? "",
      multi: j["multi"] == .bool(true),
      recommended: try liveInt(j["recommended"])
    )
  }

  public func toJson() -> JSONObject {
    var j: JSONObject = ["id": .string(id), "question": .string(question)]
    if !header.isEmpty { j["header"] = .string(header) }
    j["options"] = .strings(options)
    if multi { j["multi"] = true }
    if let recommended { j["recommended"] = .int(recommended) }
    return j
  }
}

public enum AskKind: String, CaseIterable, Sendable {
  case questions, approval, plan, menu
  public var name: String { rawValue }
}

/// One row of an agent's picker: its `label`, and what it shows under or
/// beside it (`detail`).
public struct MenuItem: Sendable, Hashable {
  public var label: String
  public var detail: String
  public init(label: String, detail: String) {
    self.label = label
    self.detail = detail
  }
}

/// The agent is waiting on the person: its questions, approval of `tool`
/// (`summary`: what it would do), its plan review (plan mode's last step) of
/// the plan `title`, or a picker a slash command opened (/resume, /model …)
/// titled `title`. A plan's `options`, a picker's `items` and the `selected`
/// row of either are read off the agent's screen by the Mac (none when it
/// couldn't read them); a picker with `filter` narrows as you type.
public struct LiveAsk: Sendable, Hashable {
  /// The tool call it belongs to.
  public let id: String
  public let kind: AskKind
  public let questions: [LiveQuestion]?
  public let tool: String
  public let summary: String
  public let title: String
  public let options: [String]
  public let items: [MenuItem]
  public let selected: Int
  public let filter: Bool

  private init(
    id: String, kind: AskKind, questions: [LiveQuestion]? = nil, tool: String = "", summary: String = "",
    title: String = "", options: [String] = [], items: [MenuItem] = [], selected: Int = 0, filter: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.questions = questions
    self.tool = tool
    self.summary = summary
    self.title = title
    self.options = options
    self.items = items
    self.selected = selected
    self.filter = filter
  }

  public static func questions(_ id: String, _ questions: [LiveQuestion]) -> LiveAsk {
    LiveAsk(id: id, kind: .questions, questions: questions)
  }

  public static func approval(_ id: String, tool: String, summary: String = "") -> LiveAsk {
    LiveAsk(id: id, kind: .approval, tool: tool, summary: summary)
  }

  public static func plan(_ id: String, title: String = "Plan", options: [String] = [], selected: Int = 0) -> LiveAsk {
    LiveAsk(id: id, kind: .plan, title: title, options: options, selected: selected)
  }

  public static func menu(_ id: String, title: String, items: [MenuItem], selected: Int = 0, filter: Bool = false)
    -> LiveAsk
  {
    LiveAsk(id: id, kind: .menu, title: title, items: items, selected: selected, filter: filter)
  }

  /// Nil where Dart's casts would throw: no string `id`, a field of the wrong type. An unknown kind reads
  /// as questions.
  public init?(json j: JSONObject) {
    guard let ask = try? LiveAsk(reading: j) else { return nil }
    self = ask
  }

  init(reading j: JSONObject) throws {
    switch j["kind"]?.string {
    case "approval":
      self = .approval(
        try liveRequiredString(j["id"]), tool: try liveString(j["tool"]) ?? "",
        summary: try liveString(j["summary"]) ?? "")
    case "plan":
      self = .plan(
        try liveRequiredString(j["id"]),
        title: try liveString(j["title"]) ?? "Plan",
        options: (try liveList(j["options"]) ?? []).map { liveDartString($0) },
        selected: try liveInt(j["selected"]) ?? 0)
    case "menu":
      let id = try liveRequiredString(j["id"])
      let title = try liveString(j["title"]) ?? ""
      let items = try (liveList(j["items"]) ?? []).map { i -> MenuItem in
        guard let o = i.object else { throw LiveCastError() }
        let label = o["label"].flatMap { $0.isNull ? nil : $0 }
        return MenuItem(label: label.map { liveDartString($0) } ?? "", detail: try liveString(o["detail"]) ?? "")
      }
      self = .menu(
        id, title: title, items: items, selected: try liveInt(j["selected"]) ?? 0, filter: j["filter"] == .bool(true))
    default:
      let id = try liveRequiredString(j["id"])
      self = .questions(
        id,
        try (liveList(j["questions"]) ?? []).map { q in
          guard let o = q.object else { throw LiveCastError() }
          return try LiveQuestion(reading: o)
        })
    }
  }

  public var isApproval: Bool { kind == .approval }
  public var isPlan: Bool { kind == .plan }
  public var isMenu: Bool { kind == .menu }

  /// What a notification says.
  public var text: String {
    switch kind {
    case .approval: "Approve \(tool)\(summary.isEmpty ? "" : ": \(summary)")?"
    case .plan: "Plan ready: \(title)"
    case .menu: title
    case .questions: questions!.map(\.question).joined(separator: "\n")
    }
  }

  public func toJson() -> JSONObject {
    switch kind {
    case .approval:
      var j: JSONObject = ["kind": "approval", "id": .string(id), "tool": .string(tool)]
      if !summary.isEmpty { j["summary"] = .string(summary) }
      return j
    case .plan:
      var j: JSONObject = ["kind": "plan", "id": .string(id), "title": .string(title)]
      if !options.isEmpty {
        j["options"] = .strings(options)
        j["selected"] = .int(selected)
      }
      return j
    case .menu:
      var j: JSONObject = [
        "kind": "menu", "id": .string(id), "title": .string(title),
        "items": .array(
          items.map { i in
            var o: JSONObject = ["label": .string(i.label)]
            if !i.detail.isEmpty { o["detail"] = .string(i.detail) }
            return .object(o)
          }),
        "selected": .int(selected),
      ]
      if filter { j["filter"] = true }
      return j
    case .questions:
      return ["kind": "ask", "id": .string(id), "questions": .array(questions!.map { .object($0.toJson()) })]
    }
  }
}

/// The person's answer to one `LiveQuestion`: the options picked (indexes)
/// and/or their own text.
public struct LiveAnswer: Sendable, Hashable {
  public let picks: [Int]
  public let custom: String?

  public init(picks: [Int] = [], custom: String? = nil) {
    self.picks = picks
    self.custom = custom
  }

  /// Nil where Dart's casts would throw (a pick that isn't an int, `custom` not a string).
  public init?(json j: JSONObject) {
    do {
      var picks: [Int] = []
      for p in try liveList(j["picks"]) ?? [] {
        guard let i = p.int else { return nil }
        picks.append(i)
      }
      self.init(picks: picks, custom: try liveString(j["custom"]))
    } catch {
      return nil
    }
  }

  public func toJson() -> JSONObject {
    var j: JSONObject = ["picks": .array(picks.map(JSON.int))]
    if let custom { j["custom"] = .string(custom) }
    return j
  }
}

/// Dart's `ArgumentError` in the live helpers: what was asked can't be done (an answer the dialog can't
/// take, a row that isn't there).
public struct LiveArgumentError: Error, Sendable, CustomStringConvertible {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
}

/// One step of answering an agent's dialog with the keyboard: keys (kitty's
/// names) pressed, or text typed.
public enum KeyStep: Sendable, Hashable {
  case keys([String])
  case typed(String)
  /// Wait for the agent to redraw before the next keys: opening or closing a
  /// typed answer and moving to the Submit tab take a moment, and keys sent
  /// before that are dropped.
  case settle
}

/// The keystrokes that answer `ask` in `agent`'s terminal UI (a question or
/// an approval). A plan review or a picker is answered from where its cursor
/// is now: `menuKeys`, or `claudeRowKey` for Claude Code's plan review.
public func answerKeys(_ ask: LiveAsk, answers: [LiveAnswer] = [], approve: Bool = false, agent: Agent = .omp)
  throws -> [KeyStep]
{
  if ask.isPlan || ask.isMenu { throw LiveArgumentError("A plan review or a picker is answered with menuKeys.") }
  if let questions = ask.questions {
    if answers.count != questions.count { throw LiveArgumentError("One answer per question.") }
    for (i, q) in questions.enumerated() {
      let a = answers[i]
      for p in a.picks where p < 0 || p >= q.options.count {
        throw LiveArgumentError("No option \(p) in \"\(q.question)\".")
      }
      if !q.multi && a.picks.count + (customText(a) == nil ? 0 : 1) != 1 {
        throw LiveArgumentError("Pick one answer for \"\(q.question)\".")
      }
    }
  }
  switch agent {
  case .omp: return ompKeys(ask, answers, approve: approve)
  case .claude:
    // Dart's `questions.single` fails on a question-less ask: Claude Code has no such dialog.
    if ask.questions?.isEmpty == true { throw LiveArgumentError("No questions.") }
    return claudeKeys(ask, answers, approve: approve)
  }
}

private func customText(_ a: LiveAnswer) -> String? {
  guard let custom = a.custom.map(liveTrim), !custom.isEmpty else { return nil }
  return custom
}

/// Steps that run consecutive key presses together, as one keys request.
private struct Steps {
  var steps: [KeyStep] = []

  mutating func press(_ keys: [String]) {
    if case .keys(let last)? = steps.last {
      steps[steps.count - 1] = .keys(last + keys)
    } else {
      steps.append(.keys(keys))
    }
  }

  mutating func add(_ step: KeyStep) { steps.append(step) }

  mutating func settle() {
    if steps.last != .settle { steps.append(.settle) }
  }
}

/// omp: the ask dialog lists each question's options and then "Other"; its
/// cursor stops at the ends, so going up past the top and then down picks a
/// row wherever the cursor started. Enter on a single-choice row answers and
/// moves on, Space toggles a multiple-choice row and Enter moves on; after
/// several questions a Submit tab takes a last Enter. A typed answer goes
/// through an editor; its Enter closes it, and the next keys wait for that
/// (`settle`). An approval is omp's Approve/Deny menu, which opens on Approve.
private func ompKeys(_ ask: LiveAsk, _ answers: [LiveAnswer], approve: Bool) -> [KeyStep] {
  if ask.isApproval { return [.keys(approve ? ["enter"] : ["down", "enter"])] }
  let questions = ask.questions!
  var s = Steps()
  var onSubmitTab = false
  for (i, q) in questions.enumerated() {
    let a = answers[i]
    let rows = q.options.count + 1
    func rowKeys(_ row: Int) -> [String] { Array(repeating: "up", count: rows) + Array(repeating: "down", count: row) }
    let custom = customText(a)
    if q.multi {
      for p in a.picks { s.press(rowKeys(p) + ["space"]) }
    }
    if let custom {
      s.press(rowKeys(q.options.count) + ["enter"])
      s.add(.settle)
      s.add(.typed(custom))
      s.press(["enter"])
      s.add(.settle)
      // A lone multiple-choice question goes to its Submit tab after a typed answer.
      if q.multi && questions.count == 1 { onSubmitTab = true }
    } else if q.multi {
      s.press(["enter"])
    } else {
      s.press(rowKeys(a.picks[0]) + ["enter"])
    }
  }
  if questions.count > 1 || onSubmitTab {
    s.settle()
    s.press(["enter"])
  }
  return s.steps
}

/// Claude Code numbers the rows of its dialogs from 1: a row's digit picks
/// it (or toggles it, in a multiple-choice question) wherever the cursor is.
public func claudeRowKey(_ row: Int) -> String { "\(row + 1)" }

/// Claude Code: a question lists its options, then "Type something", then
/// (multiple choice) a Submit row. A single-choice row's digit answers and
/// moves on; the typed row's digit opens it for typing, and Enter answers.
/// Multiple choice: digits toggle rows without moving the cursor from the
/// first, ↓ takes it to the typed row (whose text ticks it) and on to
/// Submit, where Enter moves on. Several questions, or a multiple-choice
/// one, end on a review tab whose first row submits. An approval opens on
/// Yes; Esc refuses.
private func claudeKeys(_ ask: LiveAsk, _ answers: [LiveAnswer], approve: Bool) -> [KeyStep] {
  if ask.isApproval { return [.keys([approve ? claudeRowKey(0) : "esc"])] }
  let questions = ask.questions!
  var s = Steps()
  for (i, q) in questions.enumerated() {
    let a = answers[i]
    let n = q.options.count
    let custom = customText(a)
    if i > 0 { s.settle() }
    if !q.multi {
      guard let custom else {
        s.press([claudeRowKey(a.picks[0])])
        continue
      }
      s.press([claudeRowKey(n)])
      s.add(.settle)
      s.add(.typed(custom))
      s.add(.settle)
      s.press(["enter"])
      continue
    }
    for p in a.picks { s.press([claudeRowKey(p)]) }
    guard let custom else {
      s.press(Array(repeating: "down", count: n + 1) + ["enter"])
      continue
    }
    s.press([claudeRowKey(n)] + Array(repeating: "down", count: n))
    s.add(.settle)
    s.add(.typed(custom))
    s.add(.settle)
    s.press(["down", "enter"])
  }
  if questions.count > 1 || questions[0].multi {
    s.settle()
    s.press([claudeRowKey(0)])
  }
  return s.steps
}

/// The keys that move a menu's cursor (a picker's, the plan review's) from
/// row `current` to `target`, then (with `enter`) pick it. Never above row
/// 0: the plan review's ↑ there leaves its options for the plan's text.
public func menuKeys(_ current: Int, _ target: Int, enter: Bool = true) throws -> [String] {
  if current < 0 || target < 0 { throw LiveArgumentError("No row \(target).") }
  return Array(repeating: "down", count: Swift.max(0, target - current))
    + Array(repeating: "up", count: Swift.max(0, current - target)) + (enter ? ["enter"] : [])
}
