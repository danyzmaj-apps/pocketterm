#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals

/// An image sent with a prompt: its bytes and type (`image/png`, `image/jpeg`).
public struct PromptImage: Sendable, Hashable {
  public let bytes: Data
  public let mimeType: String
  public init(bytes: Data, mimeType: String) {
    self.bytes = bytes
    self.mimeType = mimeType
  }
}

/// Where a session runs (`Terminals.locate`): from the `term` its extension reports, else (Ghostty) by its folder,
/// its title as its `agent` shows it in the window's, and the windows `claimed` by other sessions.
public typealias Locate = @MainActor (
  _ term: JSONObject?, _ cwd: String, _ title: String, _ agent: Agent, _ claimed: Set<String>
) async throws -> String?

public struct LiveException: Error, LocalizedError, CustomStringConvertible, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }
  public var errorDescription: String? { message }
}

/// Something worth a notification.
public enum LiveEvent: Sendable {
  /// The agent stopped and isn't about to go on by itself.
  case finished(LiveSession, summary: String)
  /// The agent asks a question, wants a tool approved, or has a plan for review.
  case asked(LiveSession, ask: LiveAsk)

  public var session: LiveSession {
    switch self {
    case .finished(let s, _), .asked(let s, _): s
    }
  }
}

/// Stops a synchronous listener of the hub (`LiveHub.onOps`, `LiveHub.onChange`).
@MainActor
public final class HubListener {
  private var stop: (() -> Void)?
  init(_ stop: @escaping () -> Void) { self.stop = stop }
  public func cancel() {
    stop?()
    stop = nil
  }
}

/// A request to an extension, sent: its reply, an error reply, or a failure once it times out or the session ends.
@MainActor
final class PendingReply {
  private var result: Result<JSONObject, Error>?
  private var waiter: CheckedContinuation<JSONObject, Error>?
  var timer: MainTimer?
  var onSettle: (() -> Void)?

  func settle(_ r: Result<JSONObject, Error>) {
    if result != nil { return }
    result = r
    timer?.cancel()
    timer = nil
    onSettle?()
    onSettle = nil
    if let w = waiter {
      waiter = nil
      w.resume(with: r)
    }
  }

  /// The reply; throws its `error` as a LiveException.
  func answer() async throws -> JSONObject {
    let reply: JSONObject
    if let result {
      reply = try result.get()
    } else {
      reply = try await withCheckedThrowingContinuation { waiter = $0 }
    }
    if let error = reply["error"]?.string { throw LiveException(error) }
    return reply
  }
}

/// One coding session, as its agent's extension reports it (integrations/: omp's pocketterm-live.ts, the Claude Code
/// plugin).
@MainActor
public final class LiveSession {
  init(_ link: LiveLink, _ key: String, _ log: LiveLog) {
    self.link = link
    self.key = key
    self.log = log
  }

  let link: LiveLink

  /// The terminal window it runs in (TerminalModel's keys: `kitty-<pid>/<id>`, `tmux:default/3` …), or `pid:<pid>`;
  /// a window found after it said hello (`LiveHub.relink`) is `window` only.
  public let key: String
  public internal(set) var log: LiveLog
  public internal(set) var agent: Agent = .omp

  /// The omp profile it runs in (`LiveSummary.profile`).
  public internal(set) var profile = ""
  public internal(set) var window: String?

  /// What its extension said of its terminal, to find `window` again.
  var term: JSONObject?
  public internal(set) var id = ""
  public internal(set) var title = ""
  public internal(set) var cwd = ""
  public internal(set) var model = ""
  public internal(set) var busy = false

  /// Its last run ended in an error (`LiveSummary.failed`); a new run clears it.
  public internal(set) var failed = false
  public internal(set) var ask: LiveAsk?
  public internal(set) var ctx: Int?

  /// What the session has cost so far, in US dollars (`LiveSummary.cost`).
  public internal(set) var cost: Double?
  public internal(set) var preview = ""
  public internal(set) var commands: [LiveCommand] = []
  public internal(set) var at = Date()

