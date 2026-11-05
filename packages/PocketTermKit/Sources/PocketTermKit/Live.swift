import Foundation

// Terminal from the phone, version 2. Two kinds of things travel:
//
// - Coding sessions (omp, Claude Code: Agent.swift), live and structured.
//   Each agent's extension (apps/pocketterm-desktop/integrations/omp/pocketterm-live.ts, the
//   Claude Code plugin in apps/pocketterm-desktop/integrations/claude/) reports its session to the Mac app's local API
//   (the local API → the live hub) as transcript items. The phone
//   lays them out itself, so the Mac window's width doesn't matter.
// - terminal windows, as screens (kitty, tmux, WezTerm, Ghostty): shells and anything else,
//   and the agents' own menus when the phone needs them.
//
// Computer ↔ phone: the computer's topic on the server's WebSocket (its
// id; packages/pocketterm_server/PROTOCOL.md), one per
// computer. Nothing is stored on the server. Each payload below goes sealed
// with the computer's channel key (E2E.swift, the terminal channel):
// the server sees only `{v, n, c}`.
//
//   phone → Mac   hello  {from, session?, window?}   every 4 s while the app is in front;
//                        session: the live session it shows, window: the screen it shows
//   Mac → phone   state  {windows, sessions, projects, roots, home, agent, agents?, profiles?, error?}   on every hello
//                        and on changes;
//                        sessions: LiveSummary.toJson, its slash commands as `cmds` [[name, description?]], the
//                        prompts waiting in its queue as `queue` [LiveQueued.toJson] and `paused` while it's held,
//                        `failed` when its last run ended in an error, `orch` when it is the computer's orchestrator;
//                        agent: what a new session starts (Agent.name, the Mac's setting);
//                        agents: {agent: installed | outdated | missing | off} for the coding agents found on the
//                        computer; missing from an older computer
//                        roots: the Mac's Project folders; projects: the git repositories under them
//                        profiles: the computer's omp profiles besides the default, sorted; left out when none
//   phone → Mac   sync   {from, session, epoch?, since}   catch up after a gap or on opening
//   Mac → phone   items  {to, session, epoch, seq, reset, items, last}   answer to sync, in chunks
//   Mac → phone   live   {session, epoch, ops}   changes to watched sessions, batched
//   Mac → phone   screen {window, v, lines? | diff?, colors?}   a watched window's text (ANSI lines),
//                        whole (lines) or as a ScreenDiff on version v - 1
//   phone → Mac   run    {id, op, …}   see the terminal bridge's run handler; probe {window}: does its screen change
//                        over 2 s, switch {window, agent}: a screen-only agent window to its conversation (omp quits
//                        and runs omp -c, Claude Code types /reload-plugins); queue {session, do, item?, text?, to?}:
//                        changes the session's queue (do: edit item text, remove item, move item to, send item now
//                        as a steer, pause, resume); launch {cwd, agent, profile?} and create {root, name, agent,
//                        profile?}: a new window there, starting the agent when `agent`, in that omp profile when
//                        `profile` (one of the state's `profiles`); orchestrator {}: starts the computer's
//                        orchestrator (omp in PocketTerm's orchestrator folder) unless one runs; `ran {window}`
//   Mac → phone   ran    {id, error?, window?, busy?, queued?}   busy: probe's answer; queued: the id a prompt
//                        waits under in the session's queue, when it went there instead of to the agent
//
// The queue is the computer's (the live hub): a prompt sent to wait for the run's end (or any prompt, to an agent
// that can't steer, while it works) waits there, where the phone can edit, reorder and remove it, and goes to the
// agent when a run ends, one per run. A run that was stopped (Stop, Esc at the computer) pauses it until Resume.
//
// Extension ↔ Mac, as JSON frames with the local API's bearer token, over
// either transport (one connection per session, frames in order):
//
// - a WebSocket on ws://127.0.0.1:<port>/v1/live (omp), text frames;
// - HTTP long polls on POST /v1/live/http (Claude Code mods have no
//   WebSocket): {conn?, frames, wait?} → {conn, frames}. A request without
//   conn opens a connection (its frames start with hello); its frames go in
//   in order, the answer carries the Mac's frames, waiting up to 25 s for
//   some when `wait`. An unknown conn answers 404: the extension says hello
//   again. A connection nobody asks on for 60 s is gone.
//
//   ext → Mac  hello  {v, agent?, profile?, session: {id, title, cwd, model}, window?, pid, busy, ctx?, cost?, items,
//                     older, commands}   agent: Agent.name (omp when left out); profile: the omp profile it runs in
//                     (`omp --profile`), left out for the default; the session's newest items, oldest
//                     first; again after /new, /resume, /clear.
//                     commands: [{name, description?}] the agent's own slash commands, then the session's
//                     cost: what the session has spent so far, in US dollars (the agent's own tally, rounded to
//                     cents); left out or null when unknown
//   ext → Mac  meta   {title?, model?, ctx?, cost?, commands?}
//   ext → Mac  item   {item}   a new or changed item (whole)
//   ext → Mac  append {id, text}   streamed text added to an assistant item
//   ext → Mac  busy   {busy, summary?, stopped?, failed?}   summary: the last answer, when a run has really ended;
//                     stopped: the run was interrupted (Stop from the phone, Esc at the computer); failed: it ended
//                     in an error no retry got past (not a stop)
//   ext → Mac  ask    {ask?}   the agent waits for an answer (null: not anymore): LiveAsk.toJson; a plan
//                     review comes without options, which the Mac reads off the agent's screen
//   ext → Mac  reply  {req, error?, items?, older?}
//   Mac → ext  prompt {req, text, images: [{data, mimeType}], files?: [path], docs?: [path],
//                     deliver?: steer | followUp}
//                     files: the images saved on this Mac instead, for an agent that reads them from disk
//                     (Claude Code); docs: the files sent with the prompt, saved on this Mac and named in text as
//                     @path, which that agent may read without asking; an agent that can't steer queues every
//                     prompt for the run's end. The Mac's queue sends each prompt as a followUp: an agent at rest
//                     takes it as a prompt, one that started a run meanwhile keeps it for the run's end
//   Mac → ext  abort  {req}
//   ext → Mac  call   {id, op, …}   the orchestrator's tools, from a session in PocketTerm's orchestrator folder only:
//                     op sessions {}, read {session, last?}, prompt {session, text, deliver?: steer | followUp},
//                     stop {session}
//   Mac → ext  result {id, text? | error?}   a call's answer: text for the model, or why it failed
//   Mac → ext  older  {req, limit}   items before the oldest one sent

