#if os(macOS)
import Foundation
import PocketTermKit
import XCTest

@testable import PocketTermDesktop

/// controller_test.dart.
final class ControllerTests: XCTestCase {
  func testKittysSocketsAreInTmpUnlessPocketTermKittyDirNamesAnother() {
    XCTAssertEqual(AppController.kittyDir([:]), "/tmp")
    XCTAssertEqual(AppController.kittyDir(["POCKETTERM_KITTY_DIR": ""]), "/tmp")
    XCTAssertEqual(AppController.kittyDir(["POCKETTERM_KITTY_DIR": "/tmp/pocketterm-e2e"]), "/tmp/pocketterm-e2e")
  }

  @MainActor
  func testSignedOutNothingGoesToThePhoneAndTheComputerIsNotEvenAsked() async {
    let app = TestApp()
    let sent = await app.notifyPhone("omp finished · app", "Done.", session: "kitty:/tmp/k/1")
    XCTAssertFalse(sent)
    XCTAssertEqual(app.fakeHost.calls, [])
  }

  @MainActor
  func testAtTheDeskNothingGoesToThePhone() async {
    let app = TestApp()
    await app.signIn()
    app.fakeHost.idle = 59
    app.fakeHost.calls.removeAll()
    let sent = await app.notifyPhone("omp finished · app", "Done.")
    XCTAssertFalse(sent)
    XCTAssertEqual(app.fakeHost.calls, ["idleSeconds"])
  }

  @MainActor
  func testAPushGoesSealedOutsideTheSealOnlyTagsThatMeanNothingWithoutTheKey() async throws {
    let app = TestApp()
    await app.signIn()
    app.fakeHost.idle = 600
    let sent = await app.notifyPhone("omp finished · secret-project", "Fixed the login bug.", session: "kitty-1/2")
    XCTAssertTrue(sent)

    let body = try XCTUnwrap(app.pushes.first)
    XCTAssertEqual(app.pushes.count, 1)
    let desktop = app.desktopId(app.user!.id)
    let link = try await app.pairingLink()
    let key = try XCTUnwrap(Backend.computerKey(link)).key
    XCTAssertEqual(Set(body.keys), ["action", "tag", "enc", "collapse"])
    XCTAssertEqual(body["action"]?.string, "notify")
    // The phone finds this computer's key by its tag; a newer push for the session replaces this one.
    XCTAssertEqual(body["tag"]?.string, pushTag(key))
    XCTAssertEqual(body["collapse"]?.string, sessionTag(key, "\(desktop)/kitty-1/2"))
    let wire = JSON.object(body).encoded()
    for secret in ["secret-project", "login", "finished", desktop, "kitty-1/2"] {
      XCTAssertFalse(wire.contains(secret), secret)
    }

    // A phone that scanned this computer's code opens it.
    let enc = try XCTUnwrap(Data(base64Encoded: body["enc"]!.string!))
    let opened = try XCTUnwrap(openBytes(key, enc, pushAad(desktop)))
    let notice = try XCTUnwrap(JSON.tryParse(opened)?.object)
    XCTAssertEqual(Set(notice.keys), ["title", "body", "session", "ts", "id"])
    XCTAssertEqual(notice["title"]?.string, "omp finished · secret-project")
    XCTAssertEqual(notice["body"]?.string, "Fixed the login bug.")
    XCTAssertEqual(notice["session"]?.string, "\(desktop)/kitty-1/2")
    // A phone refuses an old or repeated notice.
    let ts = try XCTUnwrap(notice["ts"]?.int)
    XCTAssertLessThan(Int(Date().timeIntervalSince1970 * 1000) - ts, 60000)
    XCTAssertNotNil(notice["id"]?.string)
    XCTAssertNil(openBytes(key, enc, pushAad("zzzz9999")))
  }

  @MainActor
  func testResetKeyTheCodeCarriesANewKeyAndAnOldOneCantOpenWhatComesNext() async throws {
    let app = TestApp()
    await app.signIn()
    app.fakeHost.idle = 600
    let first = try await app.pairingLink()
    let old = try XCTUnwrap(Backend.computerKey(first))
    let second = try await app.pairingLink()
    XCTAssertEqual(Backend.computerKey(second), old, "the key stays until reset")

    try await app.resetChannelKey()
    let third = try await app.pairingLink()
    let fresh = try XCTUnwrap(Backend.computerKey(third))
    XCTAssertEqual(fresh.desktop, old.desktop)
    XCTAssertNotEqual(fresh.key, old.key)

    _ = await app.notifyPhone("Claude Code needs you · app", "Allow?")
    let enc = try XCTUnwrap(Data(base64Encoded: app.pushes.first!["enc"]!.string!))
    XCTAssertNil(openBytes(old.key, enc, pushAad(old.desktop)))
    XCTAssertNotNil(openBytes(fresh.key, enc, pushAad(old.desktop)))
  }

