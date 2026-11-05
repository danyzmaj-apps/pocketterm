import CryptoKit
import Foundation
import XCTest

@testable import PocketTermKit

/// Every case of vectors.json's `live` section (tool/vectors/README.md), but the terminal and agent models,
/// which the terminal model's tests check.
final class LiveVectorTests: XCTestCase {
  private func cases(_ path: String...) -> [JSON] {
    var v = Vectors.section("live")
    for p in path { v = v[p]! }
    return v.array ?? v["cases"]!.array!
  }

  private func note(_ c: JSON) -> String { c["note"]?.string ?? "" }

  /// A JSON object made from a vector's item, its repeated strings expanded.
  private func expanded(_ j: JSON) -> JSONObject {
    j.object!.mapValues { v in v.object?["repeat"] != nil ? .string(Vectors.text(v)!) : v }
  }

  private func items(_ j: JSON?) -> [LiveItem] { j!.array!.map { LiveItem(json: $0.object!)! } }
  private func itemsJson(_ items: [LiveItem]) -> JSON { .array(items.map { .object($0.toJson()) }) }

  /// The README's summary of a long string.
  private func summary(_ s: String) -> JSON {
    let scalars = Array(s.unicodeScalars)
    func text(_ part: ArraySlice<Unicode.Scalar>) -> JSON {
      var out = ""
      out.unicodeScalars.append(contentsOf: part)
      return .string(out)
    }
    return [
      "codeUnits": .int(s.utf16.count),
      "utf8Bytes": .int(s.utf8.count),
      "jsonBytes": .int(jsonBytes(s)),
      "sha256": .string(SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()),
      "head": text(scalars.prefix(40)),
      "tail": text(scalars.suffix(40)),
    ]
  }

  func testRoutedKeys() {
    let routed = cases("routedKey")
    for c in routed {
      XCTAssertEqual(routedKey(c["desktop"]!.string!, c["key"]!.string!), c["routed"]!.string!, note(c))
    }
    let split = cases("splitRoutedKey")
    for c in split {
      let r = splitRoutedKey(c["input"]!.string!)
      if c["result"]!.isNull {
        XCTAssertNil(r, note(c))
      } else {
        XCTAssertEqual(r?.desktop, c["result"]!["desktop"]!.string, note(c))
        XCTAssertEqual(r?.key, c["result"]!["key"]!.string, note(c))
      }
    }
    XCTAssertEqual(routed.count + split.count, 13)
  }

  func testJsonBytes() {
    let all = cases("jsonBytes")
    for c in all {
      let units = c["utf16"]!.array!.map { UInt16($0.int!) }
      let bytes = c["bytes"]!.int!
      XCTAssertEqual(jsonBytes(utf16: units), bytes, note(c))
      if let s = c["input"]?.string {
        XCTAssertEqual(jsonBytes(s), bytes, note(c))
        XCTAssertEqual(Array(s.utf16), units, note(c))
      }
    }
    XCTAssertEqual(all.count, 10)
  }

  func testChunkJson() {
    let all = cases("chunkJson")
    for c in all {
      let chunks = chunkJson(c["items"]!.array!.map { $0.object! }, maxBytes: c["maxBytes"]!.int!)
      XCTAssertEqual(JSON.array(chunks.map { .array($0.map(JSON.object)) }), c["chunks"]!, note(c))
    }
    XCTAssertEqual(all.count, 5)
  }

  func testConstants() {
    let c = Vectors.section("live")["constants"]!
    XCTAssertEqual(cutNote, c["cutNote"]!.string!)
    XCTAssertEqual(maxItemTextBytes, c["maxItemTextBytes"]!.int!)
    XCTAssertEqual(maxOutputBytes, c["maxOutputBytes"]!.int!)
    XCTAssertEqual(maxArgsBytes, c["maxArgsBytes"]!.int!)
    XCTAssertEqual(maxTitleBytes, c["maxTitleBytes"]!.int!)
    XCTAssertEqual(LiveLog([], older: false).cap, c["logCap"]!.int!)
    XCTAssertEqual(LiveView(epoch: "e").cap, c["viewCap"]!.int!)
    // The defaults, by their effect: a chunk closes past 40000 bytes, the cache keeps the newest 600.
    let maxBytes = c["chunkJsonDefaultMaxBytes"]!.int!
    let item: JSONObject = ["t": .string(String(repeating: "x", count: maxBytes / 2 - 9))]  // encodes to maxBytes / 2 - 1
    XCTAssertEqual(chunkJson([item, item]).count, 1)
    XCTAssertEqual(chunkJson([item, item, ["t": "x"]]).count, 2)
    let keep = c["viewCacheKeep"]!.int!
    let view = LiveView(epoch: "e", items: (0...keep).map { LiveItem(id: "\($0)", kind: .user, order: $0) })
    let json = view.toJson()
    XCTAssertEqual(json["items"]!.array!.count, keep)
    XCTAssertEqual(json["older"], true)
  }