/// A session `key` as pushes and links carry it: with the computer it's on,
/// so a tap on the phone opens it there.
public func routedKey(_ desktopId: String, _ key: String) -> String { "\(desktopId)/\(key)" }

/// The computer and the session of a `routedKey`; nil if `s` isn't one.
public func splitRoutedKey(_ s: String) -> (desktop: String, key: String)? {
  let u = Array(s.utf16)
  // A computer id: 8 × [a-z0-9].
  guard u.count >= 10, u[8] == 0x2F, u[0..<8].allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) })
  else { return nil }
  return (desktop: String(decoding: u[0..<8], as: UTF16.self), key: liveSubstring(s, from: 9))
}

public enum ItemKind: String, CaseIterable, Sendable, Codable {
  case user, assistant, tool, notice
  public var name: String { rawValue }
}

public enum ToolStatus: String, CaseIterable, Sendable, Codable {
  case running, ok, error
  public var name: String { rawValue }
}

/// One entry of a session's transcript, as the phone draws it.
public struct LiveItem: Sendable, Hashable {
  public let id: String
  public let kind: ItemKind

  /// user, assistant (Markdown), notice: the text.
  public var text: String

  /// user: how many images came with it.
  public var images: Int

  /// tool: its name (`bash`, `edit`), what it says it's doing, its
  /// arguments in brief, the end of its output, how it went.
  public var tool: String
  public var title: String
  public var args: String
  public var output: String
  public var status: ToolStatus

  /// Its place in the transcript, and the hub's seq of its last change.
  public var order: Int
  public var seq: Int

  public init(
    id: String, kind: ItemKind, text: String = "", images: Int = 0, tool: String = "", title: String = "",
    args: String = "", output: String = "", status: ToolStatus = .running, order: Int = 0, seq: Int = 0
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.images = images
    self.tool = tool
    self.title = title
    self.args = args
    self.output = output
    self.status = status
    self.order = order
    self.seq = seq
  }

