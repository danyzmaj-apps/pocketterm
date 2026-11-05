#if os(macOS)
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

/// hosting_test.dart's 'This computer': the controller running the built-in server, the real one (the sidecar
/// tool/server-sidecar.sh builds, named by POCKETTERM_SIDECAR).
final class ThisComputerTests: XCTestCase {
  @MainActor private var fake: HostFakeTailscale!
  @MainActor private var dir: URL!
  @MainActor private var apps: [TestApp] = []

  @MainActor
  override func setUp() async throws {
    guard let path = ProcessInfo.processInfo.environment["POCKETTERM_SIDECAR"], !path.isEmpty else {
      throw XCTSkip("POCKETTERM_SIDECAR isn't set (tool/server-sidecar.sh builds it)")
    }
    sidecar = URL(fileURLWithPath: path)
    fake = HostFakeTailscale(installed: true)
    dir = hostTempDir(self).appendingPathComponent("pocketterm-server")
  }

  @MainActor private var sidecar: URL!

  @MainActor
  override func tearDown() async throws {
    for a in apps { await a.hosting?.stop() }
    apps = []
  }

  @MainActor
  private func app(prefs: PreferenceStore = MemoryPreferenceStore(), secrets: ControllerSecrets = ControllerSecrets())
    -> TestApp
  {
    let a = TestApp(
      prefs: prefs, secrets: secrets, tailscale: fake.tailscale, serverDir: dir, sidecar: sidecar, real: true)
    apps.append(a)
    return a
  }

  @MainActor
  func testStartingTheServerSignsThisComputerInToItOn127() async throws {
    let a = app()
    try await a.startHosting()
    XCTAssertNotNil(a.user)
    XCTAssertEqual(a.user?.device.role, .desktop)
    XCTAssertTrue(a.hostsServer)
    XCTAssertEqual(a.backend, a.hosting!.backend)
    XCTAssertEqual(URL(string: a.backend!.url)?.host, "127.0.0.1")
  }

  @MainActor
  func testAStartWhoseSignInTheKeychainRefusesTakesItAllBackAlsoForTheNextLaunch() async throws {
    let keychain = ControllerSecrets()
    keychain.locked = true
    let prefs = MemoryPreferenceStore()
    let a = app(prefs: prefs, secrets: keychain)
    try await a.startHosting()
    XCTAssertNil(a.user)
    XCTAssertEqual(a.authError, Session.keychainProblem)
    XCTAssertNil(a.hosting)
    XCTAssertFalse(a.hostsServer)
    XCTAssertNil(a.backend)
    XCTAssertFalse(prefs.bool("hosting") ?? false)
    let port = try XCTUnwrap(prefs.int("hosting_port"))
    XCTAssertFalse(hostListening(port))

    // Launched again, it waits for a choice: no server of its own starts.
    let again = app(prefs: prefs, secrets: keychain)
    await again.start()
    XCTAssertNil(again.hosting)
    XCTAssertNil(again.backend)

    // Unlocked, Start works.
    keychain.locked = false
    try await again.startHosting()
    XCTAssertNotNil(again.user)
    XCTAssertEqual(prefs.bool("hosting"), true)
  }

  @MainActor
  func testAPhonesCodeCarriesTheTsNetAddressAndItsCodeSignsAPhoneIn() async throws {
    let a = app()
    try await a.startHosting()
    await a.hosting!.refresh()
    let link = try await a.pairingLink()
    XCTAssertEqual(Backend.fromLink(link)?.url, "https://mac.tail1234.ts.net")
    XCTAssertEqual(Backend.computerKey(link)?.desktop, a.desktopId(a.user!.id))
    // The phone reaches it through Tailscale; here, on 127.0.0.1.
    let phone = PocketTermServerClient(a.backend!, tokens: MemoryDeviceTokens())
    defer { phone.close() }
    let account = try await phone.redeemCode(Backend.pairingCode(link)!, label: "iPhone", platform: "ios")
    XCTAssertEqual(account.id, a.user!.id)
    let roles = try await a.serverDevices().map(\.role)
    XCTAssertEqual(Set(roles), [.desktop, .phone])
    XCTAssertEqual(roles.count, 2)
  }

  @MainActor
  func testUntilTailscaleServesItTheresNoPhoneCodeToShow() async throws {
    fake.https = false
    let a = app()
    try await a.startHosting()
    await a.hosting!.refresh()
    XCTAssertEqual(a.hosting!.state, .httpsOff)
    do {
      _ = try await a.pairingLink()
      XCTFail("no code without Tailscale serving")
    } catch is PairingException {}
  }

