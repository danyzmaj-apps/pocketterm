#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals

// The computer's orchestrator: an omp session PocketTerm starts in its own folder (beside cli.json,
// `LiveHub.orchestratorDir`) that the PocketTerm extension gives tools to see and steer the other sessions
// (integrations/omp/pocketterm-live.ts). Its calls come to the hub as `call` frames; this is what they answer.

/// The file in the orchestrator folder omp appends to its system prompt (`omp --append-system-prompt ORCHESTRATOR.md`).
public let orchestratorPromptFile = "ORCHESTRATOR.md"

/// What the orchestrator is told, beyond omp's own system prompt.
public let orchestratorInstructions = """
  You are the PocketTerm orchestrator on this computer. The person talks to you from their phone, often in short typed or spoken messages, to find out about and steer the other coding sessions running here.

  - Use pocketterm_sessions to see what is running, and pocketterm_read to look inside a session before saying anything about it. Never guess what a session is doing.
  - Answer briefly, for a phone screen: the answer first, sessions named by project and title, not by key.
  - Use pocketterm_prompt only when the person asks you to tell a session something or clearly agrees to it; when the wording isn't obvious, say what you will send. Use deliver "followUp" unless they want the session's current run redirected now.
  - Use pocketterm_stop only when the person asks you to stop a session.
  - You run in an empty folder. Don't edit files or run commands to answer questions about sessions: their transcripts are the source of truth.

  """

/// Whether a session in `cwd` is the orchestrator: `cwd` is `dir` (symlinks resolved).
public func isOrchestratorDir(_ cwd: String, _ dir: String?) -> Bool {
  guard let dir, !cwd.isEmpty else { return false }
  func real(_ x: String) -> String { realPath(x) ?? Paths.normalize(x) }
  return Paths.equals(real(cwd), real(dir))
}

/// Makes `dir` and (re)writes its `orchestratorPromptFile` with `orchestratorInstructions`.
public func prepareOrchestratorDir(_ dir: String) throws {
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  try Data(orchestratorInstructions.utf8).write(to: URL(fileURLWithPath: Paths.join(dir, orchestratorPromptFile)))
}

/// How a call's answer names `s`: `<project> "<title>" (<key>)`.
@MainActor
public func namedSession(_ hub: LiveHub, _ s: LiveSession) -> String {
  "\(orchestratorProject(hub, s)) \"\(orchestratorTitle(s))\" (\(s.key))"
}

@MainActor
private func orchestratorProject(_ hub: LiveHub, _ s: LiveSession) -> String {
  let name = hub.projectName(s)
  return !name.isEmpty ? name : (!s.cwd.isEmpty ? s.cwd : "(no folder)")
}

@MainActor
private func orchestratorTitle(_ s: LiveSession) -> String { s.title.isEmpty ? "(untitled)" : s.title }

@MainActor
private func orchestratorState(_ s: LiveSession) -> String {
  if s.ask != nil { return "waiting for an answer" }
  if s.busy { return "working" }
  if s.failed { return "last run failed" }
  return "idle"
}

private func ago(_ at: Date, _ now: Date) -> String {
  let seconds = Int(now.timeIntervalSince(at).rounded(.towardZero))
  let minutes = seconds / 60
  if minutes < 1 { return "\(min(max(seconds, 0), 59))s ago" }
  if minutes < 60 { return "\(minutes) min ago" }
  return "\(minutes / 60) h ago"
}

/// `s` cut to `max` characters, ending with `…` when cut.
private func clip(_ s: String, _ max: Int) -> String { dartLength(s) <= max ? s : "\(dartSubstring(s, 0, max))…" }

@MainActor
private func agentAndModel(_ s: LiveSession) -> String {
  ([s.agent.label] + (s.model.isEmpty ? [] : [s.model])).joined(separator: " ")
}