  /// Nil where Dart's casts would throw: no string `id`, or a field of the wrong type.
  public init?(json j: JSONObject) {
    guard let item = try? LiveItem(reading: j) else { return nil }
    self = item
  }

  init(reading j: JSONObject) throws {
    self.init(
      id: try liveRequiredString(j["id"]),
      kind: j["k"]?.string.flatMap(ItemKind.init(rawValue:)) ?? .notice,
      text: try liveString(j["t"]) ?? "",
      images: try liveInt(j["im"]) ?? 0,
      tool: try liveString(j["tl"]) ?? "",
      title: try liveString(j["ti"]) ?? "",
      args: try liveString(j["a"]) ?? "",
      output: try liveString(j["out"]) ?? "",
      status: j["st"]?.string.flatMap(ToolStatus.init(rawValue:)) ?? .ok,
      order: try liveInt(j["o"]) ?? 0,
      seq: try liveInt(j["s"]) ?? 0
    )
  }

  public func toJson() -> JSONObject {
    var j: JSONObject = ["id": .string(id), "k": .string(kind.name)]
    if !text.isEmpty { j["t"] = .string(text) }
    if images > 0 { j["im"] = .int(images) }
    if kind == .tool {
      j["tl"] = .string(tool)
      if !title.isEmpty { j["ti"] = .string(title) }
      if !args.isEmpty { j["a"] = .string(args) }
      if !output.isEmpty { j["out"] = .string(output) }
      j["st"] = .string(status.name)
    }
    j["o"] = .int(order)
    j["s"] = .int(seq)
    return j
  }

  /// This item as it comes back from JSON (what isn't sent falls back to its default, as on the phone).
  public func copy() -> LiveItem { LiveItem(json: toJson())! }
}

/// A prompt waiting in a session's queue on the computer (the live hub), for a run to end.
public struct LiveQueued: Sendable, Hashable {
  public let id: String

  /// What the person typed, without the files' `@path`s.
  public let text: String

  /// How many images go with it, and the names of its files.
  public let images: Int
  public let files: [String]

  /// `text` is only its start: the state was too big for it whole (a session no phone shows). Not to edit.
  public let cut: Bool

  public init(id: String, text: String, images: Int = 0, files: [String] = [], cut: Bool = false) {
    self.id = id
    self.text = text
    self.images = images
    self.files = files
    self.cut = cut
  }

  /// Nil where Dart's casts would throw (no string `id`, a field of the wrong type).
  public init?(json j: JSONObject) {
    do {
      self.init(
        id: try liveRequiredString(j["id"]),
        text: try liveString(j["t"]) ?? "",
        images: try liveInt(j["im"]) ?? 0,
        files: (try liveList(j["f"]) ?? []).compactMap(\.string),
        cut: j["c"] == .bool(true)
      )
    } catch {
      return nil
    }
  }

  public func toJson() -> JSONObject {
    var j: JSONObject = ["id": .string(id)]
    if !text.isEmpty { j["t"] = .string(text) }
    if images > 0 { j["im"] = .int(images) }
    if !files.isEmpty { j["f"] = .strings(files) }
    if cut { j["c"] = true }
    return j
  }
}

/// A change to a session's transcript: `item` whole, or `append` added to
/// item `id`'s text.
public struct LiveOp: Sendable, Hashable {
  public let seq: Int
  public let item: LiveItem?
  public let id: String?
  public let append: String?

  public static func item(_ seq: Int, _ item: LiveItem) -> LiveOp {
    LiveOp(seq: seq, item: item, id: nil, append: nil)
  }

  public static func append(_ seq: Int, _ id: String, _ append: String) -> LiveOp {
    LiveOp(seq: seq, item: nil, id: id, append: append)
  }

  private init(seq: Int, item: LiveItem?, id: String?, append: String?) {
    self.seq = seq
    self.item = item
    self.id = id
    self.append = append
  }

  /// Nil where Dart's casts would throw (no int `s`; an append without string `id` and `a`).
  public init?(json j: JSONObject) {
    let item: JSONObject?
    do { item = try liveMap(j["item"]) } catch { return nil }
    guard let seq = j["s"]?.int else { return nil }
    if let item {
      guard let parsed = LiveItem(json: item) else { return nil }
      self = .item(seq, parsed)
    } else {
      guard let id = j["id"]?.string, let a = j["a"]?.string else { return nil }
      self = .append(seq, id, a)
    }
  }

