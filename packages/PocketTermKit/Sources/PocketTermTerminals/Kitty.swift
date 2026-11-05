#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

/// kitty's remote control on this Mac, spoken over its unix socket (one
/// connection per command; see https://sw.kovidgoyal.net/kitty/rc_protocol/).
/// kitty listens only with `allow_remote_control socket-only` and
/// `listen_on unix:/tmp/kitty` in kitty.conf (read at startup), which makes it
/// `/tmp/kitty-<pid>`; every unix socket named `kitty*` in /tmp that this
/// user owns counts, so several kittys work. Window keys:
/// `<socket name>/<window id>`; its OS window `<socket name>/os<id>` and its
/// tab `<socket name>/tab<id>`, by the ids kitty's `ls` gives them.
open class Kitty: TerminalHost, @unchecked Sendable {
  public let home: String
  public let socketDir: String

  /// Whose sockets count: the user PocketTerm runs as. /tmp is everyone's, and a
  /// socket another account put there would show its windows on the phone
  /// and get what the phone types.
  public let uid: uid_t

  /// How long one command may take, connecting included.
  public let timeout: Duration

  /// Whether `launch` gives the focus back (`keepFront`); tests turn it off.
  public let restoreFront: Bool

  public init(
    home: String? = nil, socketDir: String = "/tmp", timeout: Duration = .seconds(5), restoreFront: Bool = true,
    uid: uid_t? = nil
  ) {
    self.home = home ?? homeDir()
    self.socketDir = socketDir
    self.timeout = timeout
    self.restoreFront = restoreFront
    self.uid = uid ?? getuid()
  }

  open var id: String { "kitty" }
  open var label: String { "kitty" }
  open var appName: String? { "kitty" }
  open var bundleId: String? { "net.kovidgoyal.kitty" }
  open var caps: Set<TermCap> { allCaps }
  open var limits: String { "" }

  public static let notListening =
    "kitty isn't listening. Add `allow_remote_control socket-only` and `listen_on unix:/tmp/kitty` "
    + "to kitty.conf, then restart kitty."

  /// The lines Settings' one click appends to kitty.conf.
  public static let configLines = ["allow_remote_control socket-only", "listen_on unix:/tmp/kitty"]

  /// What acting on a window of a kitty that quit says.
  public static let quit = "kitty has quit."

  /// The most UTF-8 bytes of text one `send-text` carries: kitty ignores a
  /// message over about 128 KB, and JSON writes a control character in six.
  public static let typeBytes = 10000

  /// The protocol version we claim; kitty refuses clients newer than itself.
  private static let version: JSON = [0, 20, 0]
  private static let prefix = "\u{1b}P@kitty-cmd"
  private static let end = "\u{1b}\\"

  /// kitty.conf: `$KITTY_CONFIG_DIRECTORY`, else `$XDG_CONFIG_HOME/kitty`, else `~/.config/kitty`.
  public var configPath: String {
    let env = ProcessInfo.processInfo.environment
    let dir = env["KITTY_CONFIG_DIRECTORY"] ?? (env["XDG_CONFIG_HOME"].map { "\($0)/kitty" } ?? "\(home)/.config/kitty")
    return "\(dir)/kitty.conf"
  }

  /// Whether kitty.conf `text` already turns remote control on with a socket.
  public static func configured(_ text: String) -> Bool {
    func has(_ option: String, _ ok: (String) -> Bool) -> Bool {
      dartLines(text).map(dartTrim).filter { $0.dartStartsWith("\(option) ") }
        .contains { ok(dartTrim(($0 as NSString).substring(from: (option as NSString).length))) }
    }
    return has("allow_remote_control") { $0 == "socket-only" || $0 == "yes" || $0 == "socket" }
      && has("listen_on") { $0.dartStartsWith("unix:") }
  }

