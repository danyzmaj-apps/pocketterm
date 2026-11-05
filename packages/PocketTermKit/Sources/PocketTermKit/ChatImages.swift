import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How many images and files one message to a session takes.
public let maxChatAttachments = 10

/// The largest file a message takes: sealed, it's the most the server holds (20 MB).
public let maxChatFileBytes = Servers.maxBlobBytes - sealedOverhead

/// The longest side an image is sent at: plenty for reading a screenshot, and it keeps uploads and the
/// model's image tokens small.
public let maxImageSide = 2048

/// An image no bigger than this (and [maxImageSide]) in a type every model reads is sent as it is.
public let keepAsIsMaxBytes = 4 << 20

/// Picked files with these extensions go as images, scaled down like photos.
public let chatImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

/// An image about to be sent: its bytes and their type. A class: a composer tells its attachments apart by
/// identity, as Dart does.
public final class ChatImage: Sendable {
  public let bytes: Data
  /// image/png, image/jpeg, image/gif or image/webp.
  public let mime: String

  public init(_ bytes: Data, _ mime: String) {
    self.bytes = bytes
    self.mime = mime
  }
}

/// A file about to be sent as it is (a document, an archive): the agent gets it under [name], as a file on
/// the computer.
public final class ChatFile: Sendable {
  public let name: String
  public let bytes: Data
  public let mime: String

  public init(_ name: String, _ bytes: Data, _ mime: String) {
    self.name = name
    self.bytes = bytes
    self.mime = mime
  }
}

/// Something a message takes along: a [ChatImage] or a [ChatFile]. Equal only to itself.
public enum ChatAttachment: Hashable, Identifiable, Sendable {
  case image(ChatImage)
  case file(ChatFile)

  public var id: ObjectIdentifier {
    switch self {
    case .image(let i): ObjectIdentifier(i)
    case .file(let f): ObjectIdentifier(f)
    }
  }

  public var image: ChatImage? { if case .image(let i) = self { i } else { nil } }
  public var file: ChatFile? { if case .file(let f) = self { f } else { nil } }

  public static func == (a: ChatAttachment, b: ChatAttachment) -> Bool { a.id == b.id }
  public func hash(into h: inout Hasher) { h.combine(id) }
}

/// [bytes] for people: `512 bytes`, `3.4 KB`, `12.0 MB` (one decimal, halves rounded up as Dart's
/// `toStringAsFixed` does).
public func formatBytes(_ bytes: Int) -> String {
  func tenths(_ unit: Int) -> String {
    // bytes / unit to one decimal, exactly: the nearest tenth, a tie going up.
    let n = (bytes * 10 + unit / 2) / unit
    return "\(n / 10).\(n % 10)"
  }
  if bytes < 1024 { return "\(bytes) bytes" }
  if bytes < 1024 * 1024 { return "\(tenths(1024)) KB" }
  return "\(tenths(1024 * 1024)) MB"
}