  public func toJson() -> JSONObject {
    if let item { return ["s": .int(seq), "item": .object(item.toJson())] }
    return ["s": .int(seq), "id": .string(id!), "a": .string(append!)]
  }
}

private func newEpoch() -> String {
  let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
  var rng = SystemRandomNumberGenerator()
  return String((0..<8).map { _ in digits[Int.random(in: 0..<36, using: &rng)] })
}

/// The character of `s` starting at code unit `i`: how many bytes it takes
/// inside a JSON string, UTF-8 encoded (quotes, backslashes and control
/// characters escaped as jsonEncode does), and how many code units it is.
private func jsonChar(_ s: [UInt16], _ i: Int) -> (bytes: Int, units: Int) {
  let c = s[i]
  if c == 0x22 || c == 0x5C { return (2, 1) }
  if c < 0x20 { return ([0x08, 0x09, 0x0A, 0x0C, 0x0D].contains(c) ? 2 : 6, 1) }
  if c < 0x80 { return (1, 1) }
  if c < 0x800 { return (2, 1) }
  if c & 0xFC00 == 0xD800, i + 1 < s.count, s[i + 1] & 0xFC00 == 0xDC00 { return (4, 2) }
  // A lone surrogate is escaped.
  if c & 0xF800 == 0xD800 { return (6, 1) }
  return (3, 1)
}

/// How many bytes `s` takes inside a JSON string, UTF-8 encoded.
public func jsonBytes(_ s: String) -> Int { jsonBytes(utf16: Array(s.utf16)) }

/// `jsonBytes` of a string given as UTF-16 code units, which may hold lone surrogates (a Swift String can't).
public func jsonBytes(utf16 s: [UInt16]) -> Int {
  var n = 0
  var i = 0
  while i < s.count {
    let (bytes, units) = jsonChar(s, i)
    n += bytes
    i += units
  }
  return n
}

/// The start of `s` that takes at most `max` bytes as JSON (`jsonBytes`),
/// never splitting a character.
private func headBytes(_ s: String, _ max: Int) -> String {
  let u = Array(s.utf16)
  var n = 0
  var i = 0
  while i < u.count {
    let (bytes, units) = jsonChar(u, i)
    n += bytes
    if n > max { return String(decoding: u[0..<i], as: UTF16.self) }
    i += units
  }
  return s
}

/// The end of `s` that takes at most `max` bytes as JSON, never splitting a
/// character.
private func tailBytes(_ s: String, _ max: Int) -> String {
  let u = Array(s.utf16)
  var n = 0
  var end = u.count
  while end > 0 {
    let pair = end >= 2 && u[end - 1] & 0xFC00 == 0xDC00 && u[end - 2] & 0xFC00 == 0xD800
    let start = pair ? end - 2 : end - 1
    n += jsonChar(u, start).bytes
    if n > max { return String(decoding: u[end...], as: UTF16.self) }
    end = start
  }
  return s
}

/// How an item's text that was too long for the phone ends.
public let cutNote = "\n\n… (too long to show here: the rest is on the computer)"

/// The most JSON bytes an item's text takes on the way to the phone, with
/// `cutNote`; its tool output, arguments and title take less. An item
/// then always fits in one message: the server closes a socket on a frame
/// over 256 KiB, and sealing grows a message by a third (E2E.swift).
public let maxItemTextBytes = 64 * 1024
let maxOutputBytes = 16 * 1024
let maxArgsBytes = 4 * 1024
let maxTitleBytes = 1024

/// `s` cut to its first `max` bytes, ending with `cutNote`.
private func clipText(_ s: String, _ max: Int) -> String {
  jsonBytes(s) <= max ? s : headBytes(s, max - jsonBytes(cutNote)) + cutNote
}

/// The Mac's copy of one session's transcript. Every change gets the next
/// `seq`; a phone that has seen up to some seq catches up with `since`.
/// `epoch` changes when the transcript starts over (another session in that
/// omp, the extension reconnected), and a phone then drops what it has.
/// An item too big for one message is cut (`maxItemTextBytes`): its text
/// keeps its start, a tool's output its end.
public final class LiveLog {
  public let epoch: String

