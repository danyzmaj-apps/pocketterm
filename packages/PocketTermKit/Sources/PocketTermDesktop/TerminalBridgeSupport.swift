#if os(macOS)
import Foundation
import PocketTermKit
import PocketTermTerminals

/// The terminals the phone hears about: the installed ones, and tmux either way (its note says how to get it).
public func phoneTerminals(_ statuses: [TermStatus]) -> [TermStatus] {
  statuses.filter { $0.state != .missing || $0.id == "tmux" }
}

/// The phone's error line: only when `nothingShown` (no window, no session) and no terminal is usable, what the
/// first one needing setup says.
public func terminalsError(_ statuses: [TermStatus], nothingShown: Bool) -> String? {
  nothingShown && !statuses.contains(where: \.usable) ? statuses.first { $0.state == .setup }?.note : nil
}

/// Why an agent's ask in `window` can't be answered from the phone (nil: it can): answering reads the screen and
/// presses keys.
public func cantAnswer(_ terms: Terminals, _ window: String) -> String? {
  let read = terms.can(window, .read)
  if read && terms.can(window, .keys) { return nil }
  let label = terms.hostOf(window)?.label ?? "This terminal"
  return "\(label) can't \(read ? "press keys" : "show its screen"), so answer this on the computer. "
    + ((terms.tmux?.installed ?? false)
      ? "Sessions you start from the phone run in tmux there, which can."
      : "With tmux installed (Homebrew: brew install tmux, or MacPorts: sudo port install tmux), sessions you start "
        + "from the phone can.")
}

/// Why a slash command for the session in `window` can't be run from the phone (nil: it can): the agent's editor
/// reads commands, so they're typed into its terminal window.
public func cantCommand(_ terms: Terminals, _ window: String?) -> String? {
  guard let window else {
    return "Slash commands are typed into the agent's terminal window, and PocketTerm can't reach this one: it isn't in "
      + "kitty, tmux, WezTerm, iTerm2 or Ghostty. Run it on the computer."
  }
  if terms.can(window, .line) { return nil }
  return "\(terms.hostOf(window)?.label ?? "This terminal") can't take a typed line, so run the command on the computer."
}

