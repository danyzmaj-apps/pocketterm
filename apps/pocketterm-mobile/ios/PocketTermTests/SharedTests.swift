import PocketTermKit
import XCTest

@testable import PocketTerm

nonisolated final class SharedTests: XCTestCase {
  /// The tags pocketterm_core's e2e_test pins for the computer's side: a push names its computer only by this, and
  /// the iPhone must pick the same key the computer sealed with.
  @MainActor func testPushTagPicksTheKeyOfTheComputerThatSealedIt() {
    let seven = Data(repeating: 7, count: 32)
    let nine = Data(repeating: 9, count: 32)
    XCTAssertEqual(PocketTermShared.pushTag(seven), "RJM0r7AxRLM")
    XCTAssertEqual(PocketTermShared.pushTag(nine), "xx8kW7GbrvA")
    let keys = ["abcd1234": seven, "zzzz9999": nine]
    XCTAssertEqual(PocketTermShared.computer(tagged: "xx8kW7GbrvA", in: keys)?.desktop, "zzzz9999")
    XCTAssertEqual(PocketTermShared.computer(tagged: "RJM0r7AxRLM", in: keys)?.key, seven)
    XCTAssertNil(PocketTermShared.computer(tagged: "RJM0r7AxRLM", in: ["zzzz9999": nine]), "a computer never scanned")
    // The same tag the shared core computes for the computer's side.
    XCTAssertEqual(PocketTermShared.pushTag(seven), pushTag(ChannelKey(seven)!))
  }

  /// A Live Activity's pushes carry only its state; which session a tap opens comes from what the phone set when it
  /// started the activity.
  @MainActor func testLiveActivityTapOpensTheSessionThePhoneSetLocally() throws {
    let activity = SessionActivity(key: "abcd1234/kitty-1/2", title: "Fix it", project: "app")
    let link = try XCTUnwrap(URLComponents(url: activity.link, resolvingAgainstBaseURL: false))
    XCTAssertEqual(link.scheme, "pocketterm")
    XCTAssertEqual(link.host, "session")
    XCTAssertEqual(link.queryItems, [URLQueryItem(name: "key", value: "abcd1234/kitty-1/2")])

    let pushed = try JSONEncoder().encode(
      SessionActivity.ContentState(state: .needs, since: 1_700_000_000, kind: .approval))
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: pushed) as? [String: Any])
    XCTAssertEqual(Set(fields.keys), ["state", "since", "kind"], "no session key or computer id in what a push sets")
  }

  /// The theme icons the asset catalog must have, by PocketTermKit's appIconFor names, and the retired ones a phone
  /// may still show (an update can't install without them).
  @MainActor func testEveryThemeHasItsAlternateIcon() {
    XCTAssertNil(AppIcons.alternateName(appIconFor(.system)))
    XCTAssertNil(AppIcons.alternateName(appIconFor(.catppuccin)))
    XCTAssertEqual(AppIcons.alternateName(appIconFor(.rosePine)), "AppIcon-Dawn")
    XCTAssertEqual(AppIcons.alternateName(appIconFor(.tokyoNight)), "AppIcon-TokyoNight")
    let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
    let alternates = (icons?["CFBundleAlternateIcons"] as? [String: Any]).map { Set($0.keys) } ?? []
    XCTAssertTrue(
      alternates.isSuperset(of: ["AppIcon-Mocha", "AppIcon-Dawn", "AppIcon-TokyoNight", "AppIcon-Gruvbox"]),
      "\(alternates)")
    for theme in ThemeChoice.allCases {
      XCTAssertNotNil(UIImage(named: theme.launchIcon), theme.rawValue)
    }
  }
}

