#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import PocketTermTerminals

/// The files phones send with prompts, as the agent gets them: each prompt's in a folder of its own under `dir` (by
/// default `pocketterm-files` in the user's temp folder, `$TMPDIR` on a Mac), under the name it had on the phone, made
/// safe (`safeFileName`). The prompt names them as `@path` (`withMentions`), as one would at the computer. Folders
/// older than a day go when more come and when PocketTerm starts.
public final class PromptFiles: Sendable {
  public let dir: String

  public init(_ dir: String? = nil) {
    self.dir = dir ?? Paths.join(systemTempDir(), "pocketterm-files")
  }

  public static let keep: TimeInterval = 24 * 60 * 60

  /// Writes `files` into a new folder, none over another; their paths.
  public func save(_ files: [PromptFile]) async throws -> [String] {
    if files.isEmpty { return [] }
    try makePrivateDir(dir)
    await prune()
    let folder = Paths.join(dir, randomId(12))
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var out: [String] = []
    for f in files { out.append(try Self.write(folder, safeFileName(f.name, mime: f.mime), f.bytes)) }
    return out
  }

  /// `bytes` as `name` in `folder`, or `name (2)`, `name (3)` … when that is taken.
  private static func write(_ folder: String, _ name: String, _ bytes: Data) throws -> String {
    let ext = pathExtension(name)
    let stem = dartSubstring(name, 0, dartLength(name) - dartLength(ext))
    var n = 1
    while true {
      let path = Paths.join(folder, n == 1 ? name : "\(stem) (\(n))\(ext)")
      n += 1
      let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
      if fd < 0 {
        if errno == EEXIST { continue }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
      }
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      return path
    }
  }

  /// Deletes the folders older than `keep`.
  public func prune() async {
    pruneOld(in: dir, folders: true, label: "prompt files cleanup")
  }
}

/// Makes `path` (and what's above it) when it isn't there, private to this user.
func makePrivateDir(_ path: String) throws {
  if directoryExists(path) { return }
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  chmod(path, 0o700)
}

/// Deletes the folders (`folders`) or files in `dir` modified before `PromptFiles.keep` ago.
func pruneOld(in dir: String, folders: Bool, label: String) {
  guard directoryExists(dir), let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
  let before = Date().addingTimeInterval(-PromptFiles.keep)
  for name in names {
    let path = Paths.join(dir, name)
    let kind = fileKind(path)
    if folders ? kind != .directory : kind != .file { continue }
    do {
      let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
      if let modified, modified < before { try FileManager.default.removeItem(atPath: path) }
    } catch {
      debugLog("PocketTerm: \(label): \(error)")
    }
  }
}

/// The user's temp folder (Dart's `Directory.systemTemp`), without a trailing `/`.
func systemTempDir() -> String {
  var t = NSTemporaryDirectory()
  while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
  return t
}

/// `n` random characters of 0-9a-z.
func randomId(_ n: Int) -> String {
  let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
  var rng = SystemRandomNumberGenerator()
  return String((0..<n).map { _ in digits[Int.random(in: 0..<36, using: &rng)] })
}

/// package:path's `extension`: from the last dot of the last part, unless that dot comes first (`.env` has none).
func pathExtension(_ path: String) -> String {
  let file = Paths.basename(path)
  if file == ".." { return "" }
  let u = Array(file.utf16)
  guard let dot = u.lastIndex(of: 0x2E), dot > 0 else { return "" }
  return String(decoding: u[dot...], as: UTF16.self)
}

/// Dart's `length` (UTF-16 code units).
func dartLength(_ s: String) -> Int { s.utf16.count }

/// Dart's `substring(start, end)` (UTF-16 offsets).
func dartSubstring(_ s: String, _ start: Int, _ end: Int? = nil) -> String {
  (s as NSString).substring(with: NSRange(location: start, length: (end ?? dartLength(s)) - start))
}

private let pathSeparators = TermRegex(#"[/\\]"#)
private let badNameChars = TermRegex(#"[\x00-\x1f\x7f<>:"|?*]"#)
private let trailingDotsSpaces = TermRegex(#"[. ]+\z"#)

/// A name Windows opens as a device: its part before the first dot, spaces after it ignored, is one of these.
private let deviceName = TermRegex(
  #"^(con|prn|aux|nul|conin\$|conout\$|com[0-9¹²³]|lpt[0-9¹²³]) *(\.[^\n\r\x{2028}\x{2029}]*)?\z"#,
  caseInsensitive: true)

/// `name` as a file name that stays in its folder: only what follows its last `/` or `\`, without control
/// characters or the ones Windows refuses (`<>:"|?*`), spaces and dots at its end (so never `.` or `..`) or a
/// Windows device name (`CON`, `CONIN$`, `COM¹`, … with any extension, also with spaces before it); at most 120
/// characters, its extension kept. Without an extension it gets the one `mime` has. `file` when nothing is left.
public func safeFileName(_ name: String, mime: String = "") -> String {
  var n = dartTrim(badNameChars.replaceAll(pathSeparators.split(name).last!, ""))
  n = trailingDotsSpaces.replaceFirst(n, "")
  if n.isEmpty { n = "file" }
  if fileExtension(n).isEmpty, let ext = mimeExtension(mime) { n = "\(n).\(ext)" }
  if deviceName.hasMatch(n) { n = "_\(n)" }
  if dartLength(n) > 120 {
    let ext = pathExtension(n)
    n =
      dartLength(ext) < 20
      ? dartTrimRight(dartSubstring(n, 0, 120 - dartLength(ext))) + ext : dartSubstring(n, 0, 120)
  }
  return n
}

/// Dart's `trimRight()`.
func dartTrimRight(_ s: String) -> String {
  guard let last = s.unicodeScalars.lastIndex(where: { !dartSpace($0) }) else { return "" }
  return String(s.unicodeScalars[...last])
}

/// Dart's whitespace for `trim()`.
private func dartSpace(_ c: Unicode.Scalar) -> Bool {
  switch c.value {
  case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
  default: false
  }
}

private let plainMention = TermRegex(#"^[A-Za-z0-9_./+~,=%-]*[A-Za-z0-9_/+~=%-]\z"#)

/// `path` as omp and Claude Code take a file named in a prompt: `@path`, or `@"path"` when it holds a character
/// that would end the mention (a space, a quote) or a trailing one they'd take for punctuation.
public func fileMention(_ path: String) -> String { plainMention.hasMatch(path) ? "@\(path)" : "@\"\(path)\"" }

/// `text` with a mention (`fileMention`) of each of `paths` after it.
public func withMentions(_ text: String, _ paths: [String]) -> String {
  if paths.isEmpty { return text }
  return [dartTrim(text), paths.map(fileMention).joined(separator: " ")].filter { !$0.isEmpty }
    .joined(separator: "\n\n")
}
#endif
