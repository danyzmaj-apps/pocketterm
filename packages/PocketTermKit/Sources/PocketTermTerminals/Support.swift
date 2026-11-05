#if os(macOS)
import Darwin
import Foundation
import PocketTermKit

// What dart:io and package:path gave the Dart terminals, for the Swift ones:
// programs started with a time limit, file kinds, and POSIX path rules.

/// A value behind a lock, for a host's state that several tasks touch.
package final class Guarded<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  package init(_ value: Value) { self.value = value }

  package func with<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }

  package var get: Value { with { $0 } }
}

/// A value that arrives once, which any number of tasks may wait for, each
/// for as long as it likes.
final class OneShot<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T?
  private var waiters: [UUID: CheckedContinuation<T?, Never>] = [:]
  private var expired: Set<UUID> = []

  func set(_ v: T) {
    lock.lock()
    guard value == nil else {
      lock.unlock()
      return
    }
    value = v
    let all = waiters
    waiters = [:]
    lock.unlock()
    for c in all.values { c.resume(returning: v) }
  }

  var current: T? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  /// The value; nil when it hasn't come within [limit] (nil: no limit).
  func wait(_ limit: Duration? = nil) async -> T? {
    let id = UUID()
    let timer = limit.map { limit in
      Task {
        try? await Task.sleep(for: limit)
        self.expire(id)
      }
    }
    let v: T? = await withCheckedContinuation { c in
      lock.lock()
      if let value {
        lock.unlock()
        c.resume(returning: value)
      } else if expired.remove(id) != nil {
        lock.unlock()
        c.resume(returning: nil)
      } else {
        waiters[id] = c
        lock.unlock()
      }
    }
    timer?.cancel()
    return v
  }

  private func expire(_ id: UUID) {
    lock.lock()
    if let c = waiters.removeValue(forKey: id) {
      lock.unlock()
      c.resume(returning: nil)
    } else {
      if value == nil { expired.insert(id) }
      lock.unlock()
    }
  }
}

/// A program that couldn't be started (dart:io's ProcessException).
package struct ProcessLaunchError: Error, Sendable, CustomStringConvertible {
  package let message: String
  package init(message: String) { self.message = message }
  package var description: String { message }
}