  @MainActor
  func testAddAComputerItsLinkSignsAnotherComputerInToThisServer() async throws {
    let a = app()
    try await a.startHosting()
    await a.hosting!.refresh()
    let made = await a.computerSetupLink()
    let link = try XCTUnwrap(made)
    XCTAssertEqual(Backend.fromLink(link)?.url, "https://mac.tail1234.ts.net")
    let other = PocketTermServerClient(a.backend!, tokens: MemoryDeviceTokens())
    defer { other.close() }
    let account = try await other.redeemSetup(Backend.setupToken(link)!, label: "Mac mini", platform: "macos")
    XCTAssertEqual(account.id, a.user!.id)
    XCTAssertEqual(account.device.role, .desktop)
  }

  @MainActor
  func testAtLaunchItStartsAgainAndSignsInByItselfAlsoWhenItsPortWasTaken() async throws {
    let prefs = MemoryPreferenceStore()
    let secrets = ControllerSecrets()
    let first = app(prefs: prefs, secrets: secrets)
    try await first.startHosting()
    let port = first.hosting!.port
    XCTAssertTrue(prefs.contains("hosting"))
    XCTAssertTrue(prefs.contains("hosting_port"))
    let firstUser = first.user!.id
    await first.hosting!.stop()

    let taken = try occupy(port)
    defer { close(taken) }
    // Without Terminal from phone: no bridge to the terminals here.
    prefs.remove("terminal_bridge")
    let again = app(prefs: prefs, secrets: secrets)
    await again.start()
    XCTAssertNotEqual(again.hosting?.port, port)
    XCTAssertNotNil(again.user)
    XCTAssertEqual(again.user?.id, firstUser)
  }

  @MainActor
  func testSigningOutStopsTheServerTakesItOffTheTailnetAndShowsTheSetupAgain() async throws {
    let prefs = MemoryPreferenceStore()
    let a = app(prefs: prefs)
    try await a.startHosting()
    await a.hosting!.refresh()
    let port = a.hosting!.port
    await a.signOut()
    XCTAssertNil(a.hosting)
    XCTAssertNil(a.backend)
    XCTAssertNil(a.user)
    XCTAssertTrue(fake.calls.contains("serve --https=443 off"))
    XCTAssertFalse(hostListening(port))
    XCTAssertEqual(prefs.bool("hosting"), false)
  }

  @MainActor
  func testAComputerThatRunsTheServerStartsItAtLaunchQuittingTakesItOffTheTailnet() async throws {
    let prefs = MemoryPreferenceStore()
    prefs.setBool("hosting", true)
    let a = app(prefs: prefs)
    await a.start()
    XCTAssertNotNil(a.user)
    await a.hosting!.refresh()
    XCTAssertEqual(a.hosting!.state, .ready)
    let port = a.hosting!.port
    await a.fakeHost.onEvent!("quitting")
    XCTAssertEqual(fake.calls.last, "serve --https=443 off")
    XCTAssertFalse(hostListening(port))
  }

  @MainActor
  func testErasingSignsEveryPhoneOutAndThisComputerBackIn() async throws {
    let a = app()
    try await a.startHosting()
    await a.hosting!.refresh()
    let phone = PocketTermServerClient(a.backend!, tokens: MemoryDeviceTokens())
    defer { phone.close() }
    let link = try await a.pairingLink()
    _ = try await phone.redeemCode(Backend.pairingCode(link)!, label: "iPhone", platform: "ios")
    let before = a.user!.device.id

    try await a.eraseServer()
    XCTAssertNotNil(a.user)
    XCTAssertNotEqual(a.user?.device.id, before)
    do {
      _ = try await phone.devices()
      XCTFail("the phone's sign-in should be gone")
    } catch let e as ServerException {
      XCTAssertEqual(e.status, 401)
    }
    let devices = try await a.serverDevices()
    XCTAssertEqual(devices.map(\.role), [.desktop])
  }
}

/// A socket listening on 127.0.0.1:`port`, as Dart's ServerSocket.bind takes one: with SO_REUSEADDR, so the port
/// the server just left (its connections in TIME_WAIT) can be taken at once.
private func occupy(_ port: Int) throws -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var on: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = in_port_t(UInt16(port).bigEndian)
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard bound == 0, listen(fd, 4) == 0 else {
    close(fd)
    throw XCTSkip("port \(port) couldn't be taken for the test")
  }
  return fd
}
#endif
