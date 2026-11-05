import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PocketTermKit

/// A teal PNG of [w]×[h].
private func png(_ w: Int, _ h: Int) -> Data {
  let context = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(red: 0, green: 0.5, blue: 0.5, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: w, height: h))
  let out = NSMutableData()
  let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, context.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
  return out as Data
}

private func sizeOf(_ bytes: Data) -> (Int, Int)? {
  guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { return nil }
  return (image.width, image.height)
}

private func picked(_ name: String, _ bytes: Data, length: Int? = nil) -> PickedDataFile {
  PickedDataFile(name, bytes, size: length)
}

@MainActor
final class ChatImagesTests: XCTestCase {
  func testVectorLimits() {
    let l = Vectors.section("chatImages")["limits"]!
    XCTAssertEqual(maxChatAttachments, l["maxChatAttachments"]?.int)
    XCTAssertEqual(maxChatFileBytes, l["maxChatFileBytes"]?.int)
    XCTAssertEqual(Servers.maxBlobBytes, l["maxBlobBytes"]?.int)
    XCTAssertEqual(maxImageSide, l["maxImageSide"]?.int)
    XCTAssertEqual(keepAsIsMaxBytes, l["keepAsIsMaxBytes"]?.int)
    XCTAssertEqual(chatImageExtensions, Set(l["imageExtensions"]!.strings!))
  }

  func testVectorSniffImageType() {
    let cases = Vectors.cases("chatImages", "sniffImageType")
    XCTAssertEqual(cases.count, 12)
    for v in cases {
      XCTAssertEqual(sniffImageType(Vectors.hex(v["bytes"]!.string!)), v["mime"]?.string, v["note"]?.string ?? "")
    }
  }

  func testVectorFormatBytes() {
    let cases = Vectors.cases("chatImages", "formatBytes")
    XCTAssertEqual(cases.count, 12)
    for v in cases {
      XCTAssertEqual(formatBytes(v["bytes"]!.int!), v["text"]?.string)
    }
  }

  func testFormatBytesRoundsHalvesUpAsDart() {
    // 1280 / 1024 = 1.25 exactly: Dart's toStringAsFixed(1) gives 1.3, printf's %.1f 1.2.
    XCTAssertEqual(formatBytes(1280), "1.3 KB")
  }

  func testASmallImageIsSentAsItIs() async throws {
    let raw = png(maxImageSide, 300)
    let prepared = await prepareChatImage(raw)
    let image = try XCTUnwrap(prepared)
    XCTAssertEqual(image.mime, "image/png")
    XCTAssertEqual(image.bytes, raw)
  }

  func testABigImageIsScaledToFitKeepingItsShape() async throws {
    let prepared = await prepareChatImage(png(3000, 1000))
    let image = try XCTUnwrap(prepared)
    XCTAssertEqual(image.mime, "image/png")
    XCTAssertEqual(sizeOf(image.bytes)?.0, 2048)
    XCTAssertEqual(sizeOf(image.bytes)?.1, 683)
  }

  func testATallImageIsScaledByItsHeight() async throws {
    let prepared = await prepareChatImage(png(500, 4096))
    let image = try XCTUnwrap(prepared)
    XCTAssertEqual(sizeOf(image.bytes)?.0, 250)
    XCTAssertEqual(sizeOf(image.bytes)?.1, 2048)
  }

  func testSomethingThatIsNotAnImageIsRefused() async {
    let result = await prepareChatImage(Data("hello, not a picture".utf8))
    XCTAssertNil(result)
  }

