import Foundation

// The types of the files a prompt takes, by their extension: the phone names a file's type from its name,
// the computer gives a file without an extension the one its type has.

/// The type of a file called [name]; application/octet-stream when its extension says nothing known.
public func fileMime(_ name: String) -> String { mimeByExtension[fileExtension(name)] ?? "application/octet-stream" }

/// The extension files of type [mime] have (`pdf`), or nil.
public func mimeExtension(_ mime: String) -> String? {
  let type = (mime.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return fileMimes.first { $0.mime == type }?.ext
}

/// What follows the last dot of [name], in lower case; empty when none (or the dot comes first).
public func fileExtension(_ name: String) -> String {
  let u = Array(name.utf16)
  guard let dot = u.lastIndex(of: 0x2E), dot > 0 else { return "" }
  return (String(utf16CodeUnits: Array(u[(dot + 1)...]), count: u.count - dot - 1)).lowercased()
}

/// Every known extension and its type, in order: the first extension of a type is the one the computer
/// gives it.
public let fileMimes: [(ext: String, mime: String)] = [
  ("pdf", "application/pdf"),
  ("txt", "text/plain"),
  ("log", "text/plain"),
  ("md", "text/markdown"),
  ("csv", "text/csv"),
  ("tsv", "text/tab-separated-values"),
  ("html", "text/html"),
  ("xml", "application/xml"),
  ("json", "application/json"),
  ("yaml", "application/yaml"),
  ("yml", "application/yaml"),
  ("zip", "application/zip"),
  ("gz", "application/gzip"),
  ("rtf", "application/rtf"),
  ("doc", "application/msword"),
  ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
  ("xls", "application/vnd.ms-excel"),
  ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
  ("ppt", "application/vnd.ms-powerpoint"),
  ("pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
  ("pages", "application/vnd.apple.pages"),
  ("numbers", "application/vnd.apple.numbers"),
  ("key", "application/vnd.apple.keynote"),
  ("png", "image/png"),
  ("jpg", "image/jpeg"),
  ("jpeg", "image/jpeg"),
  ("gif", "image/gif"),
  ("webp", "image/webp"),
  ("heic", "image/heic"),
  ("heif", "image/heif"),
  ("tif", "image/tiff"),
  ("tiff", "image/tiff"),
  ("bmp", "image/bmp"),
  ("svg", "image/svg+xml"),
  ("mp3", "audio/mpeg"),
  ("m4a", "audio/mp4"),
  ("wav", "audio/wav"),
  ("mp4", "video/mp4"),
  ("mov", "video/quicktime"),
]

private let mimeByExtension: [String: String] = Dictionary(
  fileMimes.map { ($0.ext, $0.mime) }, uniquingKeysWith: { first, _ in first }
)
