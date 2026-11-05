import Foundation
import XCTest

@testable import PocketTermKit

/// Against the real Dart server (POCKETTERM_INTEROP=1): server_client_test.dart and the cross-device round
/// trip every port runs.
@MainActor
final class InteropTests: XCTestCase {
  var own: InteropServer!

  override func setUp() async throws {
    own = try InteropServer.start()
  }

  override func tearDown() async throws {
    own?.stop()
  }

  func until(_ seconds: TimeInterval = 10, _ check: @escaping () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !check() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    let ok = check()
    XCTAssertTrue(ok)
  }

  /// Setup link → computer; pairing code → phone; both on the computer's topic, sealed frames both ways; a
  /// sealed blob up and down; sign-out ends the phone's channel with 4003.
  func testComputerAndPhoneRoundTrip() async throws {
    let health = await own.backend.check()
    XCTAssertNil(health)
    let desktop = try await own.desktop()
    XCTAssertEqual(desktop.account?.device.role, .desktop)
    let phone = try await own.phone(desktop)
    XCTAssertEqual(phone.account?.device.role, .phone)
    XCTAssertEqual(phone.account?.id, desktop.account?.id, "the same server")

    let id = "abcd1234"
    try await desktop.putDesktop(id, name: "MacBook Pro", platform: "macos")
    let listed = try await phone.desktops()
    XCTAssertEqual(listed.compactMap { Desktop(json: $0) }.map(\.id), [id])

    let key = ChannelKey.generate()
    var onDesktop: [(String, JSONObject)] = []
    var onPhone: [(String, JSONObject)] = []
    let mac = TerminalChannel(
      desktop, id, ["hello": { onDesktop.append(("hello", $0)) }, "run": { onDesktop.append(("run", $0)) }], key: key,
      name: "mac")
    let iphone = TerminalChannel(
      phone, id, ["state": { onPhone.append(("state", $0)) }, "ran": { onPhone.append(("ran", $0)) }], key: key,
      name: "phone")
    mac.open()
    iphone.open()
    await until { mac.joined && iphone.joined }

    try iphone.send("hello", ["from": "p1"])
    try iphone.send("run", ["id": "r1", "op": "send", "text": "ls"])
    await until { onDesktop.count == 2 }
    XCTAssertEqual(onDesktop.map(\.0), ["hello", "run"])
    XCTAssertEqual(onDesktop[1].1, ["id": "r1", "op": "send", "text": "ls"])

    try mac.send("state", ["windows": [], "sessions": [], "home": "/Users/me"])
    try mac.send("ran", ["id": "r1"])
    await until { onPhone.count == 2 }
    XCTAssertEqual(onPhone.map(\.0), ["state", "ran"])
    XCTAssertEqual(onPhone[0].1["home"], "/Users/me")

    // A sealed image up from the phone, down on the computer, gone after.
    let path = phone.newBlobPath()
    XCTAssertTrue(Servers.isBlobPath(path))
    let image = Data((0..<4096).map { UInt8($0 % 251) })
    try await phone.putBlob(path, sealBytes(key, image, imageAad(path)))
    let got = try await desktop.getBlob(path)
    XCTAssertEqual(openBytes(key, got, imageAad(path)), image)
    do {
      _ = try await desktop.getBlob(path)
      XCTFail("a blob comes down once")
    } catch let e as ServerException {
      XCTAssertEqual(e.status, 404)
    }

    // The computer signs the phone out: its live channel closes with 4003 and its sign-in ends.
    var ended = false
    let endedTask = Task { @MainActor in
      for await _ in phone.ended {
        ended = true
        break
      }
    }
    try await desktop.revokeDevice(phone.account!.device.id)
    await until { ended }
    XCTAssertNil(phone.account)
    XCTAssertFalse(iphone.joined)
    endedTask.cancel()

    // The computer leaves too: its token works no more.
    try await desktop.leave()
    XCTAssertNil(desktop.account)
    mac.close()
    iphone.close()
  }

