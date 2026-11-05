#if os(macOS)
import Foundation
import PocketTermKit
import XCTest
@testable import PocketTermDesktop

/// local_api_test.dart.
final class LocalApiTests: XCTestCase {
  func testCliJsonIsUnderHomeAsTheProcessHasItUnlessATestBuildNamesAnother() {
    // A throwaway HOME (tool/smoke, tool/e2e) keeps the person's own cli.json untouched.
    XCTAssertEqual(
      LocalApi.defaultFile(env: ["HOME": "/tmp/pocketterm-home"], hooks: [:]),
      "/tmp/pocketterm-home/.config/pocketterm/cli.json")
    XCTAssertEqual(
      LocalApi.defaultFile(env: ["HOME": "/tmp/pocketterm-home"], hooks: ["POCKETTERM_CLI_JSON": "/tmp/e2e/cli.json"]),
      "/tmp/e2e/cli.json")
    XCTAssertEqual(
      LocalApi.defaultFile(env: ["HOME": "/tmp/pocketterm-home"], hooks: ["POCKETTERM_CLI_JSON": ""]),
      "/tmp/pocketterm-home/.config/pocketterm/cli.json")
  }

  private var dir = ""

  override func setUp() {
    dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pocketterm-cli-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  }

  override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

  private var cliFile: String { (dir as NSString).appendingPathComponent("cli.json") }

  @MainActor
  private func started(
    _ live: LiveEndpoint = ApiFakeEndpoint(), file: String? = nil, hold: TimeInterval = LocalApi.pollHold,
    idle: TimeInterval = LocalApi.pollIdle, watch: TimeInterval = LocalApi.watchEvery
  ) async throws -> (LocalApi, String) {
    let api = LocalApi(live: live, file: file ?? cliFile, pollHold: hold, idle: idle, watchEvery: watch)
    try await api.start()
    let token = JSON.tryParse(try String(contentsOfFile: api.file, encoding: .utf8))!["token"]!.string!
    return (api, token)
  }

  private func mode(_ path: String) -> Int {
    (try! FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
  }

  // MARK: cli.json ownership

  private let ours = #"{"port":5000,"token":"mine","pid":1}"#

  private func reclaim(_ text: String?, running: Bool = false) async -> Bool {
    await LocalApi.shouldReclaim(text, ours) { _, _ in running }
  }

  func testKeepsItsOwnFileAndOneNamingAnotherRunningPocketTerm() async {
    let a = await reclaim(ours)
    let b = await reclaim(#"{"port":6000,"token":"other","pid":2}"#, running: true)
    XCTAssertFalse(a)
    XCTAssertFalse(b)
  }

  func testTakesItBackWhenMissingUnreadableOrNamingAGonePocketTerm() async {
    for text in [nil, #"{"port":"#, #"{"port":"6000"}"#, #"{"port":6000,"token":"other","pid":2}"#] {
      let r = await reclaim(text)
      XCTAssertTrue(r, text ?? "nil")
    }
  }

  @MainActor
  func testWritesItsAddressBackAfterAnotherOverwroteIt() async throws {
    let (api, _) = try await started(watch: 0.2)
    let written = try String(contentsOfFile: cliFile, encoding: .utf8)
    XCTAssertEqual(JSON.tryParse(written)?["port"]?.int, api.port)
    XCTAssertEqual(mode(cliFile), 0o600)
    // The own `~/.config/pocketterm` gets 700 only when no file is named; this one is named.
    // A debug build that has quit since.
    try #"{"port":1,"token":"dead","pid":999999}"#.write(toFile: cliFile, atomically: false, encoding: .utf8)
    let back = await apiPumpUntil { (try? String(contentsOfFile: cliFile, encoding: .utf8)) == written }
    XCTAssertTrue(back)
    await api.stop()
  }

  @MainActor
  func testProvesItIsTheOneAtItsPortWithoutTheTokenBeingSent() async throws {
    let (api, token) = try await started()
    let port = api.port!
    let yes = await LocalApi.answers(port, token)
    XCTAssertTrue(yes)
    // Some other server's token, or nobody at the port.
    let other = await LocalApi.answers(port, "not-its-token")
    XCTAssertFalse(other)
    await api.stop()
    let gone = await LocalApi.answers(port, token)
    XCTAssertFalse(gone)
  }

  func testAProofIsGoodForOnePortOnly() {
    let nonce = "0123456789abcdef"
    XCTAssertNotEqual(LocalApi.pingProof("t", 5000, nonce), LocalApi.pingProof("t", 5001, nonce))
    XCTAssertNotEqual(LocalApi.pingProof("t", 5000, nonce), LocalApi.pingProof("u", 5000, nonce))
  }

  /// tool/vectors/vectors.json `localApiPing`: the proof and which nonces are taken, as the server answers them.
  @MainActor
  func testPingMatchesTheVectors() async throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "../../../../tool/vectors/vectors.json")
    let cases = try JSON.parse(Data(contentsOf: url))["localApiPing"]!["cases"]!.array!
    XCTAssertFalse(cases.isEmpty)
    for c in cases {
      let token = c["token"]!.string!, port = c["port"]!.int!, nonce = c["nonce"]!.string!
      XCTAssertEqual(LocalApi.pingProof(token, port, nonce), c["proof"]!.string!)
      let (status, body) = LocalApi.route(
        method: "GET", uri: "/v1/ping?nonce=\(nonce)", authorization: nil, token: token, port: port)
      XCTAssertEqual(status, c["nonceAccepted"]!.bool! ? 200 : 400)
      if status == 200 { XCTAssertEqual(JSON.tryParse(body)?["proof"]?.string, c["proof"]!.string!) }
    }
  }