/// A started program, as dart:io's `Process`: its stdin closed, its output
/// gathered, its exit awaited with or without a time limit. Spawned with
/// posix_spawn, not Foundation's `Process`, which passes arguments through
/// `fileSystemRepresentation` and so decomposes them (é as e + U+0301): text
/// typed into a terminal must arrive as it was written.
package final class Subprocess: Sendable {
  package let pid: pid_t
  private let exit = OneShot<Int32>()
  private let out = OneShot<Data>()
  private let err = OneShot<Data>()
  /// The write end of its stdin while kept open (`keepStdin`); -1 once closed.
  private let input: Guarded<Int32>

  /// Which of its streams a chunk of output came from.
  package enum Stream: Sendable { case out, err }

  /// Starts `executable` with `arguments`; `environment` adds to (or
  /// overrides) this process's, as dart:io does. `keepStdin`: its stdin is a
  /// pipe this side holds open until `closeStdin` (or this object goes), so a
  /// child that watches stdin ends with its parent. `onOutput` hears each
  /// chunk of stdout and stderr as it comes, then an empty one when that
  /// stream ends; `stdout()`/`stderr()` still gather it all.
  package static func start(
    _ executable: String, _ arguments: [String], environment: [String: String]? = nil, workingDirectory: String? = nil,
    keepStdin: Bool = false, onOutput: (@Sendable (Stream, Data) -> Void)? = nil
  ) throws(ProcessLaunchError) -> Subprocess {
    try Subprocess(executable, arguments, environment, workingDirectory, keepStdin, onOutput)
  }

  private init(
    _ executable: String, _ arguments: [String], _ environment: [String: String]?, _ cwd: String?, _ keepStdin: Bool,
    _ onOutput: (@Sendable (Stream, Data) -> Void)?
  ) throws(ProcessLaunchError) {
    var outPipe: [Int32] = [-1, -1]
    var errPipe: [Int32] = [-1, -1]
    var inPipe: [Int32] = [-1, -1]
    guard pipe(&outPipe) == 0 else { throw ProcessLaunchError(message: String(cString: strerror(errno))) }
    guard pipe(&errPipe) == 0 else {
      close(outPipe[0])
      close(outPipe[1])
      throw ProcessLaunchError(message: String(cString: strerror(errno)))
    }
    if keepStdin {
      guard pipe(&inPipe) == 0 else {
        for fd in outPipe + errPipe { close(fd) }
        throw ProcessLaunchError(message: String(cString: strerror(errno)))
      }
    }
    // Not into programs this process starts some other way meanwhile.
    for fd in outPipe + errPipe + inPipe where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    if keepStdin {
      posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
    } else {
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    }
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
    if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

    var attrs: posix_spawnattr_t?
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }
    // Nothing else of this process leaks into it, and signals this process
    // ignores (SIGPIPE) are the defaults again there.
    var all = sigset_t()
    sigfillset(&all)
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attrs, &all)
    posix_spawnattr_setsigmask(&attrs, &none)
    posix_spawnattr_setflags(
      &attrs, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    var env = ProcessInfo.processInfo.environment
    if let environment { env.merge(environment) { _, new in new } }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for p in argv { free(p) }
      for p in envp { free(p) }
    }
    var pid: pid_t = 0
    let r = posix_spawn(&pid, executable, &actions, &attrs, argv, envp)
    close(outPipe[1])
    close(errPipe[1])
    if keepStdin { close(inPipe[0]) }
    guard r == 0 else {
      close(outPipe[0])
      close(errPipe[0])
      if keepStdin { close(inPipe[1]) }
      throw ProcessLaunchError(message: String(cString: strerror(r)))
    }
    self.pid = pid
    input = Guarded(keepStdin ? inPipe[1] : -1)
    for (fd, shot, stream) in [(outPipe[0], out, Stream.out), (errPipe[0], err, Stream.err)] {
      guard let onOutput else {
        Thread.detachNewThread { shot.set(FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()) }
        continue
      }
      Thread.detachNewThread {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var all = Data()
        while true {
          let chunk = handle.availableData
          onOutput(stream, chunk)
          if chunk.isEmpty { break }
          all.append(chunk)
        }
        shot.set(all)
      }
    }
    let exit = exit
    let child = pid
    Thread.detachNewThread {
      var status: Int32 = 0
      while waitpid(child, &status, 0) < 0 && errno == EINTR {}
      // Killed by a signal: its number negated, as dart:io tells it.
      let signal = status & 0x7f
      exit.set(signal == 0 ? (status >> 8) & 0xff : -signal)
    }
  }

  /// Its exit code once it ends.
  package func exitCode() async -> Int32 { await exit.wait()! }

  /// Its exit code, or nil when it's still running after `limit`.
  package func exitCode(within limit: Duration) async -> Int32? {
    limit <= .zero ? exit.current : await exit.wait(limit)
  }

  /// SIGKILL, unless it has ended.
  package func kill() {
    if exit.current == nil { Darwin.kill(pid, SIGKILL) }
  }

  /// Closes its stdin (`keepStdin`): a child watching it sees the end. Once.
  package func closeStdin() {
    input.with { fd in
      if fd >= 0 { close(fd) }
      fd = -1
    }
  }

  deinit { closeStdin() }

  /// What it wrote, as UTF-8 (anything malformed as U+FFFD), once it's done.
  package func stdout() async -> String { String(decoding: await out.wait() ?? Data(), as: UTF8.self) }
  package func stderr() async -> String { String(decoding: await err.wait() ?? Data(), as: UTF8.self) }
}

/// A finished program's code and output.
package struct ProcessResult: Sendable {
  package let code: Int32
  package let out: String
  package let err: String
  package init(code: Int32, out: String, err: String) {
    self.code = code
    self.out = out
    self.err = err
  }
}

/// Runs [executable] to its end (dart:io's `Process.run`); killed and nil
/// when it runs longer than [timeout].
package func runProcess(
  _ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: Duration? = nil
) async throws(ProcessLaunchError) -> ProcessResult? {
  let p = try Subprocess.start(executable, arguments, environment: environment)
  let code: Int32?
  if let timeout { code = await p.exitCode(within: timeout) } else { code = await p.exitCode() }
  guard let code else {
    p.kill()
    return nil
  }
  return ProcessResult(code: code, out: await p.stdout(), err: await p.stderr())
}