  /// The most items kept; the oldest go first (and `older` turns true).
  public let cap: Int
  public private(set) var seq = 0

  /// The extension has items older than the oldest here.
  public private(set) var older: Bool

  private var byId: [String: LiveItem] = [:]

  /// Each item's text size as JSON (`jsonBytes`), kept up as text streams in.
  private var textBytes: [String: Int] = [:]
  private var next = 0
  private var min = 0

  public init(_ snapshot: [LiveItem], older: Bool, cap: Int = 3000, epoch: String? = nil) {
    self.older = older
    self.cap = cap
    self.epoch = epoch ?? newEpoch()
    for item in snapshot { add(item) }
    trim()
  }

  /// Oldest first.
  public var items: [LiveItem] { byId.values.sorted { $0.order < $1.order } }

  /// A copy of `item` cut to what fits in a message.
  private func fit(_ item: LiveItem) -> LiveItem {
    var copy = item.copy()
    copy.text = clipText(item.text, maxItemTextBytes)
    copy.title = clipText(item.title, maxTitleBytes)
    copy.args = clipText(item.args, maxArgsBytes)
    if jsonBytes(copy.output) > maxOutputBytes { copy.output = "…" + tailBytes(copy.output, maxOutputBytes - 3) }
    textBytes[copy.id] = jsonBytes(copy.text)
    return copy
  }

  @discardableResult
  private func add(_ item: LiveItem) -> LiveItem {
    let old = byId[item.id]
    var copy = fit(item)
    if let old {
      copy.order = old.order
    } else {
      copy.order = next
      next += 1
    }
    seq += 1
    copy.seq = seq
    byId[item.id] = copy
    return copy
  }

  /// `item`, new or changed. The op carries a snapshot: later appends go in
  /// ops of their own.
  public func upsert(_ item: LiveItem) -> LiveOp {
    let copy = add(item)
    trim()
    return .item(copy.seq, copy.copy())
  }

  /// Streamed `text` added to `id`; nil if there's no such item, or its
  /// text was already cut. Text past `maxItemTextBytes` is cut.
  public func append(_ id: String, _ text: String) -> LiveOp? {
    let had = textBytes[id] ?? 0
    guard var item = byId[id], !text.isEmpty, !liveHasSuffix(item.text, cutNote) else { return nil }
    var add = text
    var bytes = jsonBytes(text)
    if had + bytes > maxItemTextBytes {
      add = headBytes(text, Swift.max(0, maxItemTextBytes - had - jsonBytes(cutNote))) + cutNote
      bytes = jsonBytes(add)
    }
    textBytes[id] = had + bytes
    item.text += add
    seq += 1
    item.seq = seq
    byId[id] = item
    return .append(seq, id, add)
  }

  /// Items from before the oldest one here (oldest first), placed above it.
  /// The ops come in seq order, newest item first.
  public func addOlder(_ items: [LiveItem], more: Bool) -> [LiveOp] {
    older = more
    var ops: [LiveOp] = []
    for item in items.reversed() {
      if byId[item.id] != nil { continue }
      var copy = fit(item)
      min -= 1
      copy.order = min
      seq += 1
      copy.seq = seq
      byId[copy.id] = copy
      ops.append(.item(seq, copy.copy()))
    }
    return ops
  }

  /// Items changed after `since`, oldest first.
  public func since(_ since: Int) -> [LiveItem] { items.filter { $0.seq > since } }

  private func trim() {
    guard byId.count > cap else { return }
    for i in items.prefix(byId.count - cap) {
      byId[i.id] = nil
      textBytes[i.id] = nil
    }
    min = items.first!.order
    older = true
  }
}

/// The phone's copy of one session's transcript, kept up with `LiveLog`'s
/// ops and catch-ups, and cached on disk between launches. Like `LiveLog`,
/// it keeps at most `cap` items: the oldest go as newer ones come (and
/// `older` turns true, the Mac may still have them).
public final class LiveView {
  public private(set) var epoch: String
  public private(set) var seq: Int
  public private(set) var older: Bool
  public let cap: Int
  private var byId: [String: LiveItem] = [:]
  /// `items` sorted, and each id's place in it; nil once it needs sorting again.
  private var sorted: [LiveItem]?
  private var sortedAt: [String: Int] = [:]

