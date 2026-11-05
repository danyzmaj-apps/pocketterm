import PocketTermKit
import XCTest

@testable import PocketTerm

/// Upgrading from the Flutter app (0.1.x): its shared_preferences sat in the app's UserDefaults as
/// `flutter.<key>`; the native app must find every one of them under its own key.
nonisolated final class MigrationTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUp() {
    suite = "pocketterm-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
  }

  @MainActor func testEveryFlutterPreferenceMovesToItsNativeKeyWithItsValue() {
    let looks = #"{"abcd1234|kitty-1/3":{"name":"API","color":4293281869}}"#
    let draft = #"{"t":"half a prompt","at":1730000000000}"#
    let flutter: [String: Any] = [
      "flutter.theme": "tokyoNight",
      "flutter.pocketterm_terminal_sort": "activity",
      "flutter.pocketterm_terminal_folded": ["/Users/me/Dev/a", "/Users/me/Dev/b"],
      "flutter.pocketterm_tile_looks": looks,
      "flutter.pocketterm_profile_filter_abcd1234": "personal",
      "flutter.pocketterm_new_profile_abcd1234": "work",
      "flutter.pocketterm_desktop": "abcd1234",
      "flutter.pocketterm_desktops": "[]",
      "flutter.pocketterm_push_on_u1": true,
      "flutter.pocketterm_tips_seen": ["slash", "queue"],
      "flutter.voiceLanguage": "croatian",
      "flutter.pocketterm_draft_abcd1234/kitty-1/3": draft,
    ]
    for (k, v) in flutter { defaults.set(v, forKey: k) }

    FlutterPreferences.migrate(defaults)
    let prefs = Preferences(defaults)

    XCTAssertEqual(prefs.string("theme"), "tokyoNight")
    XCTAssertEqual(prefs.string("pocketterm_terminal_sort"), "activity")
    XCTAssertEqual(prefs.stringList("pocketterm_terminal_folded"), ["/Users/me/Dev/a", "/Users/me/Dev/b"])
    XCTAssertEqual(prefs.string("pocketterm_tile_looks"), looks)
    XCTAssertEqual(prefs.string("pocketterm_profile_filter_abcd1234"), "personal")
    XCTAssertEqual(prefs.string("pocketterm_new_profile_abcd1234"), "work")
    XCTAssertEqual(prefs.string("pocketterm_desktop"), "abcd1234")
    XCTAssertEqual(prefs.bool("pocketterm_push_on_u1"), true)
    XCTAssertEqual(prefs.stringList("pocketterm_tips_seen"), ["slash", "queue"])
    XCTAssertEqual(prefs.string("voiceLanguage"), "croatian")
    XCTAssertEqual(prefs.string("pocketterm_draft_abcd1234/kitty-1/3"), draft)
    XCTAssertTrue(prefs.keys(withPrefix: "flutter.").isEmpty, "the Flutter copies go")
  }

  @MainActor func testTheMigratedPreferencesReadAsTheChoicesTheyWere() {
    defaults.set("dawn", forKey: "flutter.theme")
    defaults.set("croatian", forKey: "flutter.voiceLanguage")
    defaults.set(["switch-open"], forKey: "flutter.pocketterm_tips_seen")
    defaults.set("activity", forKey: "flutter.pocketterm_terminal_sort")
    FlutterPreferences.migrate(defaults)
    let prefs = Preferences(defaults)

    let look = Appearance()
    look.load(prefs)
    // 0.1.7's Rosé Pine Dawn is the Rosé Pine family now, kept under its new name.
    XCTAssertEqual(look.choice, .rosePine)
    XCTAssertEqual(prefs.string("theme"), "rosePine")
    let voice = VoiceLanguage()
    voice.load(prefs)
    XCTAssertEqual(voice.choice, .croatian)
    let tips = TipsController(prefs: prefs, startSeen: false)
    XCTAssertTrue(tips.answered, "a phone that answered the tour isn't asked again")
    XCTAssertTrue(tips.seen(.switchOpen))
    XCTAssertFalse(tips.seen(.slash))
    let app = AppModel(
      prefs: prefs, device: "test", deviceTokens: MemoryDeviceTokens(), backendStore: MemoryBackendStore(),
      native: .fake)
    XCTAssertEqual(app.projectSort, .activity)
  }

  @MainActor func testAKeyTheNativeAppAlreadyHasKeepsItsValueAndTheMoveRunsOnce() {
    defaults.set("tokyoNight", forKey: "theme")
    defaults.set("dawn", forKey: "flutter.theme")
    FlutterPreferences.migrate(defaults)
    XCTAssertEqual(defaults.string(forKey: "theme"), "tokyoNight")

    // Removed later by the person (Auto again): a second launch doesn't bring the old value back.
    defaults.removeObject(forKey: "voiceLanguage")
    defaults.set("croatian", forKey: "flutter.voiceLanguage")
    FlutterPreferences.migrate(defaults)
    XCTAssertNil(defaults.string(forKey: "voiceLanguage"))
  }

  @MainActor func testDraftsExpireAfterThirtyDaysAndBlankRemoves() {
    let prefs = Preferences(defaults)
    let drafts = Drafts(prefs: prefs)
    let now = Date()
    drafts.save("abcd1234/s1", "keep me", now: now.addingTimeInterval(-29 * 86400))
    drafts.save("abcd1234/s2", "old", now: now.addingTimeInterval(-31 * 86400))
    XCTAssertEqual(drafts.load("abcd1234/s1", now: now), "keep me")
    XCTAssertNil(prefs.string(Drafts.key("abcd1234/s2")), "a stale draft is dropped on the way")
    drafts.save("abcd1234/s1", "  ", now: now)
    XCTAssertEqual(drafts.load("abcd1234/s1", now: now), "")
  }
}

/// A server kept in memory, for AppModel in tests.
nonisolated final class MemoryBackendStore: BackendStore, @unchecked Sendable {
  var saved: (url: String, kind: String?, legacy: Bool)?
  func loadBackend() -> (url: String, kind: String?, legacy: Bool)? { saved }
  func saveBackend(url: String?, kind: String?) { saved = url.map { ($0, kind, false) } }
}

extension PhoneNative {
  /// Nothing native: no Keychain, no push, no Live Activities.
  static var fake: PhoneNative {
    final class Keys: @unchecked Sendable { var all: [String: ChannelKey] = [:] }
    let keys = Keys()
    return PhoneNative(
      channelKeys: { keys.all }, setChannelKey: { keys.all[$1] = $0 }, removeAllChannelKeys: { keys.all = [:] },
      registerPush: { nil }, notificationsAllowed: { false }, endAllActivities: {})
  }
}