/// A program's stdout, or "" when it can't be run (`(await Process.run(...)).stdout` in Dart).
func outputOf(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async -> String? {
  (try? await runProcess(executable, arguments, environment: environment))??.out
}

// ------------------------------------------------------------ files

/// What sits at a path, without following a link (FileSystemEntity.typeSync(followLinks: false)).
package enum FileKind: Sendable { case notFound, file, directory, link, socket, other }

package func fileKind(_ path: String, followLinks: Bool = false) -> FileKind {
  var st = stat()
  guard (followLinks ? stat(path, &st) : lstat(path, &st)) == 0 else { return .notFound }
  switch st.st_mode & S_IFMT {
  case S_IFREG: return .file
  case S_IFDIR: return .directory
  case S_IFLNK: return .link
  case S_IFSOCK: return .socket
  default: return .other
  }
}

/// The owner of what's at [path] (not following a link); nil when nothing is.
func fileOwner(_ path: String) -> uid_t? {
  var st = stat()
  return lstat(path, &st) == 0 ? st.st_uid : nil
}

/// Whether a folder is at [path], following links (Directory.existsSync).
package func directoryExists(_ path: String) -> Bool { fileKind(path, followLinks: true) == .directory }

/// Whether a file is at [path], following links (File.existsSync: anything but a folder).
package func fileExists(_ path: String) -> Bool {
  let k = fileKind(path, followLinks: true)
  return k != .notFound && k != .directory
}

/// [path] with every link resolved (resolveSymbolicLinksSync); nil when it can't be.
package func realPath(_ path: String) -> String? {
  guard let r = realpath(path, nil) else { return nil }
  defer { free(r) }
  return String(cString: r)
}

/// The names in folder [path] (listSync(followLinks: false)); empty when it can't be read.
func listNames(_ path: String) -> [String]? {
  try? FileManager.default.contentsOfDirectory(atPath: path)
}

// ------------------------------------------------------------ paths (package:path, POSIX)

package enum Paths {
  /// p.normalize: no `.`, `..` resolved, no doubled or trailing `/`.
  package static func normalize(_ path: String) -> String {
    if path.isEmpty { return "." }
    let absolute = path.dartStartsWith("/")
    var parts: [String] = []
    for part in path.components(separatedBy: "/") where !part.isEmpty && part != "." {
      if part == "..", let last = parts.last, last != ".." {
        parts.removeLast()
      } else if part == "..", absolute {
        continue
      } else {
        parts.append(part)
      }
    }
    let joined = parts.joined(separator: "/")
    return absolute ? "/" + joined : (joined.isEmpty ? "." : joined)
  }

  /// p.equals.
  package static func equals(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

  /// p.isWithin: [child] strictly under [parent].
  package static func isWithin(_ parent: String, _ child: String) -> Bool {
    let p = normalize(parent)
    let c = normalize(child)
    if p == c { return false }
    if p == "/" { return c.dartStartsWith("/") }
    return c.dartStartsWith(p + "/")
  }

  /// p.basename: the last part, trailing separators ignored.
  package static func basename(_ path: String) -> String {
    var s = Substring(path)
    while s.count > 1, s.hasSuffix("/") { s = s.dropLast() }
    if s == "/" { return "/" }
    return s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
  }

  /// p.dirname.
  package static func dirname(_ path: String) -> String {
    var s = Substring(path)
    while s.count > 1, s.hasSuffix("/") { s = s.dropLast() }
    guard let slash = s.lastIndex(of: "/") else { return "." }
    let head = s[..<slash]
    return head.isEmpty ? "/" : String(head)
  }

  /// p.join of two parts.
  package static func join(_ a: String, _ b: String) -> String {
    if a.isEmpty { return b }
    if b.dartStartsWith("/") { return b }
    return a.dartEndsWith("/") ? a + b : a + "/" + b
  }
}

extension Array where Element == String {
  /// Sorted as Dart sorts strings: by UTF-16 code units.
  package func dartSorted() -> [String] { sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) } }
}
#endif