/// The `sessions` call's text: every session but the orchestrators.
@MainActor
public func sessionsText(_ hub: LiveHub, _ now: Date) -> String {
  func rank(_ s: LiveSession) -> Int { s.ask != nil ? 0 : (s.busy ? 1 : 2) }
  let sessions = hub.sessions.filter { !$0.orchestrator }.enumerated().sorted { a, b in
    let (ra, rb) = (rank(a.element), rank(b.element))
    if ra != rb { return ra < rb }
    if a.element.at != b.element.at { return a.element.at > b.element.at }
    return a.offset < b.offset
  }.map(\.element)
  if sessions.isEmpty { return "No other coding sessions are running on this computer." }
  var out = "\(sessions.count) coding session\(sessions.count == 1 ? "" : "s") on this computer:"
  for s in sessions {
    let summary = s.summary
    var parts = [s.key, orchestratorProject(hub, s), "\"\(orchestratorTitle(s))\"", agentAndModel(s), orchestratorState(s)]
    if let ctx = s.ctx { parts.append("ctx \(ctx)%") }
    if let cost = s.cost { parts.append("$\(String(format: "%.2f", cost))") }
    if !summary.queue.isEmpty { parts.append("\(summary.queue.count) queued\(summary.paused ? ", paused" : "")") }
    parts.append("active \(ago(s.at, now))")
    out += "\n- \(parts.joined(separator: " | "))"
    if let ask = s.ask { out += "\n  waiting on: \(ask.text)" }
    if !s.preview.isEmpty { out += "\n  last answer: \(s.preview)" }
  }
  return out
}

/// The most a `read` answer takes, in characters.
private let maxRead = 40000

/// The `read` call's text: `s`'s newest `last` items (1..200).
@MainActor
public func transcriptText(_ hub: LiveHub, _ s: LiveSession, last: Int) -> String {
  let header =
    "Session \(s.key) — \(orchestratorProject(hub, s)) · \"\(orchestratorTitle(s))\" · "
    + "\(agentAndModel(s)) · \(orchestratorState(s))"
  let items = s.log.items
  let take = min(max(min(max(last, 1), 200), 0), items.count)
  let newest = items[(items.count - take)...]
  var blocks: [String] = []
  var size = 0
  for i in newest.reversed() {
    let b = block(i)
    if size + dartLength(b) + 2 > maxRead { break }
    size += dartLength(b) + 2
    blocks.append(b)
  }
  let summary = s.summary
  var out = [header]
  if blocks.count < items.count || s.log.older { out.append("(earlier items left out)") }
  out += blocks.reversed()
  if let ask = s.ask { out.append("Waiting on: \(ask.text)") }
  if !summary.queue.isEmpty {
    out.append("Queued prompts\(summary.paused ? " (paused)" : ""):")
    for (n, q) in summary.queue.enumerated() { out.append("\(n + 1). \(clip(q.text, 300))") }
  }
  return out.joined(separator: "\n\n")
}

private func block(_ i: LiveItem) -> String {
  switch i.kind {
  case .user: return "[user] \(clip(i.text, 2000))\(i.images > 0 ? " (+\(i.images) images)" : "")"
  case .assistant: return "[assistant] \(clip(i.text, 6000))"
  case .tool:
    let what = dartTrim(TermRegex.whitespace.replaceAll(i.title.isEmpty ? i.args : i.title, " "))
    var lines = ["[tool \(i.tool) \(i.status.name)] \(clip(what, 200))"]
    if !i.output.isEmpty { lines.append(tail(i.output)) }
    return lines.joined(separator: "\n")
  case .notice: return "[notice] \(clip(i.text, 500))"
  }
}

/// A tool's output as `read` shows it: its last 12 lines, at most their last 1200 characters, indented.
private func tail(_ output: String) -> String {
  let lines = (dartTrimRight(output) as NSString).components(separatedBy: "\n")
  var text = lines[(lines.count > 12 ? lines.count - 12 : 0)...].joined(separator: "\n")
  if dartLength(text) > 1200 { text = "…\(dartSubstring(text, dartLength(text) - 1200))" }
  return (text as NSString).components(separatedBy: "\n").map { "  \($0)" }.joined(separator: "\n")
}
#endif
