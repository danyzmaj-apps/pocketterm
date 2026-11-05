import Foundation

/// One of the agent's slash commands, without its `/`.
public struct LiveCommand: Sendable, Hashable {
  public var name: String
  public var description: String
  public init(name: String, description: String = "") {
    self.name = name
    self.description = description
  }
}

/// The extension's `commands` ([{name, description?}]).
public func liveCommands(_ json: JSON?) -> [LiveCommand] {
  guard let list = json?.array else { return [] }
  return list.compactMap { c in
    guard let name = c["name"]?.string else { return nil }
    return LiveCommand(name: name, description: c["description"]?.string ?? "")
  }
}

private let anySpace = TermRegex("[\(jsSpaceChars)]")

/// The `commands` the composer offers for `text` (`/` and the start of a
/// name), at most `max`: names that start with what was typed, then names
/// that contain it, each in the agent's order. None once there's a space.
public func matchCommands(_ commands: [LiveCommand], _ text: String, max: Int = 6) -> [LiveCommand] {
  guard liveHasPrefix(text, "/"), !anySpace.hasMatch(text) else { return [] }
  let q = liveSubstring(text, from: 1).lowercased()
  let names = commands.map { $0.name.lowercased() }
  let starts = commands.indices.filter { liveHasPrefix(names[$0], q) }
  let contains = commands.indices.filter { !liveHasPrefix(names[$0], q) && liveContains(names[$0], q) }
  return (starts + contains).prefix(Swift.max(0, max)).map { commands[$0] }
}

/// A live session in the phone's list.
public struct LiveSummary: Sendable, Hashable {
  /// Stable for the agent's process: its terminal window's key (`kitty-<pid>/<id>`,
  /// `tmux:default/3` …), or `pid:<pid>` when its window can't be told. What the
  /// phone opens and notifications point at.
  public var key: String

  /// The agent's session id (changes on /new, /resume, /clear).
  public var id: String

  /// Which coding agent this is.
  public var agent: Agent

  /// The omp profile it runs in (`omp --profile`); "" for the default and for Claude Code.
  public var profile: String
  public var window: String?
  public var title: String
  public var cwd: String
  public var model: String
  public var busy: Bool
  public var ask: LiveAsk?

  /// How full the context window is, in percent.
  public var ctx: Int?

  /// What the session has spent so far, in US dollars, as its agent tallies it.
  public var cost: Double?

  /// The last answer's first line.
  public var preview: String

  /// The last change, in milliseconds since the epoch (kept as the wire's int so it goes back unchanged).
  public var atMilliseconds: Int?
  public var epoch: String
  public var seq: Int
  public var older: Bool

  /// The agent's slash commands, for the composer.
  public var commands: [LiveCommand]

  /// Prompts waiting on the computer for the run to end, next first; `paused` holds them (a stopped run, Pause).
  public var queue: [LiveQueued]
  public var paused: Bool

  /// The last run ended in an error (the answer broke off with one; not a stop, and no retry got past it). The next
  /// run clears it.
  public var failed: Bool

  /// Started by PocketTerm as this computer's orchestrator (an omp session in PocketTerm's orchestrator folder): the
  /// phone shows it in its own bar, not in the list.
  public var orchestrator: Bool

  public init(
    key: String, id: String, title: String, cwd: String, epoch: String, seq: Int, agent: Agent = .omp,
    profile: String = "", window: String? = nil, model: String = "", busy: Bool = false, ask: LiveAsk? = nil,
    ctx: Int? = nil, cost: Double? = nil, preview: String = "", at: Date? = nil, older: Bool = false,
    commands: [LiveCommand] = [], queue: [LiveQueued] = [], paused: Bool = false, failed: Bool = false,
    orchestrator: Bool = false
  ) {
    self.key = key
    self.id = id
    self.title = title
    self.cwd = cwd
    self.epoch = epoch
    self.seq = seq
    self.agent = agent
    self.profile = profile
    self.window = window
    self.model = model
    self.busy = busy
    self.ask = ask
    self.ctx = ctx
    self.cost = cost
    self.preview = preview
    self.atMilliseconds = at.map(millisecondsSinceEpoch)
    self.older = older
    self.commands = commands
    self.queue = queue
    self.paused = paused
    self.failed = failed
    self.orchestrator = orchestrator
  }

  /// The last change.
  public var at: Date? {
    get { atMilliseconds.map(dateFromMilliseconds) }
    set { atMilliseconds = newValue.map(millisecondsSinceEpoch) }
  }

  /// Nil where Dart's casts would throw: no string `key`, a field of the wrong type.
  public init?(json j: JSONObject) {
    guard let s = try? LiveSummary(reading: j) else { return nil }
    self = s
  }