/// The type a model accepts, from the file's first bytes; nil for others.
public func sniffImageType(_ b: Data) -> String? {
  let b = [UInt8](b.prefix(12))
  func at(_ i: Int, _ sig: [UInt8]) -> Bool { b.count >= i + sig.count && Array(b[i..<i + sig.count]) == sig }
  if at(0, [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
  if at(0, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
  if at(0, [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
  if at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50]) { return "image/webp" }
  return nil
}

/// [raw] as an image to send: kept as it is when it's a PNG, JPEG, GIF or WebP no bigger than
/// [maxImageSide] and 4 MB, else decoded (its first frame, turned upright), scaled down to fit and
/// re-encoded as PNG (which also turns TIFF, HEIC and the like into something every model reads). Nil when
/// it isn't an image. Runs off the main actor.
public func prepareChatImage(_ raw: Data) async -> ChatImage? {
  await Task.detached(priority: .userInitiated) { prepareChatImageNow(raw) }.value
}

private func prepareChatImageNow(_ raw: Data) -> ChatImage? {
  guard let source = CGImageSourceCreateWithData(raw as CFData, nil), CGImageSourceGetCount(source) > 0,
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
    let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0
  else { return nil }
  let mime = sniffImageType(raw)
  if let mime, max(w, h) <= maxImageSide, raw.count <= keepAsIsMaxBytes { return ChatImage(raw, mime) }

  // Upright at full size: EXIF orientations 5–8 swap the sides.
  let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
  let (uw, uh) = orientation >= 5 && orientation <= 8 ? (h, w) : (w, h)
  let upright: CGImage?
  if orientation == 1 {
    upright = CGImageSourceCreateImageAtIndex(source, 0, nil)
  } else {
    upright = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(uw, uh),
      ] as CFDictionary)
  }
  guard let image = upright else { return nil }

  let scale = min(1, Double(maxImageSide) / Double(max(uw, uh)))
  let tw = max(1, Int((Double(uw) * scale).rounded()))
  let th = max(1, Int((Double(uh) * scale).rounded()))
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
  guard let scaled = context.makeImage() else { return nil }

  let out = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
  CGImageDestinationAddImage(dest, scaled, nil)
  guard CGImageDestinationFinalize(dest) else { return nil }
  return ChatImage(out as Data, "image/png")
}

/// A file picked from the phone's files (Dart's `XFile`): its name, its size before reading it, its bytes
/// and the type the picker gave, if any.
public protocol PickedFile: Sendable {
  var name: String { get }
  /// The type the picker gave; nil or empty: named from [name].
  var mimeType: String? { get }
  func length() async throws -> Int
  func readAsBytes() async throws -> Data
}

/// A picked file on disk, as `fileImporter` and `UIDocumentPicker` hand them over (security-scoped).
public struct PickedURLFile: PickedFile {
  public let url: URL
  public let mimeType: String?

  public init(_ url: URL, mimeType: String? = nil) {
    self.url = url
    self.mimeType = mimeType
  }

  public var name: String { url.lastPathComponent }

  private func scoped<T>(_ body: () throws -> T) rethrows -> T {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try body()
  }

  public func length() async throws -> Int {
    try scoped { try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Data(contentsOf: url).count }
  }

  public func readAsBytes() async throws -> Data { try scoped { try Data(contentsOf: url) } }
}

/// A picked file already in memory (a pasted file, a test); [size] stands in for its length when given.
public struct PickedDataFile: PickedFile {
  public let name: String
  public let bytes: Data
  public let mimeType: String?
  public let size: Int?

  public init(_ name: String, _ bytes: Data, mimeType: String? = nil, size: Int? = nil) {
    self.name = name
    self.bytes = bytes
    self.mimeType = mimeType
    self.size = size
  }

  public func length() async throws -> Int { size ?? bytes.count }
  public func readAsBytes() async throws -> Data { bytes }
}

/// The images and files a composer holds until the message is sent, at most [maxChatAttachments], in the
/// order they came. Images load through [prepareChatImage]; files go as they are, up to [maxChatFileBytes]
/// each. Errors (not an image, too many, too large) go to [problem] for the composer to show. While images
/// load, [loading] is true and [pending] counts those not ready yet; each joins [items] as soon as it is.
/// `objectWillChange` fires right after each change, where Dart notifies its listeners.
@MainActor
public final class ChatAttachments: ObservableObject {
  public private(set) var items: [ChatAttachment] = []
  public private(set) var problem: String?

  /// True from the moment the photo picker opens until it hands back its images.
  public private(set) var picking = false

  /// Images and files taken in but not ready yet.
  public private(set) var pending = 0

  public init() {}

  public var isEmpty: Bool { items.isEmpty }
  public var loading: Bool { picking || pending > 0 }
  /// How many more a message takes: the photo picker's limit.
  public var room: Int { maxChatAttachments - items.count - pending }

  public nonisolated static let tooMany = "At most \(maxChatAttachments) images and files per message."

  private func notify() { objectWillChange.send() }

  /// Adds images (pasted, picked from photos); what isn't an image is left out, and said so.
  public func addAll(_ raws: [Data]) async {
    problem = nil
    let take = min(raws.count, maxChatAttachments - items.count)
    if raws.count > take { problem = Self.tooMany }
    pending = max(take, 0)
    notify()
    var skipped = 0
    defer {
      pending = 0
      notify()
    }
    for raw in raws.prefix(max(take, 0)) {
      if let image = await prepareChatImage(raw) {
        items.append(.image(image))
      } else {
        skipped += 1
      }
      pending -= 1
      notify()
    }
    if skipped > 0 {
      problem = problem ?? (skipped == 1 ? "That isn't an image PocketTerm can read." : "\(skipped) files aren't images.")
    }
  }

  /// Adds files picked from the phone's files. Images among them (by their extension or their first bytes)
  /// go as images; a file over [maxChatFileBytes] is left out, and said so. A file that can't be read
  /// stops it with that error.
  public func addFiles(_ files: [any PickedFile]) async throws {
    problem = nil
    let take = min(files.count, maxChatAttachments - items.count)
    if files.count > take { problem = Self.tooMany }
    pending = max(take, 0)
    notify()
    var tooLarge: [String] = []
    defer {
      pending = 0
      notify()
    }
    for f in files.prefix(max(take, 0)) {
      try await addFile(f, &tooLarge)
      pending -= 1
      notify()
    }
    if !tooLarge.isEmpty {
      let most = "files can be up to \(maxChatFileBytes / (1000 * 1000)) MB"
      problem =
        problem
        ?? (tooLarge.count == 1 ? "\"\(tooLarge[0])\" is too large: \(most)." : "\(tooLarge.count) files are too large: \(most).")
    }
  }

  /// Adds [f] to [items], or its name to [tooLarge].
  private func addFile(_ f: any PickedFile, _ tooLarge: inout [String]) async throws {
    let name = f.name.isEmpty ? "file" : f.name
    let named = chatImageExtensions.contains(fileExtension(name))
    if !named, try await f.length() > maxChatFileBytes {
      tooLarge.append(name)
      return
    }
    let bytes = try await f.readAsBytes()
    let image = named || sniffImageType(bytes) != nil ? await prepareChatImage(bytes) : nil
    if let image {
      items.append(.image(image))
    } else if bytes.count > maxChatFileBytes {
      tooLarge.append(name)
    } else {
      let mime = f.mimeType
      items.append(.file(ChatFile(name, bytes, mime == nil || mime!.isEmpty ? fileMime(name) : mime!)))
    }
  }

  /// Pastes the clipboard's images (the app reads them); false if it holds none (a text paste then goes
  /// ahead as usual).
  public func paste(_ raws: [Data]) async -> Bool {
    if raws.isEmpty { return false }
    await addAll(raws)
    return true
  }

  /// Picks photos through [pickImages] (the app's photo picker, given [room] as its limit; nothing when
  /// cancelled); [picking] shows a placeholder until it hands them back.
  public func pick(_ pickImages: (_ limit: Int) async throws -> [Data]) async rethrows {
    picking = true
    notify()
    let raws: [Data]
    do {
      raws = room <= 0 ? [] : try await pickImages(room)
      picking = false
      notify()
    } catch {
      picking = false
      notify()
      throw error
    }
    await addAll(raws)
  }

  public func removeAt(_ i: Int) {
    items.remove(at: i)
    problem = nil
    notify()
  }

  /// Takes out [sent] (the ones a message took), keeping what came since.
  public func removeSent(_ sent: some Sequence<ChatAttachment>) {
    let gone = Set(sent)
    items.removeAll(where: gone.contains)
    notify()
  }

  /// Takes everything out.
  public func clear() {
    items.removeAll()
    problem = nil
    notify()
  }
}
