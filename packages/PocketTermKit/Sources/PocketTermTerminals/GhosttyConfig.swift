#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// Who sets the command Ghostty's new windows run.
public enum GhosttyCommandState: String, Sendable {
  /// Nobody: they run the login shell.
  case none
  /// PocketTerm's lines (`GhosttyConfig.add`): a tmux session each.
  case ours
  /// A `command =` line of the person's own, which PocketTerm leaves alone.
  case theirs
}

/// What the config files say about Ghostty's command.
public struct GhosttyCommand: Sendable, Hashable {
  public var state: GhosttyCommandState
  public var command: String
  public init(state: GhosttyCommandState, command: String) {
    self.state = state
    self.command = command
  }
}

/// Ghostty's config files, for the one setting PocketTerm offers there: new
/// windows (and tabs) opening in tmux, each in a session of its own that
/// ends with its window. Ghostty loads every file of `files` that exists, in
/// that order; PocketTerm writes to the first that exists (else the first),
/// two marked lines and nothing else, and `remove` takes exactly those out.
public struct GhosttyConfig: Sendable {
  public let files: [String]

  public init(_ files: [String]) { self.files = files }

  /// The files Ghostty 1.3 reads on a Mac, in its order: `~/.config`'s,
  /// then Application Support's. (`XDG_CONFIG_HOME` is left out: apps
  /// started from the Dock don't get it.)
  public static func standard(home: String) -> GhosttyConfig {
    let base = Paths.join(home, ".config/ghostty")
    let support = Paths.join(home, "Library/Application Support/com.mitchellh.ghostty")
    return GhosttyConfig([
      Paths.join(base, "config.ghostty"),
      Paths.join(base, "config"),
      Paths.join(support, "config.ghostty"),
      Paths.join(support, "config"),
    ])
  }

  public static let marker =
    "# Added by PocketTerm: new windows open in tmux. Remove with Settings \u{2192} Terminals \u{2192} Remove."

  /// The line for `tmux` (an absolute path: Ghostty may not have Homebrew on
  /// its PATH). Ghostty runs it through `/bin/sh -c`; every window gets a new
  /// session (none shared, so windows don't mirror each other), which ends
  /// when its window closes rather than pile up detached, and titles its
  /// window with its pane's title and its own name (`~ (tmux 3)`), which
  /// ties the window to its session (Terminals.tieGhostty).
  public static func line(_ tmux: String) -> String {
    "command = \(word(tmux)) new-session \\; set-option destroy-unattached on"
      + #" \; set-option set-titles on \; set-option set-titles-string '#T (tmux #S)'"#
  }