  func testImageTypesAreToldByTheirFirstBytes() {
    XCTAssertEqual(sniffImageType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "image/png")
    XCTAssertEqual(sniffImageType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
    XCTAssertEqual(sniffImageType(Data("GIF89a".utf8)), "image/gif")
    XCTAssertEqual(sniffImageType(Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "image/webp")
    XCTAssertNil(sniffImageType(Data("RIFF\0\0\0\0WAVEfmt ".utf8)))
    XCTAssertNil(sniffImageType(Data([0x49, 0x49, 0x2A, 0x00])), "TIFF gets re-encoded")
  }

  func testAPickedDocumentGoesAsAFileAPictureAsAnImageInOrder() async throws {
    let a = ChatAttachments()
    try await a.addFiles([
      picked("notes.pdf", Data("%PDF-1.7".utf8)),
      picked("shot.png", png(40, 30)),
      picked("README", Data("plain words".utf8)),
    ])
    XCTAssertNil(a.problem)
    XCTAssertEqual(a.items.count, 3)
    XCTAssertNotNil(a.items[0].file)
    XCTAssertNotNil(a.items[1].image)
    let pdf = try XCTUnwrap(a.items[0].file)
    XCTAssertEqual(pdf.name, "notes.pdf")
    XCTAssertEqual(pdf.mime, "application/pdf")
    XCTAssertEqual(String(decoding: pdf.bytes, as: UTF8.self), "%PDF-1.7")
    XCTAssertEqual(a.items[2].file?.mime, "application/octet-stream")
  }

  func testAPickerTypeWinsOverTheName() async throws {
    let a = ChatAttachments()
    try await a.addFiles([PickedDataFile("x.bin", Data("a".utf8), mimeType: "text/plain"), PickedDataFile("", Data("b".utf8))])
    XCTAssertEqual(a.items[0].file?.mime, "text/plain")
    XCTAssertEqual(a.items[1].file?.name, "file")
  }

  func testAFileOver20MBIsLeftOutAndSaidSoTheOthersStillCome() async throws {
    let a = ChatAttachments()
    try await a.addFiles([
      picked("huge.zip", Data([1, 2, 3]), length: maxChatFileBytes + 1),
      picked("small.txt", Data("ok".utf8)),
    ])
    XCTAssertEqual(a.items.map { $0.file?.name }, ["small.txt"])
    XCTAssertEqual(a.problem, "\"huge.zip\" is too large: files can be up to 20 MB.")

    try await a.addFiles([picked("exactly.bin", Data([0]), length: maxChatFileBytes)])
    XCTAssertNil(a.problem, "the most that, sealed, still fits the server")
    XCTAssertEqual(a.items.count, 2)

    try await a.addFiles([
      picked("a.zip", Data(), length: maxChatFileBytes + 1), picked("b.zip", Data(), length: maxChatFileBytes + 1),
    ])
    XCTAssertEqual(a.problem, "2 files are too large: files can be up to 20 MB.")
  }

  func testAMessageTakes10ImagesAndFilesTogetherNoMore() async throws {
    let a = ChatAttachments()
    let image = png(20, 20)
    await a.addAll(Array(repeating: image, count: 4))
    try await a.addFiles((0..<8).map { picked("doc\($0).txt", Data("x".utf8)) })
    XCTAssertEqual(a.items.count, 10)
    XCTAssertEqual(a.items.compactMap(\.image).count, 4)
    XCTAssertEqual(a.room, 0)
    XCTAssertEqual(a.problem, "At most 10 images and files per message.")

    await a.addAll([image])
    XCTAssertEqual(a.items.count, 10)
    XCTAssertEqual(a.problem, "At most 10 images and files per message.")

    // Sent: what came meanwhile stays.
    a.removeSent(Array(a.items.prefix(9)))
    XCTAssertEqual(a.items.map { $0.file?.name }, ["doc5.txt"])
  }

  func testImagesJoinOneAtATimeEachCountedAsPendingUntilItDoes() async {
    let a = ChatAttachments()
    let image = png(20, 20)
    var seen: [[Int]] = []
    var roomAtStart: Int?
    let sub = a.objectWillChange.sink {
      seen.append([a.items.count, a.pending])
      if roomAtStart == nil { roomAtStart = a.room }
    }
    defer { sub.cancel() }
    await a.addAll([image, image, image])
    XCTAssertEqual(seen, [[0, 3], [1, 2], [2, 1], [3, 0], [3, 0]])
    XCTAssertEqual(roomAtStart, 10 - 3)
    XCTAssertFalse(a.loading)
  }

  func testOnlyWhatFitsLoads() async {
    let a = ChatAttachments()
    let image = png(20, 20)
    await a.addAll(Array(repeating: image, count: 9))
    var pendingAtStart: [Int] = []
    let sub = a.objectWillChange.sink { pendingAtStart.append(a.pending) }
    defer { sub.cancel() }
    await a.addAll([image, image, image])
    XCTAssertEqual(pendingAtStart.first, 1)
    XCTAssertEqual(a.items.count, 10)
    XCTAssertEqual(a.problem, "At most 10 images and files per message.")
  }

  func testNotImagesAreSaidSo() async {
    let a = ChatAttachments()
    await a.addAll([Data("no".utf8)])
    XCTAssertEqual(a.problem, "That isn't an image PocketTerm can read.")
    await a.addAll([Data("no".utf8), Data("nope".utf8), png(2, 2)])
    XCTAssertEqual(a.problem, "2 files aren't images.")
    XCTAssertEqual(a.items.count, 1)
  }

  func testPickShowsPickingUntilThePickerHandsBackAndPasteNeedsImages() async {
    let a = ChatAttachments()
    var pickingSeen = false
    var limit: Int?
    await a.pick { room in
      pickingSeen = a.picking && a.loading
      limit = room
      return [png(4, 4)]
    }
    XCTAssertTrue(pickingSeen)
    XCTAssertEqual(limit, 10)
    XCTAssertFalse(a.picking)
    XCTAssertEqual(a.items.count, 1)

    let pastedNothing = await a.paste([])
    XCTAssertFalse(pastedNothing)
    let pasted = await a.paste([png(4, 4)])
    XCTAssertTrue(pasted)
    XCTAssertEqual(a.items.count, 2)
    a.removeAt(0)
    XCTAssertEqual(a.items.count, 1)
  }
}