  @MainActor
  func testStoppingTakesCliJsonOutUnlessAnotherPocketTermWroteItSince() async throws {
    let (api, _) = try await started()
    await api.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: cliFile))

    let (again, _) = try await started()
    try #"{"port":6000,"token":"other","pid":2}"#.write(toFile: cliFile, atomically: false, encoding: .utf8)
    await again.stop()
    XCTAssertTrue(try String(contentsOfFile: cliFile, encoding: .utf8).contains(#""other""#))
  }

  @MainActor
  func testAWebSocketCarriesTextBothWaysAndStoppingEndsIt() async throws {
    let hub = ApiFakeEndpoint()
    let (api, token) = try await started(hub)
    var req = URLRequest(url: URL(string: "ws://127.0.0.1:\(api.port!)/v1/live")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let ws = session.webSocketTask(with: req)
    ws.resume()
    let hello = #"{"t":"hello","v":1,"agent":"omp","session":{"id":"s1","cwd":"/tmp"},"pid":7}"#
    try await ws.send(.string(hello))
    let heard = await apiPumpUntil { hub.frames == [hello] }
    XCTAssertTrue(heard)
    hub.links[0].send(#"{"t":"prompt"}"#)
    guard case .string(let back) = try await ws.receive() else { return XCTFail("not text") }
    XCTAssertEqual(back, #"{"t":"prompt"}"#)

    await api.stop()
    do {
      _ = try await ws.receive()
      XCTFail("still open")
    } catch {}
    XCTAssertEqual(ws.closeCode, .goingAway)
    let ended = await apiPumpUntil { hub.open == 0 }
    XCTAssertTrue(ended)
  }

  @MainActor
  func testAFolderPocketTermCliJsonNamesKeepsItsMode() async throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
    let (api, _) = try await started(file: (dir as NSString).appendingPathComponent("pocketterm.json"))
    XCTAssertEqual(mode(dir), 0o755)
    XCTAssertEqual(mode(api.file), 0o600)
    XCTAssertEqual(ApiFakeEndpoint.self == ApiFakeEndpoint.self, true)
    await api.stop()
  }

  @MainActor
  func testTheOrchestratorFolderIsBesideCliJson() {
    let hub = ApiFakeEndpoint()
    _ = LocalApi(live: hub, file: cliFile)
    XCTAssertEqual(hub.orchestratorDir, (dir as NSString).appendingPathComponent("orchestrator"))
  }

  // MARK: live sessions over HTTP long polls

  @MainActor
  private static func post(_ port: Int, _ body: String, auth: String) async throws -> (Int, JSONObject) {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/live/http")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(auth)", forHTTPHeaderField: "authorization")
    req.httpBody = Data(body.utf8)
    req.timeoutInterval = 30
    let (data, res) = try await URLSession(configuration: .ephemeral).data(for: req)
    return ((res as! HTTPURLResponse).statusCode, JSON.tryParse(data)?.object ?? [:])
  }

  private let hello =
    #"{"t":"hello","v":1,"agent":"claude","session":{"id":"s1","title":"","cwd":"/work/repo","model":"m"},"window":"kitty-1/3","pid":"x","busy":false,"items":[],"older":false,"commands":[]}"#

  @MainActor
  func testAHelloOpensASessionTheRequestWaitsInTheNextPollTheReplyAnswersIt() async throws {
    let hub = ApiFakeEndpoint()
    let (api, token) = try await started(hub)
    let port = api.port!
    let (status, opened) = try await Self.post(port, #"{"frames":[\#(hello)]}"#, auth: token)
    XCTAssertEqual(status, 200)
    XCTAssertEqual(opened["frames"], .array([]))
    let conn = opened["conn"]!.string!
    let heard = await apiPumpUntil { hub.frames.count == 1 }
    XCTAssertTrue(heard)
    XCTAssertEqual(JSON.tryParse(hub.frames[0])?["agent"]?.string, "claude")

    async let poll = Self.post(port, #"{"conn":"\#(conn)","frames":[],"wait":true}"#, auth: token)
    try await Task.sleep(nanoseconds: 200_000_000)
    hub.links[0].send(#"{"t":"prompt","req":"r1","deliver":"followUp","files":[]}"#)
    let (_, polled) = try await poll
    let frame = polled["frames"]!.array!.first!
    XCTAssertEqual(polled["frames"]!.array!.count, 1)
    XCTAssertEqual(frame["t"], "prompt")
    XCTAssertEqual(frame["deliver"], "followUp")
    _ = try await Self.post(port, #"{"conn":"\#(conn)","frames":[{"t":"reply","req":"r1"}]}"#, auth: token)
    let replied = await apiPumpUntil { hub.frames.count == 2 }
    XCTAssertTrue(replied)
    XCTAssertEqual(JSON.tryParse(hub.frames[1]), ["t": "reply", "req": "r1"])
    await api.stop()
  }

  @MainActor
  func testAWaitEndsAfterTheHoldWithNoFrames() async throws {
    let (api, token) = try await started(hold: 0.2)
    let (_, opened) = try await Self.post(api.port!, #"{"frames":[\#(hello)]}"#, auth: token)
    let (status, polled) = try await Self.post(
      api.port!, #"{"conn":"\#(opened["conn"]!.string!)","frames":[],"wait":true}"#, auth: token)
    XCTAssertEqual(status, 200)
    XCTAssertEqual(polled["frames"], .array([]))
    await api.stop()
  }

  @MainActor
  func testAnUnknownConnectionGets404AndClosingEndsTheSession() async throws {
    let hub = ApiFakeEndpoint()
    let (api, token) = try await started(hub)
    let port = api.port!
    let (status, _) = try await Self.post(port, #"{"conn":"nope","frames":[]}"#, auth: token)
    XCTAssertEqual(status, 404)
    let (_, opened) = try await Self.post(port, #"{"frames":[\#(hello)]}"#, auth: token)
    let conn = opened["conn"]!.string!
    let open = await apiPumpUntil { hub.open == 1 }
    XCTAssertTrue(open)
    _ = try await Self.post(port, #"{"conn":"\#(conn)","frames":[],"close":true}"#, auth: token)
    let closed = await apiPumpUntil { hub.open == 0 }
    XCTAssertTrue(closed)
    let (after, _) = try await Self.post(port, #"{"conn":"\#(conn)","frames":[]}"#, auth: token)
    XCTAssertEqual(after, 404)
    await api.stop()
  }

  @MainActor
  func testAConnectionWithoutRequestsGoesIdle() async throws {
    let hub = ApiFakeEndpoint()
    let (api, token) = try await started(hub, idle: 0.2)
    let (_, opened) = try await Self.post(api.port!, #"{"frames":[\#(hello)]}"#, auth: token)
    let closed = await apiPumpUntil { hub.links.count == 1 && hub.open == 0 }
    XCTAssertTrue(closed)
    let (after, _) = try await Self.post(api.port!, #"{"conn":"\#(opened["conn"]!.string!)","frames":[]}"#, auth: token)
    XCTAssertEqual(after, 404)
    await api.stop()
  }

  @MainActor
  func testAWrongTokenIsRefused() async throws {
    let hub = ApiFakeEndpoint()
    let (api, _) = try await started(hub)
    let (status, body) = try await Self.post(api.port!, #"{"frames":[\#(hello)]}"#, auth: "wrong")
    XCTAssertEqual(status, 403)
    XCTAssertEqual(body["error"], "Bad token.")
    XCTAssertTrue(hub.links.isEmpty)
    await api.stop()
  }

  @MainActor
  private func rawStatus(_ port: Int, _ method: String, _ path: String, auth: String? = nil, body: String? = nil)
    async -> Int?
  {
    await Task.detached {
      guard let s = ApiRawSocket(port: port) else { return nil }
      defer { s.close() }
      var req = "\(method) \(path) HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n"
      if let auth { req += "authorization: Bearer \(auth)\r\n" }
      if path == "/v1/live" {
        req = req.replacingOccurrences(of: "connection: close", with: "connection: Upgrade")
        req += "upgrade: websocket\r\nsec-websocket-version: 13\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
      }
      if let body { req += "content-length: \(body.utf8.count)\r\n\r\n\(body)" } else { req += "\r\n" }
      s.send(Data(req.utf8))
      return s.status()
    }.value
  }

  @MainActor
  func testEveryRouteButTheNoncePingWantsTheTokenAndItListensOnLoopbackOnly() async throws {
    let (api, token) = try await started()
    let port = api.port!
    for (method, path) in [("GET", "/v1/ping"), ("GET", "/v1/nothing"), ("GET", "/v1/live"), ("POST", "/v1/live/http")]
    {
      for auth in [nil, "wrong"] as [String?] {
        let status = await rawStatus(port, method, path, auth: auth, body: method == "GET" ? nil : #"{"title":"x"}"#)
        XCTAssertEqual(status, 403, "\(method) \(path) with \(auth ?? "no") token")
      }
    }
    let ping = await rawStatus(port, "GET", "/v1/ping?nonce=0123456789abcdef")
    XCTAssertEqual(ping, 200)
    let short = await rawStatus(port, "GET", "/v1/ping?nonce=short")
    XCTAssertEqual(short, 400)
    let pid = await rawStatus(port, "GET", "/v1/ping", auth: token)
    XCTAssertEqual(pid, 200)
    // With the token, anything but the live routes and the ping isn't there.
    let nothing = await rawStatus(port, "GET", "/v1/nothing", auth: token)
    XCTAssertEqual(nothing, 404)
    let ideas = await rawStatus(port, "POST", "/v1/ideas", auth: token, body: #"{"title":"x"}"#)
    XCTAssertEqual(ideas, 404)
    let get = await rawStatus(port, "GET", "/v1/live/http", auth: token)
    XCTAssertEqual(get, 405)

    // Nothing listens on this computer's other addresses.
    for a in apiOtherAddresses() {
      let s = await Task.detached { ApiRawSocket(host: a, port: port) }.value
      XCTAssertNil(s, a)
      s?.close()
    }
    await api.stop()
  }

  @MainActor
  func testARequestWhoseBodyNeverComesHoldsUpNobodyElse() async throws {
    let (api, token) = try await started()
    let port = api.port!
    // Headers promise a body that never arrives.
    let stuck = await Task.detached { () -> ApiRawSocket? in
      let s = ApiRawSocket(port: port)
      s?.send(Data(
        ("POST /v1/live/http HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer \(token)\r\n"
          + "content-type: application/json\r\ncontent-length: 1000000\r\n\r\n{\"frames\":").utf8))
      return s
    }.value
    defer { stuck?.close() }
    let (status, _) = try await Self.post(port, #"{"frames":[\#(hello)]}"#, auth: token)
    XCTAssertEqual(status, 200)
    await api.stop()
  }

  @MainActor
  private func sendBig(_ port: Int, _ token: String, sayLength: Bool) async -> Int? {
    let big = Data(
      (#"{"frames":[\#(hello)],"pad":""# + String(repeating: "x", count: LocalApi.maxBody) + #""}"#).utf8)
    return await Task.detached {
      guard let s = ApiRawSocket(port: port) else { return nil }
      defer { s.close() }
      var head = "POST /v1/live/http HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer \(token)\r\n"
      head += sayLength ? "content-length: \(big.count)\r\n\r\n" : "transfer-encoding: chunked\r\n\r\n"
      s.send(Data(head.utf8))
      if sayLength {
        s.send(big)
      } else {
        var off = 0
        while off < big.count {
          let n = min(65536, big.count - off)
          s.send(Data(String(n, radix: 16).utf8) + Data("\r\n".utf8) + big[off..<off + n] + Data("\r\n".utf8))
          off += n
        }
        s.send(Data("0\r\n\r\n".utf8))
      }
      return s.status()
    }.value
  }

  @MainActor
  func testABodyOverTheCapIsRefusedWith413AndOpensNoConnection() async throws {
    let hub = ApiFakeEndpoint()
    let (api, token) = try await started(hub)
    let said = await sendBig(api.port!, token, sayLength: true)
    XCTAssertEqual(said, 413)
    let chunked = await sendBig(api.port!, token, sayLength: false)
    XCTAssertEqual(chunked, 413)
    XCTAssertTrue(hub.links.isEmpty)
    await api.stop()
  }
}
#endif