  private static let plainWord = TermRegex(#"^[A-Za-z0-9_./+-]+\z"#)
  private static func word(_ s: String) -> String { plainWord.hasMatch(s) ? s : shellQuote(s) }

  private static let commandLine = TermRegex(
    "^[\(jsSpaceChars)]*command[\(jsSpaceChars)]*=(.*)\\z")

  /// A `command =` line's value (quotes off), or nil for any other line
  /// and for an empty one (which puts the default back).
  private static func command(_ line: String) -> String? {
    guard let m = commandLine.firstMatch(line) else { return nil }
    var v = dartTrim(m[1] ?? "")
    if (v as NSString).length >= 2 && v.dartStartsWith("\"") && v.dartEndsWith("\"") {
      v = (v as NSString).substring(with: NSRange(location: 1, length: (v as NSString).length - 2))
    }
    return v.isEmpty ? nil : v
  }

  private static func isMarker(_ line: String) -> Bool { dartTrimRight(line) == marker }

  private func text(_ path: String) -> String? {
    FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
  }

  /// What the files say now (read each time: edits by hand count). Ours
  /// when PocketTerm's lines are anywhere; else the person's own command,
  /// the last one Ghostty would read.
  public func read() -> GhosttyCommand {
    var ours: String?
    var theirs: String?
    for path in files {
      guard let lines = text(path)?.components(separatedBy: "\n") else { continue }
      for (i, l) in lines.enumerated() {
        guard let v = Self.command(l) else { continue }
        if i > 0 && Self.isMarker(lines[i - 1]) {
          ours = ours ?? v
        } else {
          theirs = v
        }
      }
    }
    if let ours { return GhosttyCommand(state: .ours, command: ours) }
    if let theirs { return GhosttyCommand(state: .theirs, command: theirs) }
    return GhosttyCommand(state: .none, command: "")
  }

  /// PocketTerm's lines for `tmux`, at the end of the first file that exists
  /// (made, with its folders, when none does); nothing when a command is
  /// already set. The file written.
  @discardableResult
  public func add(_ tmux: String) throws -> String? {
    if read().state != .none { return nil }
    let path = files.first(where: fileExists) ?? files[0]
    let target = fileExists(path) ? realPath(path) ?? path : path
    let text = text(target) ?? ""
    let block = "\(Self.marker)\n\(Self.line(tmux))"
    try Self.write(target, text.isEmpty || text.dartEndsWith("\n") ? "\(text)\(block)\n" : "\(text)\n\(block)")
    return target
  }

  /// PocketTerm's lines out of every file they're in; every other byte stays.
  public func remove() throws {
    for path in files where fileExists(path) {
      let target = realPath(path) ?? path
      guard let text = text(target) else { continue }
      let out = Self.without(text)
      if out != text { try Self.write(target, out) }
    }
  }

  /// PocketTerm's `command =` line made `line` for `tmux` wherever it's
  /// another (an earlier PocketTerm's, which gave windows no title to match
  /// them by); every other byte stays, the file's permissions too. Whether
  /// a file changed.
  @discardableResult
  public func upgrade(_ tmux: String) throws -> Bool {
    var changed = false
    for path in files where fileExists(path) {
      let target = realPath(path) ?? path
      guard var lines = text(target)?.components(separatedBy: "\n") else { continue }
      var here = false
      for i in lines.indices.dropFirst() {
        if !Self.isMarker(lines[i - 1]) || Self.command(lines[i]) == nil { continue }
        let want = Self.line(tmux) + (lines[i].dartEndsWith("\r") ? "\r" : "")
        if lines[i] == want { continue }
        lines[i] = want
        here = true
      }
      if !here { continue }
      try Self.write(target, lines.joined(separator: "\n"))
      changed = true
    }
    return changed
  }

  /// `text` without each marker line and the `command =` line under it. As
  /// `add` puts them in: at the end of a file not ending in a newline, the
  /// newline before them is theirs too.
  static func without(_ text: String) -> String {
    let ns = text as NSString
    let length = ns.length
    func indexOfNewline(_ from: Int) -> Int {
      guard from < length else { return -1 }
      let r = ns.range(of: "\n", options: .literal, range: NSRange(location: from, length: length - from))
      return r.location == NSNotFound ? -1 : r.location
    }
    func sub(_ a: Int, _ b: Int) -> String { ns.substring(with: NSRange(location: a, length: b - a)) }
    var out = ""
    var at = 0
    while at < length {
      let nl = indexOfNewline(at)
      let lineEnd = nl < 0 ? length : nl
      if isMarker(sub(at, lineEnd)) && nl >= 0 {
        let next = indexOfNewline(nl + 1)
        let cmdEnd = next < 0 ? length : next
        if command(sub(nl + 1, cmdEnd)) != nil {
          if next < 0 {
            // The block ends the file without a newline: the one before it goes.
            if out.dartEndsWith("\n") { out = String(out.utf16.dropLast())! }
            at = length
          } else {
            at = next + 1
          }
          continue
        }
      }
      out += sub(at, nl < 0 ? length : nl + 1)
      at = nl < 0 ? length : nl + 1
    }
    return out
  }

  /// `text` in place of `path`'s content all at once (a file beside it, then
  /// renamed over it), keeping its permissions.
  private static func write(_ path: String, _ text: String) throws {
    let fm = FileManager.default
    do {
      let mode = fileExists(path) ? (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber) : nil
      try fm.createDirectory(atPath: Paths.dirname(path), withIntermediateDirectories: true)
      let tmp = "\(path).pocketterm-tmp"
      guard fm.createFile(atPath: tmp, contents: Data(text.utf8)) else {
        throw TerminalException("Couldn\u{2019}t change \(path): \(String(cString: strerror(errno)))")
      }
      if let mode { try fm.setAttributes([.posixPermissions: mode.intValue & 0o777], ofItemAtPath: tmp) }
      guard rename(tmp, path) == 0 else {
        throw TerminalException("Couldn\u{2019}t change \(path): \(String(cString: strerror(errno)))")
      }
    } catch let e as TerminalException {
      throw e
    } catch {
      throw TerminalException("Couldn\u{2019}t change \(path): \(error.localizedDescription)")
    }
  }
}
#endif
