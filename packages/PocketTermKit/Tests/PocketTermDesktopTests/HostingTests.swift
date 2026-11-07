#if os(macOS)
import Darwin
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

final class TailscaleHostingTests: XCTestCase {
  func testFoundInTheMacAppFirstThenOnThePathOrInHomebrew() {
    func only(_ files: Set<String>) -> (String) -> Bool { { files.contains($0) } }
    XCTAssertEqual(
      Tailscale.findCli(env: ["PATH": "/usr/bin"], hooks: [:], exists: only([Tailscale.macCli, "/usr/bin/tailscale"])),
      Tailscale.macCli)
    XCTAssertEqual(
      Tailscale.findCli(env: ["PATH": "/usr/bin:/bin"], hooks: [:], exists: only(["/bin/tailscale"])),
      "/bin/tailscale")
    XCTAssertEqual(
      Tailscale.findCli(env: ["PATH": "/usr/bin"], hooks: [:], exists: only(["/opt/homebrew/bin/tailscale"])),
      "/opt/homebrew/bin/tailscale")
    XCTAssertNil(Tailscale.findCli(env: ["PATH": "/usr/bin"], hooks: [:], exists: { _ in false }))
    // A smoke run's stand-in, before the real app's, in a build for tool/smoke.
    XCTAssertEqual(
      Tailscale.findCli(hooks: ["POCKETTERM_TAILSCALE": "/tmp/fake-tailscale"], exists: { $0 == Tailscale.macCli }),
      "/tmp/fake-tailscale")
  }

  func testABuildNotMadeForSmokeIgnoresPocketTermTailscale() throws {
    try XCTSkipIf(testBuild, "a test build reads the hooks")
    XCTAssertEqual(
      Tailscale.findCli(env: ["POCKETTERM_TAILSCALE": "/tmp/fake-tailscale"], exists: { $0 == Tailscale.macCli }),
      Tailscale.macCli)
  }

  @MainActor
  func testNotInstalledServiceNotRunningSignedOutRunning() async {
    let fake = HostFakeTailscale()
    var s = await fake.tailscale.status()
    XCTAssertEqual(s.state, .missing)
    XCTAssertEqual(fake.calls, [])

    fake.installed = true
    fake.daemon = false
    s = await fake.tailscale.status()
    XCTAssertEqual(s.state, .stopped)

    fake.daemon = true
    fake.backendState = "NeedsLogin"
    s = await fake.tailscale.status()
    XCTAssertEqual(s.state, .loggedOut)

    fake.backendState = "Stopped"
    s = await fake.tailscale.status()
    XCTAssertEqual(s.state, .stopped)

    fake.backendState = "Running"
    let running = await fake.tailscale.status()
    XCTAssertEqual(running.state, .running)
    XCTAssertEqual(running.dnsName, "mac.tail1234.ts.net")
    XCTAssertEqual(running.url, URL(string: "https://mac.tail1234.ts.net"))
    XCTAssertTrue(running.https)

    fake.https = false
    s = await fake.tailscale.status()
    XCTAssertFalse(s.https)
  }

  @MainActor
  func testServeWithHttpsOffAnswersWithTheEnableLinkWithoutWaitingOnTheCli() async {
    let fake = HostFakeTailscale(installed: true, https: false)
    let started = Date()
    let result = await fake.tailscale.serve(47900)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertFalse(result.isOk)
    XCTAssertEqual(result.enableLink, URL(string: HostFakeTailscale.enableLink))
    XCTAssertEqual(fake.running.count, 1)
    XCTAssertTrue(fake.running[0].killed)
  }

  @MainActor
  func testServePublishesLoopbackAtThePortOnHttps443InTheBackground() async {
    let fake = HostFakeTailscale(installed: true)
    let ok = await fake.tailscale.serve(47901).isOk
    XCTAssertTrue(ok)
    XCTAssertEqual(fake.calls, ["serve status --json", "serve --bg --https=443 http://127.0.0.1:47901"])
    await fake.tailscale.unserve(47901)
    XCTAssertEqual(fake.calls.last, "serve --https=443 off")
  }