  /// Appends `configLines` to kitty.conf (made if missing), after copying
  /// it to `kitty.conf.pocketterm-backup`; kitty reads them when it next starts.
  public func configure() throws {
    let path = configPath
    let fm = FileManager.default
    let exists = fileExists(path)
    do {
      let text = exists ? try String(contentsOfFile: path, encoding: .utf8) : ""
      if Self.configured(text) { return }
      if exists {
        let backup = "\(path).pocketterm-backup"
        if fm.fileExists(atPath: backup) { try fm.removeItem(atPath: backup) }
        try fm.copyItem(atPath: path, toPath: backup)
      }
      try fm.createDirectory(atPath: Paths.dirname(path), withIntermediateDirectories: true)
      let sep = text.isEmpty || text.dartEndsWith("\n") ? "" : "\n"
      try "\(text)\(sep)\n# Added by PocketTerm: lets it reach kitty windows from your phone.\n\(Self.configLines.joined(separator: "\n"))\n"
        .write(toFile: path, atomically: false, encoding: .utf8)
    } catch let e as TerminalException {
      throw e
    } catch {
      throw TerminalException("Couldn\u{2019}t change \(path): \(error.localizedDescription)")
    }
  }

  public var installed: Bool {
    directoryExists("/Applications/kitty.app") || directoryExists("\(home)/Applications/kitty.app")
      || findExecutable("kitty") != nil
  }

  open func status(_ procs: Procs) async throws -> TermStatus {
    if !installed { return TermStatus(id, label, .missing) }
    let running = procs.running("/Applications/kitty.app/") || procs.all.contains { $0.program == "kitty" }
    if !sockets().isEmpty {
      do {
        let n = try await windows(procs).count
        return TermStatus(id, label, .ready, note: plural(n, "window"))
      } catch is TerminalException {
        // Only sockets left behind by a kitty that has quit.
      }
    }
    if let text = try? String(contentsOfFile: configPath, encoding: .utf8), Self.configured(text) {
      return TermStatus(
        id, label, running ? .setup : .idle,
        note: running ? "Restart kitty to let PocketTerm in (kitty.conf is set)." : "Not running")
    }
    return TermStatus(
      id, label, .setup, note: "kitty needs remote control on: one click adds it to kitty.conf.", fix: .kittyConfig)
  }

  /// The names of the sockets this user's kittys listen on, sorted.
  private func sockets() -> [String] {
    guard let names = listNames(socketDir) else { return [] }
    return names.filter { name in
      let path = "\(socketDir)/\(name)"
      return name.dartStartsWith("kitty") && fileKind(path) == .socket && fileOwner(path) == uid
    }.dartSorted()
  }