  /// Prompts waiting for a run to end, next first (`LiveHub.prompt`); `paused` holds them.
  var queue: [LiveQueuedPrompt] = []
  public internal(set) var paused = false

  /// Its folder is the orchestrator folder (`LiveHub.orchestratorDir`): it may make calls.
  public internal(set) var orchestrator = false

  /// The queue's next prompt went to the agent, which hasn't said yet that it started; `handoff` gives up on that.
  var handing = false
  var handoff: MainTimer?

  private var req = 0
  private var pending: [Int: PendingReply] = [:]

  public var summary: LiveSummary {
    LiveSummary(
      key: key, id: id, title: title, cwd: cwd, epoch: log.epoch, seq: log.seq, agent: agent, profile: profile,
      window: window, model: model, busy: busy, ask: ask, ctx: ctx, cost: cost, preview: preview, at: at,
      older: log.older, commands: commands, queue: queue.map(\.summary), paused: paused, failed: failed,
      orchestrator: orchestrator)
  }

  /// Sends request `type` now; its reply comes within `timeout` seconds, or it fails.
  func request(_ type: String, _ payload: JSONObject, timeout: TimeInterval) -> PendingReply {
    req += 1
    let req = req
    let reply = PendingReply()
    pending[req] = reply
    reply.onSettle = { [weak self] in self?.pending[req] = nil }
    reply.timer = MainTimer(timeout) { [weak self, weak reply] in
      reply?.settle(.failure(LiveException("\((self?.agent ?? .omp).label) did not answer.")))
    }
    var frame = payload
    frame["t"] = .string(type)
    frame["req"] = .int(req)
    link.send(frame.encoded())
    return reply
  }

  func reply(_ m: JSONObject) {
    guard let req = m["req"]?.int else { return }
    pending[req]?.settle(.success(m))
  }

  func fail() {
    let all = pending.values
    pending = [:]
    for c in all { c.settle(.failure(LiveException("The \(agent.label) session ended."))) }
  }
}

/// A prompt in a session's queue, as it will go to the agent.
@MainActor
final class LiveQueuedPrompt {
  init(_ id: String, _ text: String, images: [JSONObject], imageFiles: [String], docs: [String]) {
    self.id = id
    self.text = text
    self.images = images
    self.imageFiles = imageFiles
    self.docs = docs
  }

  let id: String

  /// What the person typed; `docs` are named after it as `@path` when it goes.
  var text: String

  /// For an agent that steers (omp): the images themselves; else saved on this computer for it to read.
  let images: [JSONObject]
  let imageFiles: [String]

  /// The files sent with it, saved on this computer (`PromptFiles`).
  let docs: [String]

  var empty: Bool { dartTrim(text).isEmpty && images.isEmpty && imageFiles.isEmpty && docs.isEmpty }

  var summary: LiveQueued {
    LiveQueued(id: id, text: text, images: images.count + imageFiles.count, files: docs.map(Paths.basename))
  }
}

/// The coding sessions on this computer: their extensions connect to the local API (LocalApi) and keep it up to
/// date; the terminal bridge passes them on to the phone.
@MainActor
public final class LiveHub: LiveEndpoint {
  /// `locate`: where a session runs (`Terminals.locate`, see `locate(using:)`); `windowOfTerm` by default. `files`:
  /// where files sent with prompts go; `images`: where images for an agent that reads them from disk go
  /// (`pocketterm-images` in the temp folder by default). The ones older than a day go now, and when more come.
  public init(locate: Locate? = nil, files: PromptFiles? = nil, images: String? = nil) {
    self.locate = locate ?? { term, _, _, _, _ in windowOfTerm(term) }
    self.files = files ?? PromptFiles()
    imageDir = images ?? Paths.join(systemTempDir(), "pocketterm-images")
    let promptFiles = self.files
    Task { await promptFiles.prune() }
    pruneImages()
  }

  /// `Terminals.locate` as a `Locate`.
  public static func locate(using terms: Terminals) -> Locate {
    { term, cwd, title, agent, claimed in
      await terms.locate(term, cwd: cwd, title: title, agent: agent, claimed: claimed)
    }
  }