  func testWhatElseServePublishesOn443IsToldApartFromTheBuiltInServer() {
    func at(_ config: JSON, ours: Set<Int> = [47900]) -> String? {
      Tailscale.servedElsewhere(config.encoded(), ours)
    }
    func web(_ handlers: JSON) -> JSON {
      ["TCP": ["443": ["HTTPS": true]], "Web": ["mac.tail1234.ts.net:443": ["Handlers": handlers]]]
    }
    XCTAssertNil(at([:]))
    XCTAssertNil(Tailscale.servedElsewhere("not json", [47900]))
    // This app's, from this run or the one before, whose port moved.
    XCTAssertNil(at(web(["/": ["Proxy": "http://127.0.0.1:47900"]])))
    XCTAssertNil(at(web(["/": ["Proxy": "http://127.0.0.1:47900"]]), ours: [47901, 47900]))
    // Another PocketTerm's on this Mac (another user, another copy), though on a port of the same range.
    XCTAssertEqual(at(web(["/": ["Proxy": "http://127.0.0.1:47900"]]), ours: [47901]), "http://127.0.0.1:47900")
    XCTAssertEqual(at(web(["/": ["Proxy": "http://127.0.0.1:47900"]]), ours: []), "http://127.0.0.1:47900")
    XCTAssertEqual(at(web(["/": ["Proxy": "http://127.0.0.1:3000"]])), "http://127.0.0.1:3000")
    XCTAssertEqual(
      at(web(["/": ["Proxy": "http://127.0.0.1:47900"], "/grafana": ["Proxy": "http://127.0.0.1:3000"]])),
      "http://127.0.0.1:3000 at /grafana")
    XCTAssertEqual(at(["TCP": ["443": ["TCPForward": "127.0.0.1:22"]]]), "a TCP forward to 127.0.0.1:22")
    // Another port of the tailnet name is no business of this one.
    XCTAssertNil(
      at(["Web": ["mac.tail1234.ts.net:8443": ["Handlers": ["/": ["Proxy": "http://127.0.0.1:3000"]]]]]))
    // A `tailscale serve` running in a terminal (not --bg).
    XCTAssertEqual(at(["Foreground": ["session1": web(["/": ["Path": "/Users/me/site"]])]]), "/Users/me/site")
  }

  @MainActor
  func testServeLeavesWhatElseServePublishesOn443AloneAndSoDoesUnserve() async {
    let fake = HostFakeTailscale(installed: true)
    fake.serving("http://127.0.0.1:3000")
    let result = await fake.tailscale.serve(47900)
    XCTAssertFalse(result.isOk)
    XCTAssertEqual(result.taken, "http://127.0.0.1:3000")
    XCTAssertEqual(fake.calls.filter { $0.hasPrefix("serve --") }, [])

    await fake.tailscale.unserve(47900)
    XCTAssertFalse(fake.calls.contains("serve --https=443 off"))
  }

  @MainActor
  func testWhileServeStatusCantSayServeAndUnserveChangeNothing() async {
    let fake = HostFakeTailscale(installed: true)
    fake.serving("http://127.0.0.1:3000")
    fake.statusFails = true
    var serving = await fake.tailscale.port443([47900])
    XCTAssertEqual(serving, .unknown)
    let result = await fake.tailscale.serve(47900)
    XCTAssertFalse(result.isOk)
    XCTAssertEqual(result.error, Tailscale.unreadable)
    await fake.tailscale.unserve(47900)
    XCTAssertEqual(fake.calls.filter { $0.hasPrefix("serve --") }, [])
    XCTAssertTrue(JSON.object(fake.serveConfig).encoded().contains("http://127.0.0.1:3000"))

    // Readable again: nothing there, this app's own, or something else.
    fake.statusFails = false
    fake.serveConfig = [:]
    serving = await fake.tailscale.port443([47900])
    XCTAssertEqual(serving, .nothing)
    fake.serving("http://127.0.0.1:47900")
    serving = await fake.tailscale.port443([47900])
    XCTAssertEqual(serving, .ours)
    serving = await fake.tailscale.port443([47901])
    XCTAssertEqual(serving, .elsewhere("http://127.0.0.1:47900"))
    XCTAssertEqual(Tailscale.readServing("not json", [47900]), .unknown)
  }

  func testTheOpenSourceBuildsOperatorRuleSaysHowToLetPocketTermIn() {
    XCTAssertTrue(
      Tailscale.serveError("Access denied: serve config denied\nUse sudo or set operator\n").contains("--operator"))
    XCTAssertEqual(Tailscale.serveError("first\nsomething broke\n\n"), "something broke")
  }

  @MainActor
  func testOpenShowsTailscalesApp() async {
    let fake = HostFakeTailscale(installed: true)
    await fake.tailscale.open()
    XCTAssertEqual(fake.calls, ["-a Tailscale"])
  }