  /// The newest item's order: one past it grows the transcript, one before
  /// it is an earlier message paged in (kept, though past `cap`).
  private var newest: Int?

  public init(epoch: String, seq: Int = 0, older: Bool = false, cap: Int = 3000, items: [LiveItem] = []) {
    self.epoch = epoch
    self.seq = seq
    self.older = older
    self.cap = cap
    for i in items { put(i) }
    trim()
  }

  /// The disk cache's copy (`toJson`); nil where Dart's casts would throw.
  public convenience init?(json j: JSONObject) {
    guard let epoch = j["epoch"]?.string, let seq = j["seq"]?.int, let list = j["items"]?.array else { return nil }
    var items: [LiveItem] = []
    for i in list {
      guard let o = i.object, let item = LiveItem(json: o) else { return nil }
      items.append(item)
    }
    self.init(epoch: epoch, seq: seq, older: j["older"] == .bool(true), items: items)
  }

  private func put(_ i: LiveItem) {
    byId[i.id] = i
    if let n = newest, n >= i.order { return }
    newest = i.order
  }

  /// Past `cap`: the oldest go.
  private func trim() {
    guard byId.count > cap else { return }
    let all = items
    for i in all.prefix(all.count - cap) { byId[i.id] = nil }
    sorted = nil
    older = true
  }

  /// Oldest first.
  public var items: [LiveItem] {
    if let sorted { return sorted }
    let s = byId.values.sorted { $0.order < $1.order }
    sorted = s
    sortedAt = Dictionary(uniqueKeysWithValues: s.enumerated().map { ($1.id, $0) })
    return s
  }

  /// Applies live ops; false if one is missing or the epoch moved on (catch
  /// up with a sync then). Ops already seen are skipped.
  @discardableResult
  public func apply(_ epoch: String, _ ops: [LiveOp]) -> Bool {
    guard epoch == self.epoch else { return false }
    var grew = false
    for op in ops {
      if op.seq <= seq { continue }
      if op.seq != seq + 1 { return false }
      if let item = op.item {
        let old = byId[item.id]
        if old == nil, newest == nil || item.order > newest! { grew = true }
        put(item)
        // The sorted list holds the old copy: swap it in place, or sort again.
        if let old, old.order == item.order, sorted != nil, let at = sortedAt[item.id] {
          sorted![at] = item
        } else {
          sorted = nil
        }
      } else {
        guard let id = op.id, var target = byId[id] else { return false }
        target.text += op.append!
        byId[id] = target
        if sorted != nil, let at = sortedAt[id] { sorted![at] = target }
      }
      seq = op.seq
    }
    if grew { trim() }
    return true
  }

  /// A catch-up from the Mac: `items` changed up to `seq` (`reset`: all of
  /// them, in a new `epoch`). `last` is the final chunk of the answer.
  public func catchUp(epoch: String, seq: Int, reset: Bool, items: [LiveItem], last: Bool, older: Bool? = nil) {
    if reset && self.epoch != epoch {
      self.epoch = epoch
      self.seq = 0
      byId.removeAll()
      newest = nil
    } else if epoch != self.epoch {
      return
    }
    for i in items { put(i) }
    sorted = nil
    if let older { self.older = older }
    trim()
    if last && seq > self.seq { self.seq = seq }
  }

  /// The newest `keep` items, for the disk cache. Dropping older ones makes
  /// `older` true: the Mac has them.
  public func toJson(keep: Int = 600) -> JSONObject {
    let all = items
    let kept = all.count > keep ? Array(all.suffix(keep)) : all
    return [
      "epoch": .string(epoch),
      "seq": .int(seq),
      "older": .bool(older || kept.count < all.count),
      "items": .array(kept.map { .object($0.toJson()) }),
    ]
  }
}

/// `items` split into lists whose JSON stays under `maxBytes` each: sealed
/// (E2E.swift) and in base64 a message grows by a third, and the server
/// closes a socket on a frame over 256 KB.
public func chunkJson(_ items: [JSONObject], maxBytes: Int = 40000) -> [[JSONObject]] {
  var out: [[JSONObject]] = []
  var current: [JSONObject] = []
  var size = 0
  for i in items {
    let n = i.encoded().utf8.count + 1
    if !current.isEmpty && size + n > maxBytes {
      out.append(current)
      current = []
      size = 0
    }
    current.append(i)
    size += n
  }
  if !current.isEmpty || out.isEmpty { out.append(current) }
  return out
}