  func testCodesWorkOnceAndWrongOnesSignNobodyIn() async throws {
    let desktop = try await own.desktop()
    let code = try await desktop.createPairingCode()
    let a = PocketTermServerClient(own.backend, tokens: MemoryDeviceTokens())
    _ = try await a.redeemCode(code, label: "iPhone", platform: "ios")
    let b = PocketTermServerClient(own.backend, tokens: MemoryDeviceTokens())
    do {
      _ = try await b.redeemCode(code, label: "iPad", platform: "ios")
      XCTFail("a code works once")
    } catch let e as ServerException {
      XCTAssertEqual(e.code, "invalid_code")
    }
    do {
      _ = try await b.redeemSetup("wrong", label: "Mac", platform: "macos")
      XCTFail("a wrong setup token")
    } catch let e as ServerException {
      XCTAssertEqual(e.code, "invalid_code")
    }
    XCTAssertNil(b.account)
  }

  func testOverTheLimitIsRefusedWithItsReason() async throws {
    let desktop = try await own.desktop()
    do {
      try await desktop.putBlob(desktop.newBlobPath(), Data(count: Servers.maxBlobBytes + 1))
      XCTFail("taken")
    } catch let e as ServerException {
      XCTAssertEqual(e.status, 413)
      XCTAssertTrue(e.message.contains("20 MB"))
    }
  }

  func testDevicesLeaveRevokeErase() async throws {
    let desktop = try await own.desktop()
    let phone = try await own.phone(desktop)
    let devices = try await desktop.devices()
    XCTAssertEqual(devices.map(\.role), [.desktop, .phone])
    XCTAssertEqual(devices.filter(\.current).map(\.role), [.desktop])

    try await phone.leave()
    XCTAssertNil(phone.account)
    let after = try await desktop.devices()
    XCTAssertEqual(after.count, 1)

    let tokens = MemoryDeviceTokens()
    let kept = PocketTermServerClient(own.backend, tokens: tokens)
    _ = try await kept.redeemCode(try await desktop.createPairingCode(), label: "iPad", platform: "ios")
    XCTAssertNotNil(tokens.value)
    let relaunched = PocketTermServerClient(own.backend, tokens: tokens)
    await relaunched.load()
    XCTAssertEqual(relaunched.account?.device.label, "iPad")

    try await desktop.erase()
    XCTAssertNil(desktop.account)
    await relaunched.recheck()
    XCTAssertNil(relaunched.account, "erased: every sign-in ends")
    XCTAssertNil(tokens.value)
    // Its setup link still works.
    _ = try await own.desktop("Mac mini")
  }
}

/// A computer, or with [phone] a phone, keeping its sign-in in [tokens] and the computer keys from links.
@MainActor
class TestSession: Session {
  init(_ device: String, phone: Bool = false, atOnce: Bool = false, tokens: DeviceTokens = MemoryDeviceTokens()) {
    self.phone = phone
    self.atOnce = atOnce
    super.init(device: device, deviceTokens: tokens, backendStore: PreferencesBackendStore(MemoryPreferenceStore()))
  }
  let phone: Bool
  let atOnce: Bool
  var keys: [ComputerKey] = []
  var computer: ComputerKey?
  var told: [String] = []
  var connected: [URL] = []
  var scans: [Bool] = []
  var recordLinksOnly = false

  override var role: DeviceRole { phone ? .phone : .desktop }
  override var platform: String { phone ? "ios" : "macos" }
  override var signInAtOnce: Bool { atOnce }
  override var hostsServer: Bool { !phone }
  override func addComputerKey(_ computer: ComputerKey) async { keys.append(computer) }
  override func computerKey(_ desktopId: String) -> ChannelKey? { keys.last { $0.desktop == desktopId }?.key }
  override func pairingComputer() async -> ComputerKey? { computer }
  override func onNotice(_ message: String) { told.append(message) }
  override func connectLink(_ uri: URL, scanned: Bool = false) async {
    if recordLinksOnly {
      connected.append(uri)
      scans.append(scanned)
      return
    }
    await super.connectLink(uri, scanned: scanned)
  }
}

/// A Keychain that refuses until [locked] is turned off, as a locked or missing one does.
final class LockedKeychain: DeviceTokens, @unchecked Sendable {
  let inner = MemoryDeviceTokens()
  private let state = Locked(true)
  var locked: Bool {
    get { state.get }
    set { state.with { $0 = newValue } }
  }
  func read() async throws -> String? { try await inner.read() }
  func write(_ value: String?) async throws {
    if locked { throw SecureStoreError(status: -25308, message: "locked") }
    try await inner.write(value)
  }
}