  @MainActor
  func testTheFirstSignInTurnsOnTerminalFromPhoneOnceAndNeverAddsALoginItem() async throws {
    let app = TestApp()
    await app.signIn()
    await settle()
    XCTAssertTrue(app.terminalOn)
    XCTAssertFalse(app.fakeHost.loginItem)
    XCTAssertFalse(app.fakeHost.calls.contains("setLaunchAtLogin(true)"))

    // Turned off again, it stays off at the next sign-in.
    try await app.setTerminal(on: false)
    app.fakeHost.calls.removeAll()
    await app.onSignedIn(app.user!)
    XCTAssertFalse(app.terminalOn)
    XCTAssertEqual(app.fakeHost.calls, [])
  }

  @MainActor
  func testAComputerThatHadItsFirstSignInKeepsItsSettings() async {
    let prefs = MemoryPreferenceStore()
    prefs.setBool("first_sign_in_done", true)
    let app = TestApp(prefs: prefs)
    await app.signIn()
    await settle()
    XCTAssertFalse(app.terminalOn)
    XCTAssertEqual(app.fakeHost.calls, [])
  }

  @MainActor
  func testAtLaunchAComputerNotSetUpYetShowsItsWindow() async {
    let app = TestApp()
    await app.start()
    XCTAssertEqual(app.fakeHost.calls, ["start", "showMain"])
    XCTAssertEqual(app.mainShown, 1)
  }

  @MainActor
  func testAtLaunchSignedInItStartsInTheBackground() async {
    let prefs = MemoryPreferenceStore()
    prefs.setBool("first_sign_in_done", true)
    Backend(url: "https://my-mac.tail1234.ts.net").save(to: PreferencesBackendStore(prefs))
    let app = TestApp(prefs: prefs)
    await app.start()
    XCTAssertNotNil(app.user)
    XCTAssertEqual(app.fakeHost.calls, ["start"])
  }