/// AppModel (the Dart MobileSession) without a server.
nonisolated final class AppModelTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() {
    suite = "pocketterm-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  /// 0.1 connected through a Supabase project: the phone forgets the project, its sign-in, keys, cached computers
  /// and Supabase session, and keeps the person's choices.
  @MainActor func testTheSupabaseAppsDataGoesAndTheChoicesStay() async throws {
    let prefs = Preferences(defaults)
    prefs.setString("sb-abc-auth-token", "x")
    prefs.setString("supabase.session", "x")
    prefs.setString("pocketterm_push_token", "x")
    prefs.setString(AppModel.desktopKey, "abcd1234")
    prefs.setString(AppModel.desktopsKey, "[]")
    prefs.setString("theme", "dawn")
    prefs.setStringList(TipsController.seenKey, ["slash"])
    let store = MemoryBackendStore()
    store.saved = ("https://x.supabase.co", "supabase", true)
    let tokens = MemoryDeviceTokens()
    try await tokens.write("old")
    var native = PhoneNative.fake
    try native.setChannelKey(ChannelKey.generate(), "abcd1234")
    var ended = false
    native.endAllActivities = { ended = true }
    let app = AppModel(prefs: prefs, device: "test", deviceTokens: tokens, backendStore: store, native: native)

    await app.forgetOldApp()

    XCTAssertNil(store.saved)
    let token = try await tokens.read()
    XCTAssertNil(token)
    XCTAssertTrue(native.channelKeys().isEmpty)
    XCTAssertTrue(ended, "followed sessions end")
    for k in ["sb-abc-auth-token", "supabase.session", "pocketterm_push_token", AppModel.desktopKey, AppModel.desktopsKey] {
      XCTAssertNil(prefs.string(k), k)
    }
    XCTAssertEqual(prefs.string("theme"), "dawn")
    XCTAssertEqual(prefs.stringList(TipsController.seenKey), ["slash"])
  }

  /// A phone on a Supabase project (PocketTerm 0.2): signed out here with a note, the person's choices kept;
  /// once the computer's new code signs it in, the note goes.
  @MainActor func testAPhoneOnSupabaseIsSignedOutWithANoteOnce() async throws {
    let prefs = Preferences(defaults)
    prefs.setString("theme", "dawn")
    let store = MemoryBackendStore()
    store.saved = ("https://abcdefghijklmnop.supabase.co", "supabase", false)
    let tokens = MemoryDeviceTokens()
    try await tokens.write("old")
    var native = PhoneNative.fake
    try native.setChannelKey(ChannelKey.generate(), "abcd1234")
    var ended = false
    native.endAllActivities = { ended = true }
    let app = AppModel(prefs: prefs, device: "test", deviceTokens: tokens, backendStore: store, native: native)

    await app.launch()

    XCTAssertNil(store.saved)
    XCTAssertNil(app.backend)
    XCTAssertNil(app.user)
    let token = try await tokens.read()
    XCTAssertNil(token)
    XCTAssertTrue(native.channelKeys().isEmpty)
    XCTAssertTrue(ended, "followed sessions end")
    XCTAssertEqual(app.movedNote, "Your computer's PocketTerm now runs its own server. Scan its new code.")
    XCTAssertEqual(prefs.string("theme"), "dawn")

    let account = Account(id: "server-1", device: Device(id: "phone-1", role: .phone, label: "Phone", platform: "ios"))
    await app.onSignedIn(account)
    XCTAssertNil(app.movedNote, "shown once")
  }

  /// Any other server stays: a computer's on Tailscale, or one on a VPS (that computer moves; this phone then
  /// scans its new code).
  @MainActor func testAPhoneOnAPocketTermServerKeepsIt() async throws {
    for url in ["https://my-mac.tail1234.ts.net", "https://pt.example.com"] {
      let store = MemoryBackendStore()
      store.saved = (url, nil, false)
      let tokens = MemoryDeviceTokens()
      try await tokens.write("kept")
      let app = AppModel(
        prefs: Preferences(defaults), device: "test", deviceTokens: tokens, backendStore: store, native: .fake)
      await app.leaveSupabase()
      XCTAssertEqual(store.saved?.url, url)
      let token = try await tokens.read()
      XCTAssertEqual(token, "kept", url)
      XCTAssertNil(app.movedNote, url)
    }
  }

  @MainActor func testRowNamesAndColoursAreKeptPerComputer() {
    let app = AppModel(
      prefs: Preferences(defaults), device: "test", deviceTokens: MemoryDeviceTokens(),
      backendStore: MemoryBackendStore(), native: .fake)
    app.setTileLooks("abcd1234", ["kitty-1/3": TileLook(name: "API", color: tileColors[0]), "gone": TileLook()])
    app.setTileLooks("zzzz9999", ["kitty-1/3": TileLook(name: "Other")])
    XCTAssertEqual(app.tileLooks("abcd1234"), ["kitty-1/3": TileLook(name: "API", color: tileColors[0])])
    XCTAssertEqual(app.tileLooks("zzzz9999")["kitty-1/3"]?.name, "Other")
  }

  /// A followed session's link waits for the home page; anything else is ignored.
  @MainActor func testASessionLinkWaitsUntilTaken() {
    let app = AppModel(
      prefs: Preferences(defaults), device: "test", deviceTokens: MemoryDeviceTokens(),
      backendStore: MemoryBackendStore(), native: .fake)
    app.openedLink(URL(string: "pocketterm://session?key=abcd1234%2Fkitty-1%2F3")!)
    XCTAssertEqual(app.takeOpenedSession(), "abcd1234/kitty-1/3")
    XCTAssertNil(app.takeOpenedSession())
    app.openedLink(URL(string: "https://example.com/session?key=x")!)
    XCTAssertNil(app.takeOpenedSession())
  }
}