  @MainActor
  func testEnableHttpsLinkTakesBackAServeThatWentThrough() async {
    let fake = HostFakeTailscale(installed: true)
    let link = await fake.tailscale.enableHttpsLink()
    XCTAssertEqual(link, Tailscale.adminDns)
    XCTAssertEqual(fake.calls.last, "serve --https=443 off")
    XCTAssertTrue(fake.serveConfig.isEmpty)
  }
}

final class BuiltInServerHostingTests: XCTestCase {
  @MainActor
  private func host(_ fake: HostFakeTailscale, _ dir: URL, sidecar: HostFakeSidecar = HostFakeSidecar()) async throws
    -> BuiltInServer
  {
    let server = BuiltInServer(dataDir: dir, tailscale: fake.tailscale, sidecar: sidecar, recheck: 0, recheckReady: 0)
    addTeardownBlock { await server.stop() }
    try await server.start(port: 0)
    await server.refresh()
    return server
  }

  @MainActor
  private func serves(_ fake: HostFakeTailscale) -> Int {
    fake.calls.filter { $0.hasPrefix("serve --bg") }.count
  }

  @MainActor
  func testWithoutTailscaleItStillRunsOnLoopbackWithNothingToHandOut() async throws {
    let server = try await host(HostFakeTailscale(), hostTempDir(self))
    XCTAssertEqual(server.state, .noTailscale)
    XCTAssertTrue(hostListening(server.port))
    XCTAssertEqual(server.backend.url, "http://127.0.0.1:\(server.port)")
    XCTAssertNil(server.publicUrl)
    let link = try await server.setupLink()
    XCTAssertNil(link)
    let own = try await server.ownSetupLink()
    XCTAssertEqual(Backend.fromLink(own)?.url, server.backend.url)
  }

  @MainActor
  func testSignedOutOfTailscaleItSaysSoAndServesNothing() async throws {
    let fake = HostFakeTailscale(installed: true, backendState: "NeedsLogin")
    let server = try await host(fake, hostTempDir(self))
    XCTAssertEqual(server.state, .loggedOut)
    XCTAssertEqual(fake.calls.filter { $0.hasPrefix("serve") }, [])
  }

  @MainActor
  func testHttpsOffThenOnTailscaleServesItAtItsTsNetName() async throws {
    let fake = HostFakeTailscale(installed: true, https: false)
    let server = try await host(fake, hostTempDir(self))
    XCTAssertEqual(server.state, .httpsOff)
    XCTAssertEqual(server.enableHttps, URL(string: HostFakeTailscale.enableLink))
    XCTAssertNil(server.publicUrl)

    fake.https = true
    await server.refresh()
    XCTAssertEqual(server.state, .ready)
    XCTAssertEqual(server.publicUrl, URL(string: "https://mac.tail1234.ts.net"))
    XCTAssertEqual(fake.calls.last, "serve --bg --https=443 http://127.0.0.1:\(server.port)")

    // Looking again doesn't serve again.
    let served = serves(fake)
    await server.refresh()
    let again = serves(fake)
    XCTAssertEqual(again, served)
  }

  @MainActor
  func testStoppingTakesItOffTheTailnetAndClosesThePort() async throws {
    let fake = HostFakeTailscale(installed: true)
    let server = try await host(fake, hostTempDir(self))
    let port = server.port
    XCTAssertEqual(server.state, .ready)
    await server.stop()
    XCTAssertEqual(fake.calls.last, "serve --https=443 off")
    XCTAssertFalse(hostListening(port))
    XCTAssertFalse(server.running)
  }