  private static let keyPattern = TermRegex(#"^(kitty[A-Za-z0-9_.-]*)/([0-9]+)\z"#)
  private static let osWindowPattern = TermRegex(#"^(kitty[A-Za-z0-9_.-]*)/os([0-9]+)\z"#)
  private static let colorLine = TermRegex(
    "^([A-Za-z0-9_]+)[\(jsSpaceChars)]+#([0-9a-fA-F]{6})\\z")

  open func owns(_ key: String) -> Bool { Self.keyPattern.hasMatch(key) }

  /// Runs `cmd` on the kitty behind `socket` and returns the answer's `data`
  /// (kitty sends most of it as a string, ls as JSON inside that string).
  private func rc(_ socket: String, _ cmd: String, _ payload: JSONObject? = nil) async throws -> JSON? {
    var request: JSONObject = ["cmd": .string(cmd), "version": Self.version]
    if let payload { request["payload"] = .object(payload) }
    let bytes = Array("\(Self.prefix)\(JSON.object(request).encoded())\(Self.end)".utf8)
    let path = "\(socketDir)/\(socket)"
    let timeout = timeout
    let result = await withCheckedContinuation { c in
      DispatchQueue.global().async { c.resume(returning: KittySocket.exchange(path, bytes, timeout)) }
    }
    let reply: String
    switch result {
    case .success(let data):
      reply = String(decoding: data.dropLast(2), as: UTF8.self)
    case .failure(.connect(let errno)):
      // Nobody listens on it: a socket left behind by a kitty that quit.
      if errno == 2 || errno == 61 || errno == 111 { throw TerminalException(Self.quit) }
      throw TerminalException("kitty did not answer.")
    case .failure(.noAnswer):
      throw TerminalException("kitty did not answer.")
    case .failure(.hungUp):
      throw TerminalException("kitty hung up mid-answer.")
    }
    let body = reply.dartStartsWith(Self.prefix) ? (reply as NSString).substring(from: (Self.prefix as NSString).length) : reply
    guard let decoded = JSON.tryParse(body)?.object else { throw TerminalException("kitty answered gibberish.") }
    if decoded["ok"]?.bool != true {
      let error = decoded["error"]?.string ?? "kitty refused."
      if error.dartStartsWith("No matching windows") { throw TerminalException("That window is gone.") }
      throw TerminalException(error)
    }
    return decoded["data"]
  }

  /// `<socket>/<id>` back to its parts; anything else is refused before it
  /// reaches kitty.
  private func parse(_ key: String) throws -> (socket: String, match: String) {
    guard let m = Self.keyPattern.firstMatch(key), let socket = m[1], let id = m[2], sockets().contains(socket) else {
      throw TerminalException("That window is gone.")
    }
    return (socket, "id:\(id)")
  }

  /// Every window of every listening kitty, in kitty's order.
  open func windows(_ procs: Procs) async throws -> [TermWindow] { try await listWindows(procs) }

  /// `windows` without a process snapshot: no ttys.
  public func windows() async throws -> [TermWindow] { try await listWindows(nil) }

  private func listWindows(_ procs: Procs?) async throws -> [TermWindow] {
    let sockets = sockets()
    if sockets.isEmpty { throw TerminalException(Self.notListening) }
    var out: [TermWindow] = []
    var answered = false
    for socket in sockets {
      let data: JSON?
      do {
        data = try await rc(socket, "ls")
      } catch is TerminalException {
        // A socket left behind by a kitty that has quit.
        continue
      }
      answered = true
      out += try parseKittyLs(socket, data?.string ?? "", procs)
    }
    if !answered { throw TerminalException(Self.notListening) }
    return out
  }

  open func lines(_ key: String, history: Bool) async throws -> [String] {
    let (socket, match) = try parse(key)
    let text = try await rc(
      socket, "get-text", ["match": .string(match), "extent": .string(history ? "all" : "screen"), "ansi": true])
    return screenLines(text?.string ?? "")
  }

  open func plainScreen(_ key: String) async throws -> String {
    let (socket, match) = try parse(key)
    let text = try await rc(socket, "get-text", ["match": .string(match), "extent": "screen", "ansi": false])
    return dartTrimRight(text?.string ?? "")
  }

  open func colors(_ key: String) async throws -> JSONObject? {
    let (socket, match) = try parse(key)
    let out = try await rc(socket, "get-colors", ["match": .string(match)])?.string ?? ""
    var named: [String: Int] = [:]
    for line in out.components(separatedBy: "\n") {
      if let m = Self.colorLine.firstMatch(dartTrim(line)), let name = m[1], let hex = m[2] {
        named[name] = Int(hex, radix: 16)
      }
    }
    return [
      "fg": .int(named["foreground"] ?? 0xDDDDDD),
      "bg": .int(named["background"] ?? 0x000000),
      "palette": .array((0..<256).map { .int(named["color\($0)"] ?? 0) }),
    ]
  }

  /// Not as a paste: omp answers a paste by also attaching whatever image is
  /// on the Mac's clipboard. In pieces of `typeBytes`, a command each.
  open func type(_ key: String, _ text: String) async throws {
    let (socket, match) = try parse(key)
    for chunk in textChunks(text, Self.typeBytes) {
      _ = try await rc(
        socket, "send-text",
        ["match": .string(match), "data": .string("text:\(chunk)"), "bracketed_paste": "disable"])
    }
  }

  /// In one command, as kitty names them (`shift+tab`, `a`).
  open func pressKeys(_ key: String, _ names: [String]) async throws {
    let (socket, match) = try parse(key)
    if names.isEmpty { return }
    _ = try await rc(socket, "send-key", ["match": .string(match), "keys": .strings(names)])
  }

  /// kitty doesn't ask; the phone does, before it sends this. A kitty in
  /// the background comes to the front when one of its OS windows closes
  /// (not when a tab does): the app that was in front gets it back.
  open func close(_ key: String) async throws {
    let (socket, match) = try parse(key)
    let close = { _ = try await self.rc(socket, "close-window", ["match": .string(match)]) }
    if !restoreFront {
      return try await close()
    }
    let ls = try await rc(socket, "ls")?.string ?? "[]"
    if !lastInOsWindow(ls, Int((match as NSString).substring(from: 3)) ?? -1) { return try await close() }
    try await keepFront(app: bundleId, close)
  }

  /// With `into` (`<socket>/os<id>`), a new tab in that OS window, taking no
  /// focus from a window being typed in there; otherwise, or if that OS
  /// window is gone, a new OS window. A kitty in the background comes to the
  /// front for a new OS window (the app that was in front gets it back), not
  /// for a tab.
  open func launch(_ cwd: String, command: [String]?, into: String?) async throws -> String {
    if !directoryExists(cwd) { throw TerminalException("No such folder: \(cwd)") }
    let sockets = sockets()
    if sockets.isEmpty { throw TerminalException(Self.notListening) }
    func open(_ socket: String, _ spot: (window: Int, focused: Bool)?) async throws -> String {
      var payload: JSONObject = [
        "args": .strings(command ?? []),
        "cwd": .string(cwd),
        "type": .string(spot == nil ? "os-window" : "tab"),
        // In the OS window being typed in, the tab opens behind the one in
        // use; in one in the background it becomes that window's active tab.
        "keep_focus": .bool(spot?.focused ?? true),
      ]
      if let spot { payload["match"] = .string("window_id:\(spot.window)") }
      let data = try await rc(socket, "launch", payload)
      return "\(socket)/\(dartTrim(jsonText(data)))"
    }

    var last: TerminalException?
    if let m = Self.osWindowPattern.firstMatch(into ?? ""), let socket = m[1], let os = m[2].flatMap({ Int($0) }),
      sockets.contains(socket)
    {
      do {
        if let spot = kittyTabSpot(try await rc(socket, "ls")?.string ?? "[]", os) { return try await open(socket, spot) }
      } catch let e as TerminalException {
        last = e
      }
    }
    let window = { () async throws -> String in
      for socket in sockets {
        do {
          return try await open(socket, nil)
        } catch let e as TerminalException {
          last = e
        }
      }
      throw last ?? TerminalException(Self.notListening)
    }
    return restoreFront ? try await keepFront(app: bundleId, window) : try await window()
  }
}

/// Where in kitty's `ls` `json` a new tab in OS window `osWindow` goes: next
/// to one of its windows (kitty's `launch` matches a window, not an OS
/// window), with whether that OS window has the focus; nil if it's gone.
public func kittyTabSpot(_ json: String, _ osWindow: Int) -> (window: Int, focused: Bool)? {
  for os in JSON.tryParse(json)?.array ?? [] where os["id"]?.int == osWindow {
    for tab in os["tabs"]?.array ?? [] {
      for w in tab["windows"]?.array ?? [] {
        return (w["id"]?.int ?? 0, os["is_focused"]?.bool == true)
      }
    }
  }
  return nil
}

/// Whether window `id` is the last one of its OS window in kitty's `ls`
/// `json`: closing it closes the OS window.
public func lastInOsWindow(_ json: String, _ id: Int) -> Bool {
  for os in JSON.tryParse(json)?.array ?? [] {
    let ids = (os["tabs"]?.array ?? []).flatMap { ($0["windows"]?.array ?? []).map { $0["id"] } }
    if ids.contains(.int(id)) { return ids.count == 1 }
  }
  return true
}

private let leadingDash = TermRegex("^-")

/// kitty's `ls` JSON (from the kitty behind `socket`) as windows; `procs`
/// gives each its tty.
public func parseKittyLs(_ socket: String, _ json: String, _ procs: Procs? = nil) throws -> [TermWindow] {
  guard let all = JSON.tryParse(json)?.array else { throw TerminalException("kitty answered gibberish.") }
  var out: [TermWindow] = []
  for os in all {
    for tab in os["tabs"]?.array ?? [] {
      for win in tab["windows"]?.array ?? [] {
        let proc = win["foreground_processes"]?.array?.first
        let cmd = proc?["cmdline"]?.strings ?? win["cmdline"]?.strings ?? []
        out.append(
          TermWindow(
            key: "\(socket)/\(jsonText(win["id"]))",
            title: cleanTitle(win["title"]?.string ?? ""),
            tab: cleanTitle(tab["title"]?.string ?? ""),
            cwd: proc?["cwd"]?.string ?? win["cwd"]?.string ?? "",
            program: cmd.first.map { leadingDash.replaceFirst($0.components(separatedBy: "/").last!, "") } ?? "",
            focused: win["is_focused"]?.bool == true,
            tty: win["pid"]?.int.flatMap { procs?.byPid($0)?.tty } ?? "",
            osWindow: "\(socket)/os\(jsonText(os["id"]))",
            tabId: "\(socket)/tab\(jsonText(tab["id"]))"
          ))
      }
    }
  }
  return out
}

/// A JSON value as Dart's string interpolation writes it: a string as itself, anything else as JSON.
func jsonText(_ j: JSON?) -> String { j?.string ?? (j ?? .null).encoded() }

/// Dart's `trimRight()`.
func dartTrimRight(_ s: String) -> String {
  var units = Array(s.utf16)
  while let last = units.last, isDartSpace(last) { units.removeLast() }
  return String(decoding: units, as: UTF16.self)
}

private func isDartSpace(_ u: UInt16) -> Bool {
  switch u {
  case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
  default: false
  }
}

/// One kitty command over its unix socket, done with blocking calls (on a
/// thread of its own): connect, write, read up to the terminator.
enum KittySocket {
  enum Failure: Error { case connect(Int32), noAnswer, hungUp }

  static func exchange(_ path: String, _ request: [UInt8], _ timeout: Duration) -> Result<[UInt8], Failure> {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failure(.connect(errno)) }
    defer { Darwin.close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let name = Array(path.utf8)
    guard name.count < MemoryLayout.size(ofValue: addr.sun_path) else { return .failure(.connect(ENAMETOOLONG)) }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      for (i, b) in name.enumerated() { buf[i] = b }
      buf[name.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    var deadline = ContinuousClock.now + timeout
    let r = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if r != 0 {
      let e = errno
      guard e == EINPROGRESS || e == EAGAIN else { return .failure(.connect(e)) }
      guard wait(fd, Int16(POLLOUT), deadline) else { return .failure(.connect(ETIMEDOUT)) }
      var err: Int32 = 0
      var len = socklen_t(MemoryLayout<Int32>.size)
      getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
      if err != 0 { return .failure(.connect(err)) }
    }

    // The command's time starts once connected.
    deadline = ContinuousClock.now + timeout
    var sent = 0
    while sent < request.count {
      let n = request[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
      if n > 0 {
        sent += n
      } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
        guard wait(fd, Int16(POLLOUT), deadline) else { return .failure(.noAnswer) }
      } else {
        return .failure(.noAnswer)
      }
    }
    var reply: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
      if n > 0 {
        reply += buf[..<n]
        // JSON escapes ESC, so the terminator can't occur inside the answer.
        if reply.count >= 2 && reply[reply.count - 2] == 0x1b && reply[reply.count - 1] == 0x5c {
          return .success(reply)
        }
      } else if n == 0 {
        return .failure(.hungUp)
      } else if errno == EAGAIN || errno == EINTR {
        guard wait(fd, Int16(POLLIN), deadline) else { return .failure(.noAnswer) }
      } else {
        return .failure(.noAnswer)
      }
    }
  }

  /// Whether `fd` is ready for `events` before `deadline`.
  private static func wait(_ fd: Int32, _ events: Int16, _ deadline: ContinuousClock.Instant) -> Bool {
    while true {
      let left = deadline - ContinuousClock.now
      if left <= .zero { return false }
      let ms = Int32(min(left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000, 60000))
      var p = pollfd(fd: fd, events: events, revents: 0)
      let r = poll(&p, 1, max(ms, 1))
      if r > 0 { return true }
      if r < 0 && errno != EINTR { return false }
    }
  }
}
#endif