  func testClip() {
    let all = cases("clip")
    for c in all {
      let log = LiveLog([], older: false)
      if let input = c["input"] {
        _ = log.upsert(LiveItem(json: expanded(input))!)
        let item = log.items[0]
        XCTAssertEqual(summary(item.text), c["text"]!, note(c))
        XCTAssertEqual(summary(item.title), c["title"]!, note(c))
        XCTAssertEqual(summary(item.args), c["args"]!, note(c))
        XCTAssertEqual(summary(item.output), c["output"]!, note(c))
      } else {
        _ = log.upsert(LiveItem(id: "a", kind: .assistant))
        var nonNull = 0
        var last: LiveOp?
        for i in 0..<140 {
          if let op = log.append("a", "\(i) " + String(repeating: "x", count: 500) + "\n") {
            nonNull += 1
            last = op
          }
        }
        XCTAssertEqual(nonNull, c["appendsNonNull"]!.int!, note(c))
        let expect = c["lastNonNullOp"]!
        XCTAssertEqual(last?.seq, expect["s"]!.int!)
        XCTAssertEqual(last?.id, expect["id"]!.string!)
        XCTAssertEqual(summary(last!.append!), expect["a"]!)
        XCTAssertEqual(summary(log.items[0].text), c["text"]!, note(c))
      }
    }
    XCTAssertEqual(all.count, 6)
  }

  func testLogScenario() {
    let s = Vectors.section("live")["logScenario"]!
    let log = LiveLog(items(s["snapshot"]), older: true, epoch: "e1")
    XCTAssertEqual(itemsJson(log.items), s["snapshotStored"]!)
    var wire: [JSON] = []
    for step in s["steps"]!.array! {
      let action = step["action"]!
      var ops: [LiveOp?]
      if let u = action["upsert"] {
        ops = [log.upsert(LiveItem(json: u.object!)!)]
      } else if let a = action["append"] {
        ops = [log.append(a["id"]!.string!, a["text"]!.string!)]
      } else {
        let o = action["addOlder"]!
        ops = log.addOlder(items(o["items"]), more: o["more"]!.bool!)
      }
      let json = JSON.array(ops.map { $0.map { .object($0.toJson()) } ?? .null })
      XCTAssertEqual(json, step["ops"]!, note(step))
      wire += ops.compactMap { $0.map { .object($0.toJson()) } }
    }
    XCTAssertEqual(log.seq, s["finalSeq"]!.int!)
    XCTAssertEqual(log.older, s["finalOlder"]!.bool!)
    XCTAssertEqual(itemsJson(log.items), s["finalItems"]!)
    XCTAssertEqual(itemsJson(log.since(3)), s["since3"]!)

    // The phone, given the wire ops (through JSON).
    let ops = wire.map { LiveOp(json: try! JSON.parse($0.encoded()).object!)! }
    func caughtUp(_ epoch: String = "e1") -> LiveView {
      LiveView(epoch: epoch, seq: 1, items: items(s["snapshotStored"]))
    }
    let all = caughtUp()
    XCTAssertEqual(all.apply("e1", ops), s["viewApplyAll"]!["result"]!.bool!)
    XCTAssertEqual(JSON.object(all.toJson()), s["viewApplyAll"]!["view"]!)
    XCTAssertEqual(caughtUp().apply("e1", Array(ops.dropFirst())), s["viewApplyWithGap"]!["result"]!.bool!)
    XCTAssertEqual(caughtUp("e0").apply("e1", ops), s["viewApplyOtherEpoch"]!["result"]!.bool!)
  }