  @MainActor
  func testAtLaunchAComputerOnAVpsIsSignedOutOnceAndTheSetupSaysWhy() async throws {
    let prefs = MemoryPreferenceStore()
    let secrets = ControllerSecrets()
    try await SecretDeviceTokens(secrets).write("kept-sign-in")
    Backend(url: "https://pt.example.com").save(to: PreferencesBackendStore(prefs))
    let app = TestApp(prefs: prefs, secrets: secrets)
    await app.start()
    XCTAssertNil(app.user)
    XCTAssertNil(app.backend)
    XCTAssertNil(prefs.string("backend_url"))
    let tokens = try await SecretDeviceTokens(secrets).read()
    XCTAssertNil(tokens, "signed out here")
    XCTAssertEqual(app.fakeHost.calls, ["start", "showMain"])
    XCTAssertTrue(app.movedNote?.hasPrefix("PocketTerm now runs its server on this computer") == true)
    // The VPS is told, in the background.
    for _ in 0..<100 where app.fakeServer?.left != true { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertEqual(app.fakeServer?.left, true)
    XCTAssertEqual(app.fakeServer?.backend.url, "https://pt.example.com")

    // Launched again: nothing more to do; the note stays until a sign-in.
    let again = TestApp(prefs: prefs, secrets: secrets)
    await again.start()
    XCTAssertNil(again.fakeServer)
    XCTAssertNotNil(again.movedNote)
    await again.signIn()
    for _ in 0..<100 where again.movedNote != nil { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertNil(again.movedNote, "shown once")
  }

  @MainActor
  func testAtLaunchAComputerOnSupabaseIsSignedOutWithoutAskingIt() async throws {
    for kept in [("backend_kind", "supabase"), ("backend_key", "sb_publishable_x")] {
      let prefs = MemoryPreferenceStore()
      let secrets = ControllerSecrets()
      try await SecretDeviceTokens(secrets).write("kept-sign-in")
      prefs.setString("backend_url", "https://abcdefghijklmnop.supabase.co")
      prefs.setString(kept.0, kept.1)
      let app = TestApp(prefs: prefs, secrets: secrets)
      await app.start()
      XCTAssertNil(app.user, kept.0)
      XCTAssertNil(app.fakeServer, "Supabase isn't spoken to")
      XCTAssertNil(prefs.string("backend_url"), kept.0)
      XCTAssertFalse(prefs.contains(kept.0), kept.0)
      let tokens = try await SecretDeviceTokens(secrets).read()
      XCTAssertNil(tokens, kept.0)
      XCTAssertNotNil(app.movedNote, kept.0)
    }
  }

  @MainActor
  func testAtLaunchAComputerOnTailscaleOrItsOwnServerStaysSignedIn() async {
    for url in ["https://other-mac.tail1234.ts.net", "http://127.0.0.1:47900"] {
      let prefs = MemoryPreferenceStore()
      Backend(url: url).save(to: PreferencesBackendStore(prefs))
      let app = TestApp(prefs: prefs)
      await app.start()
      XCTAssertNotNil(app.user, url)
      XCTAssertNil(app.movedNote, url)
    }
  }

  @MainActor
  func testTheHostsMenuItemsOpenTheWindowAndQuittingWaitsForOnQuit() async {
    let prefs = MemoryPreferenceStore()
    Backend(url: "https://my-mac.tail1234.ts.net").save(to: PreferencesBackendStore(prefs))
    let app = TestApp(prefs: prefs)
    await app.start()
    var release: CheckedContinuation<Void, Never>?
    var quitStarted = false
    app.onQuit = {
      quitStarted = true
      await withCheckedContinuation { release = $0 }
    }
    app.fakeHost.calls.removeAll()

    await app.fakeHost.onEvent!("openSettings")
    await app.fakeHost.onEvent!("mainClosed")
    await settle()
    XCTAssertEqual(app.fakeHost.calls, ["showMain"])
    XCTAssertTrue(app.mainHidden)

    var quitting = false
    let quit = Task { @MainActor in
      await app.fakeHost.onEvent!("quitting")
      quitting = true
    }
    await settle()
    XCTAssertTrue(quitStarted)
    XCTAssertFalse(quitting)
    release?.resume()
    await quit.value
    XCTAssertTrue(quitting)
  }

  @MainActor
  func testThisComputersIdIsMadeOncePerUserInTheFormTheServerTakes() {
    let app = TestApp()
    let id = app.desktopId("user-1")
    XCTAssertNotNil(id.range(of: "^[a-z0-9]{8}$", options: .regularExpression))
    XCTAssertEqual(app.desktopId("user-1"), id)
    XCTAssertNotEqual(app.desktopId("user-2"), id)
  }

  func testTheComputersNameFitsTheServers1To80Characters() {
    XCTAssertEqual(AppController.desktopName("  Ana’s MacBook  "), "Ana’s MacBook")
    XCTAssertEqual(AppController.desktopName(" "), "Computer")
    XCTAssertEqual(AppController.desktopName(String(repeating: "x", count: 100)), String(repeating: "x", count: 80))
  }

  @MainActor
  func testAPhoneSignedInIsAskedUntilYesThenKeptPerServer() async {
    let prefs = MemoryPreferenceStore()
    let app = TestApp(prefs: prefs)
    await app.signIn()
    XCTAssertNil(app.phoneSignedIn)
    await app.checkPhone()
    XCTAssertEqual(app.phoneSignedIn, false)
    app.fakeServer!.phones = true
    await app.checkPhone()
    XCTAssertEqual(app.phoneSignedIn, true)
    XCTAssertEqual(prefs.bool("phone_signed_in_server-1"), true)

    // Launched again on the same server: known at once.
    let again = TestApp(prefs: prefs)
    await again.signIn()
    XCTAssertEqual(again.phoneSignedIn, true)
  }

  @MainActor
  func testPreferencesKeepTheFlutterAppsKeysAndDefaults() {
    let prefs = MemoryPreferenceStore()
    let app = TestApp(prefs: prefs)
    XCTAssertEqual(app.terminalApp, "auto")
    XCTAssertEqual(app.placement, .projectWindow)
    XCTAssertEqual(app.codingAgent, .omp)
    XCTAssertEqual(app.projectRoots, [])
    XCTAssertNil(app.setupStep)
    XCTAssertFalse(app.getReadyDone)

    app.setTerminalApp("kitty")
    app.setPlacement(.newWindow)
    app.setCodingAgent(.claude)
    app.setProjectRoots(["/Users/me/Dev"])
    app.setSetupStep("thisComputer")
    app.setGetReadyDone(true)
    XCTAssertEqual(prefs.string("terminal_app"), "kitty")
    XCTAssertEqual(prefs.string("session_placement"), "newWindow")
    XCTAssertEqual(prefs.string("coding_agent"), "claude")
    XCTAssertEqual(prefs.stringList("project_roots"), ["/Users/me/Dev"])
    XCTAssertEqual(prefs.string("setup_step"), "thisComputer")
    XCTAssertEqual(prefs.bool("get_ready_done"), true)
    app.setSetupStep(nil)
    XCTAssertFalse(prefs.contains("setup_step"))
  }

  @MainActor
  func testLaunchAtLoginIsHowTheSystemHasItAlsoAfterARefusal() async {
    let app = TestApp()
    XCTAssertNil(app.launchAtLogin)
    try? await app.setLaunchAtLogin(on: true)
    XCTAssertEqual(app.launchAtLogin, true)
    app.fakeHost.loginItemRefused = MacHost.loginItemsHint
    do {
      try await app.setLaunchAtLogin(on: false)
      XCTFail("the refusal should come through")
    } catch {
      XCTAssertEqual("\(error)", MacHost.loginItemsHint)
    }
    XCTAssertEqual(app.launchAtLogin, true)
  }
}
#endif