/// Waits `seconds` (Dart's `Future.delayed`).
func pause(_ seconds: TimeInterval) async {
  try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

/// Whether `window`'s screen changes over `gap`: the agent in it is at work (a spinner, a clock, output). Where the
/// terminal can't show its screen (Ghostty), its title, read a few times over `gap`: an agent at work spins there
/// too.
public func screenChanges(_ terms: Terminals, _ window: String, gap: TimeInterval = 2) async throws -> Bool {
  if !terms.can(window, .read) {
    func title() async -> String? { await terms.windows().first { $0.key == window }?.title }
    guard let first = await title() else { throw TerminalException("That window has closed.") }
    for _ in 0..<4 {
      await pause(gap / 4)
      if let t = await title(), !sameText(t, first) { return true }
    }
    return false
  }
  let before = try await terms.plainScreen(window)
  await pause(gap)
  return !sameText(try await terms.plainScreen(window), before)
}

/// The omp profile a phone's `launch`/`create` asks for: "" for none asked or another agent; one this computer
/// doesn't have is refused (it's typed into a shell, so only a listed name goes).
public func launchProfile(_ requested: JSON?, _ agent: Agent, _ profiles: [String]) throws -> String {
  guard let requested = requested?.string, !requested.isEmpty, agent == .omp else { return "" }
  if !profiles.contains(requested) { throw TerminalException("omp has no profile \(requested) on this computer.") }
  return requested
}

/// Switches `agent` in `window` (an agent window no live session claims) to reporting its session to PocketTerm.
/// omp quits and starts again on the same conversation: Esc stops a run, Ctrl+C empties its editor (Ctrl+U clears
/// one line only), Ctrl+D on an empty editor quits; once the foreground program on `tty` isn't omp anymore (or
/// after `noTty`, where the terminal tells no tty) the shell gets `omp -c`, in the omp `profile` it ran in.
/// Claude Code reloads its plugins in place.
/// Where `tty` tells, nothing is pressed unless `agent` still runs there: the agent may have quit since the phone
/// last looked, and Ctrl+D would end the shell (and close the window) instead.
public func switchToConversation(
  _ terms: Terminals, _ window: String, _ agent: Agent, tty: String = "", profile: String = "",
  settle: TimeInterval = 0.4, quitFor: TimeInterval = 8, noTty: TimeInterval = 2, pollEvery: TimeInterval = 0.25
) async throws {
  if !terms.can(window, .keys) || !terms.can(window, .type) {
    throw TerminalException(
      "\(terms.hostOf(window)?.label ?? "This terminal") can't press keys and type here, so switch it on the computer.")
  }
  func runs() async -> Bool { Agent.ofProgram(await terms.snapshot().foreground(tty)?.program ?? "") == agent }
  if !tty.isEmpty, !(await runs()) {
    throw TerminalException("\(agent.label) isn't running in that window anymore.")
  }
  switch agent {
  case .claude:
    try await terms.send(window, "/reload-plugins", enter: true)
  case .omp:
    try await terms.pressKeys(window, ["esc"])
    await pause(settle)
    try await terms.pressKeys(window, ["ctrl+c"])
    await pause(settle)
    try await terms.pressKeys(window, ["ctrl+d"])
    if tty.isEmpty {
      await pause(noTty)
    } else {
      let until = Date().addingTimeInterval(quitFor)
      while await runs() {
        if Date() > until {
          throw TerminalException(
            "omp didn't quit. Quit it on the computer, then run \(agent.commandIn(profile)) -c there.")
        }
        await pause(pollEvery)
      }
    }
    try await terms.send(window, "\(agent.commandIn(profile)) -c", enter: true)
  }
}

/// One session's screen followed for pickers: when it was last told to look soon (a command, an answer, a key) and
/// last saw a change, and what the phone typed into the current picker's search.
@MainActor
final class MenuWatch {
  var armed = Date()
  var changed = Date()
  var query = ""
  private var waiter: CheckedContinuation<Void, Never>?
  private var timer: MainTimer?

  /// Reads soon again, for a while.
  func arm() {
    armed = Date()
    changed = armed
    wake()
  }

  func wake() {
    timer?.cancel()
    timer = nil
    if let w = waiter {
      waiter = nil
      w.resume()
    }
  }

  /// Waits `seconds`, or less if woken.
  func sleep(_ seconds: TimeInterval) async {
    await withCheckedContinuation { c in
      waiter = c
      timer = MainTimer(seconds) { [weak self] in self?.wake() }
    }
  }
}

/// The requests phones sent lately, by id, and their answers. A phone that heard no answer (its app went to the
/// background, the network dropped) sends the same request again under the same id: it gets the answer it missed
/// (marked `repeat`) instead of the request running twice; one still running is answered once it ends.
@MainActor
public final class RunLog {
  public init(keep: TimeInterval = 2 * 60, clock: (() -> Date)? = nil) {
    self.keep = keep
    self.clock = clock ?? { Date() }
  }

  /// How long a request's answer is kept for a repeat.
  public let keep: TimeInterval
  private let clock: () -> Date
  private var runs: [String: (at: Date, ran: JSONObject?)] = [:]

  /// Whether request `id` is new, and then taken as running; for one that already ran, its answer goes to `again`.
  public func start(_ id: String, _ again: (JSONObject) -> Void) -> Bool {
    let now = clock()
    runs = runs.filter { now.timeIntervalSince($0.value.at) <= keep }
    if let r = runs[id] {
      if var ran = r.ran {
        ran["repeat"] = true
        again(ran)
      }
      return false
    }
    runs[id] = (now, nil)
    return true
  }

  /// Request `id` ended with `ran`.
  public func done(_ id: String, _ ran: JSONObject) { runs[id] = (clock(), ran) }
}
#endif