  private let locate: Locate
  private let files: PromptFiles

  /// The sessions by key, in the order they came (Dart's map order).
  private var byKey: [String: LiveSession] = [:]
  private var order: [String] = []

  private func put(_ s: LiveSession) {
    if byKey.updateValue(s, forKey: s.key) == nil { order.append(s.key) }
  }

  private func drop(_ key: String) {
    if byKey.removeValue(forKey: key) != nil { order.removeAll { $0 == key } }
  }

  /// Transcript changes, per session.
  public var ops: AsyncStream<(LiveSession, [LiveOp])> { opsOut.stream() }
  private let opsOut = Broadcaster<(LiveSession, [LiveOp])>()

  /// A session came, went, or its summary changed.
  public var changes: AsyncStream<Void> { changesOut.stream() }
  private let changesOut = Broadcaster<Void>()

  public var events: AsyncStream<LiveEvent> { eventsOut.stream() }
  private let eventsOut = Broadcaster<LiveEvent>()

  private var listenerIds = 0
  private var opsListeners: [(id: Int, f: (LiveSession, [LiveOp]) -> Void)] = []
  private var changeListeners: [(id: Int, f: () -> Void)] = []

  /// Hears every transcript change as it happens (Dart's synchronous stream), before `ops`' listeners.
  public func onOps(_ f: @escaping @MainActor (LiveSession, [LiveOp]) -> Void) -> HubListener {
    listenerIds += 1
    let id = listenerIds
    opsListeners.append((id, f))
    return HubListener { [weak self] in self?.opsListeners.removeAll { $0.id == id } }
  }

  /// Hears every change as it happens (Dart's synchronous stream), before `changes`' listeners.
  public func onChange(_ f: @escaping @MainActor () -> Void) -> HubListener {
    listenerIds += 1
    let id = listenerIds
    changeListeners.append((id, f))
    return HubListener { [weak self] in self?.changeListeners.removeAll { $0.id == id } }
  }

  private func emitOps(_ s: LiveSession, _ ops: [LiveOp]) {
    for l in opsListeners { l.f(s, ops) }
    opsOut.send((s, ops))
  }

  private func changed() {
    for l in changeListeners { l.f() }
    changesOut.send(())
  }

  public var sessions: [LiveSession] { order.compactMap { byKey[$0] } }
  public subscript(key: String) -> LiveSession? { byKey[key] }

  /// PocketTerm's orchestrator folder, next to cli.json; set by LocalApi. Nil: no orchestrator.
  public var orchestratorDir: String?