  func testViewCatchUp() {
    let v = Vectors.section("live")["viewCatchUp"]!
    let initial = v["initial"]!
    let view = LiveView(epoch: initial["epoch"]!.string!, seq: initial["seq"]!.int!, items: items(initial["items"]))
    let steps = v["steps"]!.array!
    for step in steps {
      let c = step["catchUp"]!
      view.catchUp(
        epoch: c["epoch"]!.string!, seq: c["seq"]!.int!, reset: c["reset"]!.bool!, items: items(c["items"]),
        last: c["last"]!.bool!, older: c["older"]!.bool)
      XCTAssertEqual(JSON.object(view.toJson()), step["view"]!, note(step))
    }
    XCTAssertEqual(steps.count, 3)
  }

  private func commandsJson(_ commands: [LiveCommand]) -> JSON {
    .array(commands.map { ["name": .string($0.name), "description": .string($0.description)] })
  }

  func testCommands() {
    let parsed = cases("liveCommands")
    for c in parsed {
      XCTAssertEqual(commandsJson(liveCommands(c["input"])), c["commands"]!, note(c))
    }
    let m = Vectors.section("live")["matchCommands"]!
    let commands = liveCommands(m["commands"])
    XCTAssertEqual(commandsJson(commands), m["commands"]!)
    let matches = m["cases"]!.array!
    for c in matches {
      let names = matchCommands(commands, c["text"]!.string!, max: c["max"]!.int!).map(\.name)
      XCTAssertEqual(names, c["names"]!.strings!, note(c))
    }
    XCTAssertEqual(parsed.count + matches.count, 13)
  }

  func testAnswerKeys() {
    let all = cases("answerKeys")
    for c in all {
      let ask = LiveAsk(json: c["ask"]!.object!)!
      let answers = c["answers"]!.array!.map { LiveAnswer(json: $0.object!)! }
      let agent = Agent.parse(c["agent"])
      let steps = try? answerKeys(ask, answers: answers, approve: c["approve"]!.bool!, agent: agent)
      if c["steps"] == "error" {
        XCTAssertNil(steps, note(c))
        continue
      }
      let json = JSON.array(
        (steps ?? []).map { s -> JSON in
          switch s {
          case .keys(let k): ["keys": .strings(k)]
          case .typed(let t): ["type": .string(t)]
          case .settle: ["settle": true]
          }
        })
      XCTAssertEqual(json, c["steps"]!, note(c))
    }
    XCTAssertEqual(all.count, 22)
  }

  func testMenuKeysAndRowKeys() {
    let menu = cases("menuKeys")
    for c in menu {
      let keys = try? menuKeys(c["current"]!.int!, c["target"]!.int!, enter: c["enter"]!.bool!)
      if c["keys"] == "error" {
        XCTAssertNil(keys, note(c))
      } else {
        XCTAssertEqual(keys, c["keys"]!.strings!, note(c))
      }
    }
    let rows = cases("claudeRowKey")
    for c in rows {
      XCTAssertEqual(claudeRowKey(c["row"]!.int!), c["key"]!.string!, note(c))
    }
    XCTAssertEqual(menu.count + rows.count, 10)
  }

  func testParsePlanReview() {
    let all = cases("parsePlanReview")
    for c in all {
      let r = parsePlanReview(c["screen"]!.string!, agent: Agent.parse(c["agent"]))
      let json: JSON = r.map { ["options": .strings($0.options), "current": .int($0.current)] } ?? .null
      XCTAssertEqual(json, c["result"]!, note(c))
    }
    XCTAssertEqual(all.count, 10)
  }

  func testParseMenu() {
    let all = cases("parseMenu")
    for c in all {
      let m = parseMenu(c["screen"]!.string!)
      let json: JSON =
        m.map {
          [
            "title": .string($0.title),
            "items": .array($0.items.map { ["label": .string($0.label), "detail": .string($0.detail)] }),
            "current": .int($0.current), "filter": .bool($0.filter),
          ]
        } ?? .null
      XCTAssertEqual(json, c["result"]!, note(c))
    }
    XCTAssertEqual(all.count, 9)
  }

  func testAskOnScreen() {
    let all = cases("askOnScreen")
    for c in all {
      let ask = LiveAsk(json: c["ask"]!.object!)!
      XCTAssertEqual(
        askOnScreen(ask, c["screen"]!.string!, agent: Agent.parse(c["agent"])), c["onScreen"]!.bool!, note(c))
    }
    XCTAssertEqual(all.count, 12)
  }