// MARK: - Dart semantics the live code relies on

/// A failed Dart cast (`j['x'] as String`): the value isn't of the type.
struct LiveCastError: Error {}

/// `v as String?`.
func liveString(_ v: JSON?) throws -> String? {
  switch v {
  case nil, .null?: return nil
  case .string(let s)?: return s
  default: throw LiveCastError()
  }
}

/// `v as String`.
func liveRequiredString(_ v: JSON?) throws -> String {
  guard let s = try liveString(v) else { throw LiveCastError() }
  return s
}

/// `v as int?`.
func liveInt(_ v: JSON?) throws -> Int? {
  switch v {
  case nil, .null?: return nil
  case .int(let i)?: return i
  default: throw LiveCastError()
  }
}

/// `v as List?`.
func liveList(_ v: JSON?) throws -> [JSON]? {
  switch v {
  case nil, .null?: return nil
  case .array(let a)?: return a
  default: throw LiveCastError()
  }
}

/// `v as Map?`.
func liveMap(_ v: JSON?) throws -> JSONObject? {
  switch v {
  case nil, .null?: return nil
  case .object(let o)?: return o
  default: throw LiveCastError()
  }
}

/// `'$v'`: a JSON value as Dart's `toString` prints it.
func liveDartString(_ v: JSON?) -> String {
  switch v {
  case nil, .null?: return "null"
  case .bool(let b)?: return b ? "true" : "false"
  case .int(let i)?: return String(i)
  case .double(let d)?: return JSON.dartDouble(d)
  case .string(let s)?: return s
  case .array(let a)?: return "[" + a.map { liveDartString($0) }.joined(separator: ", ") + "]"
  case .object(let o)?: return "{" + o.keys.sorted().map { "\($0): \(liveDartString(o[$0]))" }.joined(separator: ", ") + "}"
  }
}

/// Dart's `substring(from)` (UTF-16 offsets).
func liveSubstring(_ s: String, from: Int, to: Int? = nil) -> String {
  let ns = s as NSString
  let end = to ?? ns.length
  return ns.substring(with: NSRange(location: from, length: end - from))
}

/// Dart's `length`.
func liveLength(_ s: String) -> Int { (s as NSString).length }

/// Dart's `startsWith`, `endsWith`, `contains` and `==`: code unit by code unit (Swift's compare
/// canonically equivalent strings equal, and a prefix must end on a character boundary).
func liveHasPrefix(_ s: String, _ prefix: String) -> Bool { s.utf16.starts(with: prefix.utf16) }
func liveHasSuffix(_ s: String, _ suffix: String) -> Bool { s.utf16.reversed().starts(with: suffix.utf16.reversed()) }
func liveSame(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
func liveContains(_ s: String, _ part: String) -> Bool {
  let h = Array(s.utf16)
  let n = Array(part.utf16)
  if n.isEmpty { return true }
  if n.count > h.count { return false }
  for start in 0...(h.count - n.count) where h[start] == n[0] && h[start..<(start + n.count)].elementsEqual(n) {
    return true
  }
  return false
}

/// Dart's `String.trim()` whitespace.
private func isTrimSpace(_ c: UInt16) -> Bool {
  switch c {
  case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
  default: false
  }
}

/// Dart's `trim()`.
func liveTrim(_ s: String) -> String {
  let u = Array(s.utf16)
  var a = 0
  var b = u.count
  while a < b, isTrimSpace(u[a]) { a += 1 }
  while b > a, isTrimSpace(u[b - 1]) { b -= 1 }
  return a == 0 && b == u.count ? s : String(decoding: u[a..<b], as: UTF16.self)
}

/// `s.length - s.trimLeft().length`.
func liveIndent(_ s: String) -> Int {
  var n = 0
  for c in s.utf16 {
    guard isTrimSpace(c) else { break }
    n += 1
  }
  return n
}

/// Dart's `split('\n')`.
func liveSplitLines(_ s: String) -> [String] { (s as NSString).components(separatedBy: "\n") }