  @MainActor
  func testStoppingWhileTailscaleIsStillServingTakesBackWhatThatServePublishes() async throws {
    let fake = HostFakeTailscale(installed: true)
    fake.serveGate = HostGate()
    let server = BuiltInServer(
      dataDir: hostTempDir(self), tailscale: fake.tailscale, sidecar: HostFakeSidecar(), recheck: 0)
    try await server.start(port: 0)
    let port = server.port
    while !fake.calls.contains("serve --bg --https=443 http://127.0.0.1:\(port)") {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    async let stopped: Void = server.stop()
    try await Task.sleep(nanoseconds: 10_000_000)
    fake.serveGate!.complete()
    await stopped
    XCTAssertEqual(fake.calls.last, "serve --https=443 off")
    XCTAssertTrue(fake.serveConfig.isEmpty)
    XCTAssertEqual(server.state, .checking)
    XCTAssertFalse(hostListening(port))
  }

  @MainActor
  func testItsOwnServeEntryGoneWhileReadyIsPublishedAgain() async throws {
    let fake = HostFakeTailscale(installed: true)
    let server = try await host(fake, hostTempDir(self))
    XCTAssertEqual(server.state, .ready)

    // serve status can't say for a moment: nothing changes.
    fake.statusFails = true
    let before = serves(fake)
    await server.refresh()
    XCTAssertEqual(server.state, .ready)
    let after = serves(fake)
    XCTAssertEqual(after, before)

    fake.statusFails = false
    fake.serveConfig = [:]
    await server.refresh()
    XCTAssertEqual(fake.calls.last, "serve --bg --https=443 http://127.0.0.1:\(server.port)")
    XCTAssertTrue(JSON.object(fake.serveConfig).encoded().contains("http://127.0.0.1:\(server.port)"))
    XCTAssertEqual(server.state, .ready)
  }

  @MainActor
  func testATakenPortMovesItToTheNextOne() async throws {
    let taken = hostOccupy()
    defer { close(taken.fd) }
    let server = BuiltInServer(
      dataDir: hostTempDir(self), tailscale: HostFakeTailscale().tailscale, sidecar: HostFakeSidecar(), recheck: 0)
    addTeardownBlock { await server.stop() }
    try await server.start(port: taken.port)
    XCTAssertGreaterThan(server.port, taken.port)
  }

  @MainActor
  func testSomethingElseOn443StaysUntilItGoes() async throws {
    let fake = HostFakeTailscale(installed: true)
    fake.serving("http://127.0.0.1:3000")
    let server = try await host(fake, hostTempDir(self))
    XCTAssertEqual(server.state, .taken)
    XCTAssertTrue(server.error?.contains("http://127.0.0.1:3000") == true)
    XCTAssertNil(server.publicUrl)
    let link = try await server.setupLink()
    XCTAssertNil(link)

    fake.serveConfig = [:]
    await server.refresh()
    XCTAssertEqual(server.state, .ready)
  }

  @MainActor
  func testSomethingElseTaking443LaterShowsAndStoppingLeavesItThere() async throws {
    let fake = HostFakeTailscale(installed: true)
    let server = try await host(fake, hostTempDir(self))
    XCTAssertEqual(server.state, .ready)

    fake.serving("http://127.0.0.1:8080")
    await server.refresh()
    XCTAssertEqual(server.state, .taken)
    XCTAssertNil(server.publicUrl)
    await server.stop()
    XCTAssertFalse(fake.serveConfig.isEmpty)
  }

  @MainActor
  func testAnotherPocketTermsEntryIsTakenOnAFirstStartAndStays() async throws {
    let fake = HostFakeTailscale(installed: true)
    fake.serving("http://127.0.0.1:47900")
    let server = try await host(fake, hostTempDir(self))
    XCTAssertEqual(server.state, .taken)
    XCTAssertTrue(server.error?.contains("http://127.0.0.1:47900") == true)
    XCTAssertEqual(fake.calls.filter { $0.hasPrefix("serve --") }, [])
    await server.stop()
    XCTAssertFalse(fake.calls.contains("serve --https=443 off"))
    XCTAssertTrue(JSON.object(fake.serveConfig).encoded().contains("http://127.0.0.1:47900"))
  }

  @MainActor
  func testItsOwnEntryFromLastTimeMovesToThePortItHasNow() async throws {
    let fake = HostFakeTailscale(installed: true)
    fake.serving("http://127.0.0.1:47950")
    let server = BuiltInServer(
      dataDir: hostTempDir(self), tailscale: fake.tailscale, sidecar: HostFakeSidecar(), recheck: 0)
    addTeardownBlock { await server.stop() }
    try await server.start(port: 0, earlier: 47950)
    await server.refresh()
    XCTAssertEqual(server.state, .ready)
    XCTAssertEqual(fake.calls.last, "serve --bg --https=443 http://127.0.0.1:\(server.port)")
  }

  @MainActor
  func testTailscaleStoppingLaterTakesItOffBackOnItServesAgain() async throws {
    let fake = HostFakeTailscale(installed: true)
    let server = try await host(fake, hostTempDir(self))
    XCTAssertEqual(server.state, .ready)
    fake.backendState = "Stopped"
    await server.refresh()
    XCTAssertEqual(server.state, .tailscaleOff)
    XCTAssertNil(server.publicUrl)
    fake.backendState = "Running"
    await server.refresh()
    XCTAssertEqual(server.state, .ready)
  }

  @MainActor
  func testANewTailscaleNameMovesItThereAndIsRememberedUntilSeen() async throws {
    let fake = HostFakeTailscale(installed: true)
    let dir = hostTempDir(self)
    let server = try await host(fake, dir)
    XCTAssertNil(server.renamedFrom)

    fake.dnsName = "studio.tail1234.ts.net"
    await server.refresh()
    XCTAssertEqual(server.publicUrl, URL(string: "https://studio.tail1234.ts.net"))
    let link = try await server.setupLink()
    XCTAssertEqual(Backend.fromLink(link!)?.url, "https://studio.tail1234.ts.net")
    XCTAssertEqual(server.renamedFrom, URL(string: "https://mac.tail1234.ts.net"))

    // Renamed again: the phones still have the first one.
    fake.dnsName = "office.tail1234.ts.net"
    await server.refresh()
    XCTAssertEqual(server.renamedFrom, URL(string: "https://mac.tail1234.ts.net"))

    await server.stop()
    let again = try await host(fake, dir)
    XCTAssertEqual(again.renamedFrom, URL(string: "https://mac.tail1234.ts.net"))

    // Back at the first name: the phones' address works again.
    fake.dnsName = "mac.tail1234.ts.net"
    await again.refresh()
    XCTAssertNil(again.renamedFrom)

    fake.dnsName = "studio.tail1234.ts.net"
    await again.refresh()
    XCTAssertNotNil(again.renamedFrom)
    again.renameSeen()
    XCTAssertNil(again.renamedFrom)
  }

  @MainActor
  func testAServerThatEndsByItselfIsTakenOffTheTailnet() async throws {
    let fake = HostFakeTailscale(installed: true)
    let sidecar = HostFakeSidecar()
    let server = try await host(fake, hostTempDir(self), sidecar: sidecar)
    XCTAssertEqual(server.state, .ready)
    // The fake's server ends as a crashed sidecar would: its socket closes.
    let port = server.port
    let running = try XCTUnwrap(sidecar.servers.last)
    await running.stop()
    for _ in 0..<200 where server.running { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(server.running)
    XCTAssertEqual(fake.calls.last, "serve --https=443 off")
    XCTAssertFalse(hostListening(port))
  }
}

/// The real sidecar (tool/server-sidecar.sh), when POCKETTERM_SIDECAR names it.
final class SidecarHostingTests: XCTestCase {
  private func binary() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["POCKETTERM_SIDECAR"], !path.isEmpty else {
      throw XCTSkip("POCKETTERM_SIDECAR isn't set (tool/server-sidecar.sh builds it)")
    }
    return URL(fileURLWithPath: path)
  }

  @MainActor
  func testTheBundledServerListensAnswersMakesItsSetupLinkAndStops() async throws {
    let binary = try binary()
    let dir = hostTempDir(self).appendingPathComponent("pocketterm-server")
    let server = BuiltInServer(dataDir: dir, tailscale: HostFakeTailscale().tailscale, binary: binary, recheck: 0)
    addTeardownBlock { await server.stop() }
    try await server.start(port: 0)
    XCTAssertTrue(server.running)
    let port = server.port
    XCTAssertGreaterThan(port, 0)
    let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/health")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    let health = await server.backend.check()
    XCTAssertNil(health)

    let link = try await server.ownSetupLink()
    XCTAssertEqual(Backend.fromLink(link)?.url, "http://127.0.0.1:\(port)")
    let token = try XCTUnwrap(Backend.setupToken(link))
    XCTAssertEqual(token.count, 43)
    // The same token each time (only `--new` replaces it).
    let again = try await server.ownSetupLink()
    XCTAssertEqual(Backend.setupToken(again), token)

    await server.stop()
    XCTAssertFalse(server.running)
    XCTAssertFalse(hostListening(port))
  }

  @MainActor
  func testATakenPortMovesTheBundledServerToTheNextOne() async throws {
    let binary = try binary()
    let taken = hostOccupy()
    defer { close(taken.fd) }
    let server = BuiltInServer(
      dataDir: hostTempDir(self), tailscale: HostFakeTailscale().tailscale, binary: binary, recheck: 0)
    addTeardownBlock { await server.stop() }
    try await server.start(port: taken.port)
    XCTAssertGreaterThan(server.port, taken.port)
    XCTAssertTrue(hostListening(server.port))
  }

  func testASidecarThatIsntThereSaysSo() async {
    do {
      _ = try await BundledServer(binary: URL(fileURLWithPath: "/nonexistent/pocketterm-server")).serve(
        dataDir: FileManager.default.temporaryDirectory, port: 0, relay: nil, relayKey: nil)
      XCTFail("started")
    } catch {
      guard case .failed = error else { return XCTFail("\(error)") }
    }
  }
}
#endif
