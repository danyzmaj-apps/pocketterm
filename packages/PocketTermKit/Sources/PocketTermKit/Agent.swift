import Foundation

/// The coding agents whose sessions PocketTerm brings to the phone (Live.swift):
/// what a new session from the phone starts, how notifications and the phone
/// name a session, and how its dialogs are answered.
public enum Agent: String, CaseIterable, Sendable, Codable {
  case omp
  case claude

  /// Its name as it travels (`omp`, `claude`).
  public var name: String { rawValue }

  /// How the phone and notifications name it: "Claude finished".
  public var label: String {
    switch self {
    case .omp: "omp"
    case .claude: "Claude"
    }
  }

  /// What a shell starts it with, which is also the program the terminal reports.
  public var command: String { name }

  /// `command` in an omp `profile` (`omp --profile=personal`), as typed; "" is the default profile,
  /// and Claude Code has none.
  public func commandIn(_ profile: String) -> String {
    self == .omp && !profile.isEmpty ? "\(command) --profile=\(profile)" : command
  }

  /// `label` with an omp `profile` that isn't the default: "omp · personal".
  public func labelIn(_ profile: String) -> String {
    self == .omp && !profile.isEmpty ? "\(label) · \(profile)" : label
  }

  /// The command that restarts it on the conversation it had (`omp -c`), for text: it never
  /// breaks across lines (a no-break space, and a word joiner after the hyphen) yet copies as typed.
  public var resume: String { resumeIn("") }

  /// `resume` in an omp `profile` (`omp --profile=personal -c`), with the same no-break characters.
  public func resumeIn(_ profile: String) -> String {
    self == .omp && !profile.isEmpty
      ? "\(command)\u{00A0}-\u{2060}-\u{2060}profile=\(profile)\u{00A0}-\u{2060}c"
      : "\(command)\u{00A0}-\u{2060}c"
  }

  /// What a session opened before PocketTerm was installed needs to load it, for text:
  /// Claude Code reloads its plugins in place, omp restarts on the same conversation (`resume`).
  public var pickUp: String { pickUpIn("") }

  /// `pickUp` for a session in an omp `profile`.
  public func pickUpIn(_ profile: String) -> String {
    switch self {
    case .omp: resumeIn(profile)
    case .claude: "/reload-plugins"
    }
  }

  /// A prompt sent while it works steers the run (omp); Claude Code queues it
  /// until the run ends.
  public var steers: Bool { self == .omp }

  /// `name` as it travels; omp for anything else (an older peer sends none).
  public static func parse(_ name: JSON?) -> Agent {
    name?.string.flatMap(Agent.init(rawValue:)) ?? .omp
  }

  /// The agent a terminal window's foreground `program` is, if it is one.
  public static func ofProgram(_ program: String) -> Agent? { Agent(rawValue: program) }

  private static let ompTitle = TermRegex("^π(?:: | [^\(jsSpaceChars)] )(.+)\\z")

  /// The session a terminal `title` this agent set names: omp sets
  /// `π > <session name>` (`>` idle; `:` or a spinner frame working, `!`
  /// asking; `π: ` with its title spinner off), the name being its folder's
  /// until the session has one. Nil for a title it didn't set, and for
  /// Claude Code, whose title names nothing its sessions report.
  public func sessionOfTitle(_ title: String) -> String? {
    switch self {
    case .omp: Agent.ompTitle.firstMatch(title)?[1].map(dartTrim)
    case .claude: nil
    }
  }
}

private let ompProfileName = TermRegex(#"^[a-z0-9][a-z0-9._-]{0,63}\z"#)

/// Whether `name` is a name omp takes for a profile (`omp --profile <name>`).
public func isOmpProfile(_ name: String) -> Bool {
  ompProfileName.hasMatch(name) && !name.hasSuffix(".")
}

/// The omp profile a command line `args` runs in, from its `--profile=<name>` or `--profile <name>` as omp reads
/// them: the last one before `--`, `default` being none; "" for none, and for a name omp wouldn't take.
public func ompProfileOfArgs(_ args: String) -> String {
  let words = TermRegex.whitespace.split(args)
  var found: String?
  var i = 0
  while i < words.count {
    let w = words[i]
    if w == "--" { break }
    if w.hasPrefix("--profile=") {
      found = String(w.dropFirst("--profile=".count))
    } else if w == "--profile" && i + 1 < words.count {
      i += 1
      found = words[i]
    }
    i += 1
  }
  if let found, found != "default", isOmpProfile(found) { return found }
  return ""
}

/// Where PocketTerm stands in a coding agent found on a computer, as the
/// computer tells the phone (the state's `agents`, Live.swift): its
/// sessions report to PocketTerm only once it's `installed` and they
/// started after that.
public enum AgentIntegration: String, CaseIterable, Sendable, Codable {
  /// Installed and the same as the app's copy.
  case installed
  /// Installed, older than the app's copy.
  case outdated
  /// Not installed, or the agent can't take it (Claude Code too old).
  case missing
  /// Installed in Claude Code, which has mods (its plugins' runtime) turned off.
  case off

  public var name: String { rawValue }

  /// The state's `agents`: agent name to value; agents or values this side
  /// doesn't know are left out, and an older computer sends none (empty).
  public static func parseAll(_ json: JSON?) -> [Agent: AgentIntegration] {
    guard let map = json?.object else { return [:] }
    var out: [Agent: AgentIntegration] = [:]
    for (key, value) in map {
      if let a = Agent(rawValue: key), let i = value.string.flatMap(AgentIntegration.init(rawValue:)) {
        out[a] = i
      }
    }
    return out
  }

  public static func toJsonAll(_ agents: [Agent: AgentIntegration]) -> JSONObject {
    var out: JSONObject = [:]
    for (key, value) in agents { out[key.name] = .string(value.name) }
    return out
  }
}