  func testScreenDiff() {
    let between = cases("screenDiff", "between")
    for c in between {
      let a = c["a"]!.strings!
      let d = ScreenDiff.between(a, c["b"]!.strings!)
      XCTAssertEqual(d.map { JSON.object($0.toJson()) } ?? .null, c["diff"]!, note(c))
      if let d {
        XCTAssertEqual(d.apply(a), c["applied"]!.strings!, note(c))
      }
    }
    let apply = cases("screenDiff", "apply")
    for c in apply {
      let d = ScreenDiff(json: c["diff"]!.object!)!
      XCTAssertEqual(d.apply(c["a"]!.strings!).map(JSON.strings) ?? .null, c["result"]!, note(c))
    }
    XCTAssertEqual(between.count + apply.count, 12)
  }

  func testModels() {
    let m = Vectors.section("live")["models"]!
    func check(_ kind: String, _ roundTrip: (JSONObject, JSON) -> JSON?) -> Int {
      let all = m[kind]!.array!
      for c in all {
        XCTAssertEqual(roundTrip(c["input"]!.object!, c), c["output"]!, "\(kind): \(note(c))")
      }
      return all.count
    }
    var n = 0
    n += check("LiveItem") { j, _ in LiveItem(json: j).map { .object($0.toJson()) } }
    n += check("LiveQueued") { j, _ in LiveQueued(json: j).map { .object($0.toJson()) } }
    n += check("LiveOp") { j, _ in LiveOp(json: j).map { .object($0.toJson()) } }
    n += check("LiveAsk") { j, c in
      let ask = LiveAsk(json: j)!
      XCTAssertEqual(ask.text, c["text"]!.string!, note(c))
      return .object(ask.toJson())
    }
    n += check("LiveAnswer") { j, _ in LiveAnswer(json: j).map { .object($0.toJson()) } }
    n += check("LiveSummary") { j, _ in LiveSummary(json: j).map { .object($0.toJson()) } }
    n += check("LiveView") { j, c in
      LiveView(json: j).map { .object(c["keep"]?.int.map($0.toJson(keep:)) ?? $0.toJson()) }
    }
    n += check("ScreenDiff") { j, _ in ScreenDiff(json: j).map { .object($0.toJson()) } }
    XCTAssertEqual(n, 27)
  }

  func testChannelFrames() {
    let all = cases("frames", "channel")
    for c in all {
      let p = c["payload"]!.object!
      switch c["event"]!.string! {
      case "state":
        var parsed: JSONObject = [
          "windows": .array(p["windows"]!.array!.map { .object(TermWindow.fromJson($0.object!)!.toJson()) }),
          "sessions": .array(p["sessions"]!.array!.map { .object(LiveSummary(json: $0.object!)!.toJson()) }),
          "agents": .object(AgentIntegration.toJsonAll(AgentIntegration.parseAll(p["agents"]))),
        ]
        if let t = p["terminals"]?.array { parsed["terminals"] = .array(t.map { .object(TermStatus(json: $0.object!).toJson()) }) }
        XCTAssertEqual(JSON.object(parsed), c["parsed"]!, note(c))
      case "items":
        XCTAssertEqual(JSON.object(["items": itemsJson(items(p["items"]))]), c["parsed"]!, note(c))
      case "live":
        let ops = p["ops"]!.array!.map { JSON.object(LiveOp(json: $0.object!)!.toJson()) }
        XCTAssertEqual(JSON.object(["ops": .array(ops)]), c["parsed"]!, note(c))
      case "screen":
        if let d = p["diff"] { XCTAssertEqual(JSON.object(ScreenDiff(json: d.object!)!.toJson()), d, note(c)) }
        XCTAssertNil(c["parsed"])
      default:
        XCTAssertNil(c["parsed"], note(c))
      }
    }
    XCTAssertEqual(all.count, 19)
  }

  func testLocalFrames() {
    let all = cases("frames", "local")
    for c in all {
      let f = c["frame"]!.object!
      var parsed: JSONObject = [:]
      if f["commands"] != nil { parsed["commands"] = commandsJson(liveCommands(f["commands"])) }
      if let i = f["item"] { parsed["item"] = .object(LiveItem(json: i.object!)!.toJson()) }
      if let a = f["ask"]?.object { parsed["ask"] = .object(LiveAsk(json: a)!.toJson()) }
      if let list = f["items"]?.array {
        // hello's and reply's items: each one an item.
        XCTAssertEqual(list.compactMap { $0.object.flatMap(LiveItem.init(json:)) }.count, list.count, note(c))
      }
      if let expected = c["parsed"] {
        XCTAssertEqual(JSON.object(parsed), expected, note(c))
      }
    }
    XCTAssertEqual(all.count, 21)
  }
}