  private init(reading j: JSONObject) throws {
    var ask: LiveAsk?
    if let a = j["ask"]?.object {
      ask = try LiveAsk(reading: a)
    }
    func number(_ v: JSON?) throws -> Double? {
      switch v {
      case nil, .null?: return nil
      case let n?: guard let d = n.number else { throw LiveCastError() }; return d
      }
    }
    // `num.toInt()` truncates toward zero.
    let ctx = try number(j["ctx"]).map { d -> Int in
      if case .int(let i)? = j["ctx"] { return i }
      return Int(d.rounded(.towardZero))
    }
    self.init(
      key: try liveRequiredString(j["key"]),
      id: try liveString(j["id"]) ?? "",
      title: try liveString(j["title"]) ?? "",
      cwd: try liveString(j["cwd"]) ?? "",
      epoch: try liveString(j["epoch"]) ?? "",
      seq: try liveInt(j["seq"]) ?? 0,
      agent: Agent.parse(j["agent"]),
      profile: try liveString(j["profile"]) ?? "",
      window: try liveString(j["window"]),
      model: try liveString(j["model"]) ?? "",
      busy: j["busy"] == .bool(true),
      ask: ask,
      ctx: ctx,
      cost: try number(j["cost"]),
      preview: try liveString(j["preview"]) ?? "",
      older: j["older"] == .bool(true),
      commands: (try liveList(j["cmds"]) ?? []).compactMap { c in
        guard let l = c.array, let name = l.first?.string else { return nil }
        return LiveCommand(name: name, description: l.count > 1 ? l[1].string ?? "" : "")
      },
      queue: try (liveList(j["queue"]) ?? []).compactMap { q in
        guard let o = q.object, o["id"]?.string != nil else { return nil }
        guard let queued = LiveQueued(json: o) else { throw LiveCastError() }
        return queued
      },
      paused: j["paused"] == .bool(true),
      failed: j["failed"] == .bool(true),
      orchestrator: j["orch"] == .bool(true)
    )
    atMilliseconds = j["at"]?.int
  }

  public func toJson() -> JSONObject {
    var j: JSONObject = ["key": .string(key), "id": .string(id), "agent": .string(agent.name)]
    if !profile.isEmpty { j["profile"] = .string(profile) }
    if let window { j["window"] = .string(window) }
    j["title"] = .string(title)
    j["cwd"] = .string(cwd)
    if !model.isEmpty { j["model"] = .string(model) }
    if busy { j["busy"] = true }
    if let ask { j["ask"] = .object(ask.toJson()) }
    if let ctx { j["ctx"] = .int(ctx) }
    if let cost { j["cost"] = .double(cost) }
    if !preview.isEmpty { j["preview"] = .string(preview) }
    if let atMilliseconds { j["at"] = .int(atMilliseconds) }
    j["epoch"] = .string(epoch)
    j["seq"] = .int(seq)
    if older { j["older"] = true }
    if !commands.isEmpty {
      j["cmds"] = .array(
        commands.map { c in .strings(c.description.isEmpty ? [c.name] : [c.name, c.description]) })
    }
    if !queue.isEmpty { j["queue"] = .array(queue.map { .object($0.toJson()) }) }
    if paused { j["paused"] = true }
    if failed { j["failed"] = true }
    if orchestrator { j["orch"] = true }
    return j
  }
}

/// How a screen's lines changed: `drop` from the top, the next `keep`
/// unchanged, then `tail` new. Scrolling and a redrawn bottom cost a few
/// lines instead of the whole screen.
public struct ScreenDiff: Sendable, Hashable {
  public let drop: Int
  public let keep: Int
  public let tail: [String]

  public init(drop: Int, keep: Int, tail: [String]) {
    self.drop = drop
    self.keep = keep
    self.tail = tail
  }

  /// Nil where Dart's casts would throw (`drop`/`keep` not ints, `tail` not a list of strings).
  public init?(json j: JSONObject) {
    guard let drop = j["drop"]?.int, let keep = j["keep"]?.int, let list = j["tail"]?.array else { return nil }
    let tail = list.compactMap(\.string)
    guard tail.count == list.count else { return nil }
    self.init(drop: drop, keep: keep, tail: tail)
  }

  /// From `a` to `b`; nil when sending `b` whole is about as cheap.
  public static func between(_ a: [String], _ b: [String]) -> ScreenDiff? {
    if a.isEmpty || b.isEmpty { return nil }
    var bestDrop = 0
    var bestKeep = 0
    // Where b's first line sits in a: 0 unless lines scrolled off the top.
    var tries = 0
    var d = 0
    while d < a.count && tries < 8 {
      defer { d += 1 }
      if !liveSame(a[d], b[0]) { continue }
      tries += 1
      var k = 0
      while k < b.count && d + k < a.count && liveSame(a[d + k], b[k]) { k += 1 }
      if k > bestKeep {
        bestKeep = k
        bestDrop = d
      }
    }
    if bestKeep < b.count / 4 { return nil }
    return ScreenDiff(drop: bestDrop, keep: bestKeep, tail: Array(b[bestKeep...]))
  }

  /// `a` changed into what `between` was given; nil if `a` isn't what this
  /// diff was made from (the phone missed a version).
  public func apply(_ a: [String]) -> [String]? {
    // A negative count (only from a bad peer) is Dart's RangeError: not this base either.
    if drop < 0 || keep < 0 || drop + keep > a.count { return nil }
    return Array(a[drop..<(drop + keep)]) + tail
  }

  public func toJson() -> JSONObject { ["drop": .int(drop), "keep": .int(keep), "tail": .strings(tail)] }
}