/// session_test.dart: links and their confirmation, without a server.
@MainActor
final class SessionLinkTests: XCTestCase {
  let mine = Backend(url: "https://mine.example.com")
  let theirs = Backend(url: "https://theirs.example.com")

  func linkSession() -> TestSession {
    let s = TestSession("iPhone", phone: true)
    s.recordLinksOnly = true
    return s
  }

  func settle() async { for _ in 0..<20 { await Task.yield() } }

  func testAnotherServersLinkWaitsForThePerson() async {
    let s = linkSession()
    let link = theirs.linkWithCode("ABCD-1234")
    s.openedLink(link, saved: mine)
    await settle()
    XCTAssertTrue(s.connected.isEmpty)
    XCTAssertEqual(s.linkToConfirm, link)
    await s.answerLink(connect: true)
    XCTAssertEqual(s.connected, [link])
    XCTAssertNil(s.linkToConfirm)
  }

  func testNoDropsItAndANewDeviceAsks() async {
    let s = linkSession()
    s.openedLink(theirs.linkWithCode("ABCD-1234"), saved: nil)
    XCTAssertNotNil(s.linkToConfirm)
    await s.answerLink(connect: false)
    XCTAssertTrue(s.connected.isEmpty)
    XCTAssertNil(s.linkToConfirm)
  }

  func testOwnServerGoesAheadNeverAsAScan() async {
    let s = linkSession()
    let link = mine.linkWithCode("ABCD-1234")
    s.openedLink(link, saved: mine)
    await settle()
    XCTAssertEqual(s.connected, [link])
    XCTAssertEqual(s.scans, [false])
    XCTAssertNil(s.linkToConfirm)
  }

  func testOtherLinksGoElsewhere() {
    final class Other: TestSession {
      var other: [URL] = []
      override func onOtherLink(_ uri: URL) { other.append(uri) }
    }
    let s = Other("iPhone", phone: true)
    s.openedLink(URL(string: "pocketterm://session?key=abcd1234/kitty-1/1")!, saved: nil)
    XCTAssertEqual(s.other.count, 1)
  }
}

/// session_test.dart against the real server.
@MainActor
final class SessionInteropTests: XCTestCase {
  var own: InteropServer!
  var mac: TestSession!

  override func setUp() async throws {
    own = try InteropServer.start()
    mac = TestSession("MacBook Pro")
    mac.computer = ComputerKey(desktop: "abcd1234", key: ChannelKey.generate())
    await mac.connectLink(try own.setupLink())
  }

  override func tearDown() async throws {
    await mac?.disconnect()
    own?.stop()
  }

  func testComputerAndPhoneSignIn() async throws {
    XCTAssertNil(mac.authError)
    XCTAssertEqual(mac.user?.device.role, .desktop)
    XCTAssertEqual(mac.user?.device.label, "MacBook Pro")

    let phone = TestSession("iPhone", phone: true)
    await phone.connectLink(try await mac.pairingLink(), scanned: true)
    XCTAssertNil(phone.authError)
    XCTAssertEqual(phone.user?.device.role, .phone)
    XCTAssertEqual(phone.user?.id, mac.user?.id)
    XCTAssertEqual(phone.keys, [mac.computer!])

    let link = try await mac.pairingLink()
    let second = TestSession("iPad", phone: true)
    await second.connectLink(link)
    XCTAssertNotNil(second.user)
    let third = TestSession("Pixel", phone: true)
    await third.connectLink(link)
    XCTAssertNil(third.user)
    XCTAssertTrue(third.authError?.contains("used") == true)
    for s in [phone, second, third] { await s.disconnect() }
  }

  func testLockedKeychainAndTryAgain() async throws {
    let keychain = LockedKeychain()
    let other = TestSession("Mac mini", tokens: keychain)
    let link = try own.setupLink()
    await other.connectLink(link)
    XCTAssertNil(other.user)
    XCTAssertEqual(other.authError, Session.keychainProblem)
    XCTAssertEqual(other.retryLink, link)
    keychain.locked = false
    await other.retry()
    XCTAssertNil(other.authError)
    XCTAssertEqual(other.user?.device.label, "Mac mini")
    XCTAssertNil(other.retryLink)
    await other.disconnect()
  }