  private static let pathParts = TermRegex(#"[\\/]"#)

  /// What notifications call `s`'s project: its folder's name, with the one above it when another session's folder
  /// has the same name (two checkouts called `api`); empty when its folder isn't known.
  public func projectName(_ s: LiveSession) -> String {
    func parts(_ cwd: String) -> [String] { Self.pathParts.split(cwd).filter { !$0.isEmpty } }
    let mine = parts(s.cwd)
    guard let last = mine.last else { return s.cwd == "/" ? "/" : "" }
    let clash = byKey.values.contains { o in
      o !== s && !sameText(o.cwd, s.cwd) && parts(o.cwd).last.map { sameText($0, last) } == true
    }
    return clash && mine.count > 1 ? "\(mine[mine.count - 2])/\(last)" : last
  }

  /// Serves one extension, whose JSON `frames` come in order over `link`, until they end. A frame this side can't
  /// read (an extension older or newer than the app, with fields missing or of another shape) is skipped; the
  /// session goes on.
  public func accept(_ frames: AsyncStream<String>, _ link: LiveLink) async {
    var session: LiveSession?
    for await frame in frames {
      do {
        guard case .object(let m) = try JSON.parse(frame) else { continue }
        if m["t"] == "hello" {
          session = try await hello(link, session, m)
        } else if let s = session, byKey[s.key] === s {
          try handle(s, m)
        }
      } catch {
        debugLog("PocketTerm: live session: a frame skipped: \(error)")
      }
    }
    if let s = session {
      s.fail()
      s.handoff?.cancel()
      if byKey[s.key] === s {
        drop(s.key)
        keepQueue(s)
        changed()
      }
    }
  }

  /// Sessions gone with prompts in their queue, by key: the same agent saying hello again in the same window soon
  /// (restarted, reconnected) takes them over.
  private var orphans: [String: (session: LiveSession, timer: MainTimer)] = [:]
  static let orphanFor: TimeInterval = 10 * 60

  private func keepQueue(_ s: LiveSession) {
    if s.queue.isEmpty && !s.handing { return }
    orphans.removeValue(forKey: s.key)?.timer.cancel()
    let key = s.key
    orphans[key] = (s, MainTimer(Self.orphanFor) { [weak self] in self?.orphans[key] = nil })
  }

  /// `to` takes over `from`'s queue, when they're the same agent.
  private static func takeQueue(_ to: LiveSession, _ from: LiveSession?) {
    guard let from, from !== to, from.agent == to.agent, !from.queue.isEmpty else { return }
    to.queue += from.queue
    to.paused = from.paused
    from.queue.removeAll()
  }

  /// The session's key is the window it runs in: where its `term` says (an older extension reports only kitty's, as
  /// `window`), else its pid. A `term` that names no window is trusted over `window`, which an extension also reads
  /// from KITTY_* variables leaked from a kitty that started the terminal (they'd name a window of that kitty). The
  /// same agent saying hello again stays where it is, under the same key.
  private func hello(_ link: LiveLink, _ current: LiveSession?, _ m: JSONObject) async throws -> LiveSession {
    let s = try castMap(m["session"]) ?? [:]
    let term = try castMap(m["term"])
    let agent = Agent.parse(m["agent"])
    let cwd = try castString(s["cwd"]) ?? ""
    let title = try castString(s["title"]) ?? ""
    // Read up front: a frame of the wrong shape changes nothing.
    let id = try castString(s["id"]) ?? ""
    let model = try castString(s["model"]) ?? ""
    let ctx = try castRounded(m["ctx"])
    let cost = try castNumber(m["cost"])
    var items: [LiveItem] = []
    for i in try castList(m["items"]) ?? [] {
      guard let o = i.object, o["id"]?.string != nil else { continue }
      guard let item = LiveItem(json: o) else { throw HubCastError(value: i, type: "LiveItem") }
      items.append(item)
    }
    var window: String?
    do {
      window = try await locate(term, cwd, title, agent, claimed(except: current))
    } catch {
      debugLog("PocketTerm: where a live session runs: \(error)")
    }
    if term == nil, window == nil { window = try castString(m["window"]) }
    let same = current.flatMap { byKey[$0.key] === $0 ? $0 : nil }
    if window == nil { window = same?.window }
    let key = same != nil && same!.window == window ? same!.key : window ?? "pid:\(dartInterpolated(m["pid"]))"
    let log = LiveLog(items, older: m["older"] == true)
    let session: LiveSession
    if let current, current.key == key, byKey[key] === current {
      // Another session in the same agent (/new, /resume, /clear): a new transcript.
      current.log = log
      session = current
    } else {
      let moved = current.flatMap { byKey[$0.key] === $0 ? $0 : nil }
      if let moved { drop(moved.key) }
      session = LiveSession(link, key, log)
      session.agent = agent
      // The same window's previous agent, if its connection hasn't closed yet.
      let old = byKey[key]
      if let old, old.link !== link { Task { await old.link.close() } }
      put(session)
      let orphan = orphans.removeValue(forKey: key)
      orphan?.timer.cancel()
      Self.takeQueue(session, moved)
      Self.takeQueue(session, old)
      Self.takeQueue(session, orphan?.session)
    }
    let profile = m["profile"]?.string
    session.agent = agent
    session.profile = agent == .omp && profile.map(isOmpProfile) == true ? profile! : ""
    session.window = window
    session.term = term
    session.id = id
    session.title = title
    session.cwd = cwd
    session.model = model
    session.busy = m["busy"] == true
    session.failed = false
    session.handing = false
    session.ctx = ctx
    session.cost = cost
    session.ask = nil
    session.commands = liveCommands(m["commands"])
    session.preview = Self.preview(log.items.last { $0.kind == .assistant }?.text ?? "")
    session.at = Date()
    session.orchestrator = isOrchestratorDir(cwd, orchestratorDir)
    session.handoff?.cancel()
    changed()
    drain(session)
    // A window claimed can leave another session the one window left.
    if window != nil { relinkSoon() }
    return session
  }

  /// The windows the sessions other than `except` run in.
  private func claimed(except: LiveSession?) -> Set<String> {
    Set(byKey.values.filter { $0 !== except }.compactMap(\.window))
  }

  private var relinking = false
  private var relinkAgain = false

  /// Looks again for the window of each session that has none, by what changed since its hello: a Ghostty window is
  /// told apart by its title (a session gets one after its first prompt) and by the windows other sessions run in. A
  /// window found becomes the session's `LiveSession.window`; its key stays the one the phone knows.
  public func relink() async {
    if relinking {
      relinkAgain = true
      return
    }
    relinking = true
    defer { relinking = false }
    var found = false
    repeat {
      relinkAgain = false
      found = false
      for s in sessions {
        if s.window != nil || s.term == nil { continue }
        var window: String?
        do {
          window = try await locate(s.term, s.cwd, s.title, s.agent, claimed(except: s))
        } catch {
          debugLog("PocketTerm: where a live session runs: \(error)")
        }
        // Gone, placed or beaten to it meanwhile.
        guard let window, s.window == nil, byKey[s.key] === s, !claimed(except: s).contains(window) else { continue }
        s.window = window
        found = true
        changed()
      }
      // A window claimed can leave another session the one window left.
    } while found || relinkAgain
  }

  private func relinkSoon() {
    if byKey.values.contains(where: { $0.window == nil && $0.term != nil }) { Task { await relink() } }
  }

  private static let markdownMarks = TermRegex("[`*_#>]")

  private static func preview(_ text: String) -> String {
    let line =
      (text as NSString).components(separatedBy: "\n").map { dartTrim(markdownMarks.replaceAll($0, "")) }
      .first { !$0.isEmpty } ?? ""
    return dartLength(line) > 140 ? "\(dartSubstring(line, 0, 139))…" : line
  }

  private func handle(_ s: LiveSession, _ m: JSONObject) throws {
    switch m["t"]?.string {
    case "item":
      guard let o = try castMap(m["item"]) else { throw HubCastError(value: m["item"], type: "Map<dynamic, dynamic>") }
      guard let item = LiveItem(json: o) else { throw HubCastError(value: m["item"], type: "LiveItem") }
      s.at = Date()
      emitOps(s, [s.log.upsert(item)])
      if item.kind == .assistant && !item.text.isEmpty {
        let preview = Self.preview(item.text)
        if !sameText(preview, s.preview) {
          s.preview = preview
          changed()
        }
      }
    case "append":
      let id = try castRequiredString(m["id"])
      if let op = s.log.append(id, try castString(m["text"]) ?? "") { emitOps(s, [op]) }
    case "busy":
      let busy = m["busy"] == true
      s.handing = false
      s.handoff?.cancel()
      s.busy = busy
      s.failed = !busy && m["failed"] == true
      s.at = Date()
      // Stopped (Stop from the phone, Esc at the computer): what waits stays until Resume.
      if !busy && m["stopped"] == true && !s.queue.isEmpty { s.paused = true }
      // The queue's next prompt goes now: the agent goes on, so nothing finished.
      if drainable(s) { return drain(s) }
      changed()
      let summary = try castString(m["summary"])
      if !busy, let summary { eventsOut.send(.finished(s, summary: summary)) }
    case "ask":
      var ask: LiveAsk?
      if let o = m["ask"]?.object {
        guard let a = LiveAsk(json: o) else { throw HubCastError(value: m["ask"], type: "LiveAsk") }
        ask = a
      }
      s.ask = ask
      changed()
      if let ask { eventsOut.send(.asked(s, ask: ask)) }
      drain(s)
    case "meta":
      if let title = m["title"]?.string, !sameText(title, s.title) {
        s.title = title
        if s.window == nil { relinkSoon() }
      }
      if let model = m["model"]?.string { s.model = model }
      if m.keys.contains("ctx") { s.ctx = try castRounded(m["ctx"]) }
      if m.keys.contains("cost") { s.cost = try castNumber(m["cost"]) }
      if m["commands"]?.array != nil { s.commands = liveCommands(m["commands"]) }
      changed()
    case "reply":
      s.reply(m)
    case "call":
      Task { await call(s, m) }
    default:
      break
    }
  }

  private func session(_ key: String) throws -> LiveSession {
    guard let s = byKey[key] else { throw LiveException("That session has ended.") }
    return s
  }

  /// Answers a call of the orchestrator's tools (`LiveSession.orchestrator` only): a `result` with the text for its
  /// model, or the error.
  private func call(_ s: LiveSession, _ m: JSONObject) async {
    let id = m["id"] ?? .null
    var text: String?
    var error: String?
    do {
      if !s.orchestrator { throw LiveException("Only the PocketTerm orchestrator can do that.") }
      switch m["op"]?.string {
      case "sessions":
        text = sessionsText(self, Date())
      case "read":
        text = transcriptText(self, try target(m), last: try castTruncated(m["last"]) ?? 30)
      case "prompt":
        let words = dartTrim(try castString(m["text"]) ?? "")
        if words.isEmpty { throw LiveException("Nothing to send.") }
        if words.dartStartsWith("/") { throw LiveException("Slash commands can't be sent from the orchestrator.") }
        let t = try target(m)
        let queued = try await prompt(t.key, words, followUp: m["deliver"] != "steer")
        text =
          queued == nil
          ? "Sent to \(namedSession(self, t))."
          : "Queued in \(namedSession(self, t)): it goes when its current run ends."
      case "stop":
        let t = try target(m)
        try await abort(t.key)
        let n = t.queue.count
        text =
          "Stopped \(namedSession(self, t))."
          + (n == 0
            ? "" : " Its \(n) queued prompt\(n == 1 ? "" : "s") wait\(n == 1 ? "s" : "") until the person resumes them.")
      default:
        throw LiveException("Unknown call.")
      }
    } catch let e as LiveException {
      error = e.message
    } catch let e {
      error = "\(e)"
    }
    guard byKey[s.key] === s else { return }
    var result: JSONObject = ["t": "result", "id": id]
    if let text { result["text"] = .string(text) }
    if let error { result["error"] = .string(error) }
    s.link.send(result.encoded())
  }

  /// The session a call names: not gone, not the orchestrator itself.
  private func target(_ m: JSONObject) throws -> LiveSession {
    let t = try session(try castString(m["session"]) ?? "")
    if t.orchestrator { throw LiveException("That is the orchestrator itself.") }
    return t
  }

  /// Replaces session `key`'s ask, while it's still `id` (nil: while there is none), with what this computer read
  /// off its screen: a plan review's options, a picker a slash command opened, or nil once it's gone. Not the agent
  /// asking, so no event. False when the session's ask has moved on.
  @discardableResult
  public func updateAsk(_ key: String, _ id: String?, _ ask: LiveAsk?) -> Bool {
    guard let s = byKey[key], s.ask?.id == id else { return false }
    s.ask = ask
    changed()
    drain(s)
    return true
  }

  /// Where images for an agent that reads them from disk (Claude Code) wait for it.
  private let imageDir: String

  /// Sends `text` (and `images` and `files`) as the person's prompt. While omp works it steers the run, or waits
  /// for the run to end with `followUp`; Claude Code always waits, and gets the images as files. `files` are saved
  /// on this computer (`PromptFiles`) and named in the text as `@path`, as one would at the computer: omp reads them
  /// in when it isn't working, else the agent opens them; Claude Code's extension lets it read them without asking.
  ///
  /// One that waits goes to the session's queue, under `id` (a new one by default), which it returns; it goes to the
  /// agent when a run ends, next in line. Nil when it went to the agent now.
  @discardableResult
  public func prompt(
    _ key: String, _ text: String, images: [PromptImage] = [], files: [PromptFile] = [], followUp: Bool = false,
    id: String? = nil
  ) async throws -> String? {
    let steers = try session(key).agent.steers
    let saved = try await self.files.save(files)
    let q = LiveQueuedPrompt(
      id ?? randomId(16), text,
      images: steers
        ? images.map { ["data": .string($0.bytes.base64EncodedString()), "mimeType": .string($0.mimeType)] } : [],
      imageFiles: steers ? [] : try saveImages(images),
      docs: saved)
    // As it is now: it may have started or ended a run, or said hello again, meanwhile.
    let s = try session(key)
    if (followUp || !steers) && (s.busy || s.ask != nil) {
      try Self.room(s, dartLength(q.text), another: true)
      s.queue.append(q)
      changed()
      return q.id
    }
    _ = try await send(s, q, deliver: followUp || !steers ? "followUp" : "steer").answer()
    return nil
  }

  /// At most this many prompts wait in a session's queue, with at most `maxQueuedText` characters of text together:
  /// the phones get every one whole with each state.
  public static let maxQueued = 20
  public static let maxQueuedText = 32000

  /// Throws unless `s`'s queue has room for `chars` more characters, and `another` prompt.
  private static func room(_ s: LiveSession, _ chars: Int, another: Bool = false) throws {
    if another && s.queue.count >= maxQueued {
      throw LiveException("The queue is full: \(maxQueued) prompts wait already.")
    }
    if s.queue.reduce(0, { $0 + dartLength($1.text) }) + chars > maxQueuedText {
      throw LiveException("That is more text than the queue holds: send it when the run ends.")
    }
  }

  private func send(_ s: LiveSession, _ q: LiveQueuedPrompt, deliver: String) -> PendingReply {
    var payload: JSONObject = [
      "text": .string(withMentions(q.text, q.docs)), "images": .array(q.images.map(JSON.object)),
      "deliver": .string(deliver),
    ]
    if !s.agent.steers { payload["files"] = .strings(q.imageFiles) }
    if !s.agent.steers && !q.docs.isEmpty { payload["docs"] = .strings(q.docs) }
    return s.request("prompt", payload, timeout: 15)
  }

  /// Whether `s`'s queue's next prompt can go: the agent is at rest and asks nothing, nothing holds the queue.
  private func drainable(_ s: LiveSession) -> Bool {
    !s.queue.isEmpty && !s.paused && !s.busy && s.ask == nil && !s.handing && byKey[s.key] === s
  }

  /// How long the agent may take to say it started on a prompt from the queue before it's taken to be at rest.
  public static let handoffWait: TimeInterval = 10

  /// Hands `s`'s queue's next prompt to the agent, if it can go (`drainable`). The session shows as working from
  /// here on, so it never looks done in between. One that doesn't go returns to the front, and the queue pauses.
  private func drain(_ s: LiveSession) {
    guard drainable(s) else { return }
    let q = s.queue.removeFirst()
    s.handing = true
    s.busy = true
    s.failed = false
    s.at = Date()
    if s.queue.isEmpty { s.paused = false }
    changed()
    let reply = send(s, q, deliver: "followUp")
    Task { await handOff(s, q, reply) }
  }

  private func handOff(_ s: LiveSession, _ q: LiveQueuedPrompt, _ reply: PendingReply) async {
    do {
      _ = try await reply.answer()
    } catch {
      debugLog("PocketTerm: a queued prompt did not go: \(error)")
      s.queue.insert(q, at: 0)
      s.paused = true
      if s.handing {
        s.handing = false
        s.busy = false
      }
      changed()
      return
    }
    if !s.handing { return }
    s.handoff?.cancel()
    s.handoff = MainTimer(Self.handoffWait) { [weak self, weak s] in
      guard let self, let s, s.handing else { return }
      s.handing = false
      s.busy = false
      if drainable(s) { return drain(s) }
      changed()
    }
  }

  private func queued(_ s: LiveSession, _ id: String) throws -> LiveQueuedPrompt {
    guard let q = s.queue.first(where: { $0.id == id }) else {
      throw LiveException("That prompt has gone to the agent already.")
    }
    return q
  }

  /// Replaces the text of prompt `id` in session `key`'s queue.
  public func editQueued(_ key: String, _ id: String, _ text: String) throws {
    let s = try session(key)
    let q = try queued(s, id)
    let was = q.text
    q.text = text
    if q.empty {
      q.text = was
      throw LiveException("A prompt needs some text, an image or a file.")
    }
    q.text = was
    try Self.room(s, dartLength(text) - dartLength(was))
    q.text = text
    changed()
  }

  /// Takes prompt `id` out of session `key`'s queue: it never goes.
  public func removeQueued(_ key: String, _ id: String) throws {
    let s = try session(key)
    let q = try queued(s, id)
    s.queue.removeAll { $0 === q }
    if s.queue.isEmpty { s.paused = false }
    changed()
  }

  /// Moves prompt `id` to place `to` (0: next) in session `key`'s queue.
  public func moveQueued(_ key: String, _ id: String, to: Int) throws {
    let s = try session(key)
    let q = try queued(s, id)
    s.queue.removeAll { $0 === q }
    // As Dart's `to.clamp(0, length - 1)` after the removal.
    s.queue.insert(q, at: min(max(to, 0), max(s.queue.count - 1, 0)))
    changed()
  }

  /// Sends prompt `id` out of session `key`'s queue now: it steers the run. omp only; Claude Code can't take a
  /// prompt while it works. One that doesn't go goes back where it was.
  public func sendQueuedNow(_ key: String, _ id: String) async throws {
    let s = try session(key)
    if !s.agent.steers { throw LiveException("\(s.agent.label) can't take a prompt while it works.") }
    let q = try queued(s, id)
    let at = s.queue.firstIndex { $0 === q }!
    s.queue.remove(at: at)
    if s.queue.isEmpty { s.paused = false }
    changed()
    do {
      _ = try await send(s, q, deliver: "steer").answer()
    } catch {
      s.queue.insert(q, at: min(at, s.queue.count))
      changed()
      throw error
    }
  }

  /// Holds session `key`'s queue, or lets it go on: its next prompt goes now if the agent is at rest.
  public func pauseQueue(_ key: String, paused: Bool) throws {
    let s = try session(key)
    s.paused = paused && !s.queue.isEmpty
    changed()
    drain(s)
  }

  private func saveImages(_ images: [PromptImage]) throws -> [String] {
    if images.isEmpty { return [] }
    // Private to this user.
    try makePrivateDir(imageDir)
    pruneImages()
    return try images.map { i in
      let path = Paths.join(imageDir, "\(randomId(12)).\(i.mimeType == "image/jpeg" ? "jpg" : "png")")
      try i.bytes.write(to: URL(fileURLWithPath: path))
      return path
    }
  }

  /// Deletes the images older than `PromptFiles.keep`.
  private func pruneImages() {
    pruneOld(in: imageDir, folders: false, label: "image cleanup")
  }

  /// Esc: stops what the agent is doing. What waits in its queue stays there until Resume.
  public func abort(_ key: String) async throws {
    let s = try session(key)
    if !s.queue.isEmpty && !s.paused {
      s.paused = true
      changed()
    }
    _ = try await s.request("abort", [:], timeout: 5).answer()
  }

  /// Fetches the items before the oldest one the hub has; they go out as ops.
  public func older(_ key: String, limit: Int = 150) async throws {
    let s = try session(key)
    if !s.log.older { return }
    let log = s.log
    let reply = try await s.request("older", ["limit": .int(limit)], timeout: 10).answer()
    // Another session started meanwhile: these belong to the old one.
    if s.log !== log { return }
    let items = try (castList(reply["items"]) ?? []).map { i -> LiveItem in
      guard let o = i.object, let item = LiveItem(json: o) else { throw HubCastError(value: i, type: "LiveItem") }
      return item
    }
    let ops = log.addOlder(items, more: reply["older"] == true)
    if !ops.isEmpty { emitOps(s, ops) }
    changed()
  }
}
#endif