  func testLinkNotFromTheScannerNeverGivesAKey() async throws {
    let phone = TestSession("iPhone", phone: true)
    await phone.connectLink(try await mac.pairingLink())
    XCTAssertNotNil(phone.user)
    XCTAssertTrue(phone.keys.isEmpty)

    let planted = ComputerKey(desktop: "zzzz9999", key: ChannelKey.generate())
    let link = mac.backend!.linkWithCode("ABCD-1234", computer: planted)
    await phone.connectLink(link)
    XCTAssertTrue(phone.keys.isEmpty)
    XCTAssertEqual(phone.told.count, 1)
    XCTAssertTrue(phone.told[0].contains("scanner"))
    XCTAssertNil(phone.authError)
    await phone.connectLink(link, scanned: true)
    XCTAssertEqual(phone.keys, [planted])
    await phone.disconnect()
  }

  func testLinkWithoutWhatThisDeviceSignsInWith() async throws {
    let phone = TestSession("iPhone", phone: true)
    await phone.connectLink(try own.setupLink())
    XCTAssertNil(phone.user)
    XCTAssertTrue(phone.authError?.contains("no sign-in code") == true)

    let other = TestSession("Mac mini")
    await other.connectLink(own.backend.linkWithCode(try await mac.server!.createPairingCode()))
    XCTAssertNil(other.user)
    XCTAssertTrue(other.authError?.contains("no setup token") == true)
  }

  func testRelaunchAndSignOut() async throws {
    let tokens = MemoryDeviceTokens()
    let phone = TestSession("iPhone", phone: true, tokens: tokens)
    await phone.connectLink(try await mac.pairingLink())
    let id = phone.user!.device.id

    let relaunched = TestSession("iPhone", phone: true, tokens: tokens)
    await relaunched.connect(own.backend)
    XCTAssertEqual(relaunched.user?.device.id, id)
    await relaunched.signOut()
    XCTAssertNil(relaunched.user)
    XCTAssertEqual(relaunched.signedOutReason, "You signed out.")
    XCTAssertNil(tokens.value)
    let ids = try await mac.server!.devices().map(\.id)
    XCTAssertFalse(ids.contains(id))
  }

  func testSignedOutByTheComputerHearsIt() async throws {
    let tokens = MemoryDeviceTokens()
    let phone = TestSession("iPhone", phone: true, tokens: tokens)
    await phone.connectLink(try await mac.pairingLink())
    let kept = tokens.value
    try await mac.server!.revokeDevice(phone.user!.device.id)
    do {
      _ = try await phone.server!.desktops()
      XCTFail("listed")
    } catch is ServerException {}
    for _ in 0..<50 where phone.user != nil { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertNil(phone.user)
    XCTAssertTrue(phone.signedOutReason?.contains("Scan a new code") == true)

    let again = TestSession("iPhone", phone: true, tokens: MemoryDeviceTokens(kept))
    await again.connect(own.backend)
    XCTAssertNil(again.user)
  }

  func testAnotherServersComputerKeepsThePhoneWhereItIs() async throws {
    let phone = TestSession("iPhone", phone: true)
    await phone.connectLink(try await mac.pairingLink(), scanned: true)
    let before = phone.user
    let elsewhere = Backend(url: "https://other.example.com")
    await phone.connectLink(
      elsewhere.linkWithCode("ABCD-1234", computer: ComputerKey(desktop: "zzzz9999", key: ChannelKey.generate())),
      scanned: true)
    XCTAssertEqual(phone.user, before)
    XCTAssertEqual(phone.backend, own.backend)
    XCTAssertEqual(phone.keys, [mac.computer!])
    XCTAssertEqual(phone.told.count, 1)
    XCTAssertTrue(phone.told[0].contains("other.example.com") && phone.told[0].contains("Leave this server"))
    await phone.signOut()
    XCTAssertNil(phone.authError)
  }

  func testScannedCodeCantSwapAKeyUnlessItsCodeWorks() async throws {
    let phone = TestSession("iPhone", phone: true)
    await phone.connectLink(try await mac.pairingLink(), scanned: true)
    let devices = try await mac.server!.devices().count

    let planted = ComputerKey(desktop: mac.computer!.desktop, key: ChannelKey.generate())
    await phone.connectLink(
      mac.backend!.linkWithCode("ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345", computer: planted), scanned: true)
    XCTAssertEqual(phone.computerKey(planted.desktop), mac.computer!.key, "the key it held stays")
    XCTAssertTrue(phone.told.first?.contains("doesn't work") == true)

    mac.computer = ComputerKey(desktop: mac.computer!.desktop, key: ChannelKey.generate())
    await phone.connectLink(try await mac.pairingLink(), scanned: true)
    XCTAssertEqual(phone.computerKey(planted.desktop), mac.computer!.key)
    XCTAssertEqual(phone.told.count, 1)
    XCTAssertNotNil(phone.user)
    let now = try await mac.server!.devices().count
    XCTAssertEqual(now, devices, "the sign-in that tried the code left")
    await phone.disconnect()
  }

  func testEraseLeavesNoProblemBehind() async throws {
    mac.authError = "Sign out before switching to other.example.com."
    try await mac.eraseServer()
    XCTAssertNil(mac.user)
    XCTAssertNil(mac.authError)
    XCTAssertEqual(mac.signedOutReason, "This server's data was erased.")
  }

  func testSignOutOfflineStillForgets() async throws {
    let tokens = MemoryDeviceTokens()
    let phone = TestSession("iPhone", phone: true, tokens: tokens)
    await phone.connectLink(try await mac.pairingLink())
    own.stop()
    await phone.signOut()
    XCTAssertNil(phone.user)
    XCTAssertNil(tokens.value)
    XCTAssertEqual(phone.signedOutReason, "You signed out.")
  }
}

/// session_test.dart's "a phone launched with the sign-in it kept", against a server that holds GET /v1/me.
@MainActor
final class SessionHeldTests: XCTestCase {
  var server: TestHTTPServer!
  let answer = Locked<(Int, String)?>(nil)
  let asked = Locked(0)
  var kept: MemoryDeviceTokens!
  var backend: Backend!

  static let me = #"{"device":{"id":"dev0000000000001","role":"phone","label":"iPhone","platform":"ios"},"server":{"id":"srv0000000000001"}}"#

  override func setUp() async throws {
    let answer = answer
    let asked = asked
    server = try TestHTTPServer { req in
      guard req.path == "/v1/me" else { return .http(status: 200, body: "{}") }
      asked.with { $0 += 1 }
      // Held until the test says what to answer.
      while answer.get == nil { usleep(10_000) }
      let (status, body) = answer.get!
      return .http(status: status, body: body)
    }
    backend = Backend(url: server.url)
    kept = MemoryDeviceTokens(
      JSON.object([
        "url": .string(backend.url), "token": "token-1", "server": "srv0000000000001",
        "device": ["id": "dev0000000000001", "role": "phone", "label": "iPhone", "platform": "ios"],
      ]).encoded())
  }

  override func tearDown() async throws {
    answer.with { $0 = (200, "{}") }
    server.stop()
  }

  func respond(_ status: Int, _ body: String) async throws {
    for _ in 0..<200 where asked.get == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    answer.with { $0 = (status, body) }
    try await Task.sleep(nanoseconds: 300_000_000)
  }

  func testSignedInBeforeTheServerAnswersAndStaysOnANonAnswer() async throws {
    let phone = TestSession("iPhone", phone: true, atOnce: true, tokens: kept)
    await phone.connect(backend)
    XCTAssertEqual(phone.user?.device.id, "dev0000000000001")
    try await respond(200, "<html>Sign in to the Wi-Fi</html>")
    XCTAssertNotNil(phone.user)
    XCTAssertNotNil(kept.value)
  }

  func testSignedOutOnceTheServerRefuses() async throws {
    let phone = TestSession("iPhone", phone: true, atOnce: true, tokens: kept)
    await phone.connect(backend)
    XCTAssertNotNil(phone.user)
    try await respond(401, #"{"error":"unauthorized","message":"Sign in again."}"#)
    XCTAssertNil(phone.user)
    XCTAssertTrue(phone.signedOutReason?.contains("Scan a new code") == true)
    XCTAssertNil(kept.value)
  }

  func testAnAnswerAfterSignOutDoesntSignBackIn() async throws {
    let phone = TestSession("iPhone", phone: true, atOnce: true, tokens: kept)
    await phone.connect(backend)
    await phone.signOut()
    try await respond(200, Self.me)
    XCTAssertNil(phone.user)
    XCTAssertNil(kept.value, "the sign-in it left isn't kept again")
    XCTAssertNil(phone.server!.account)
  }
}
