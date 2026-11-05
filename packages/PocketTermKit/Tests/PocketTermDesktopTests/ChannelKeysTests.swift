#if os(macOS)
import Foundation
import PocketTermKit
import Security
import XCTest

@testable import PocketTermDesktop

final class ChannelKeysTests: XCTestCase {
  private func text(_ data: Data?) -> String? { data.flatMap { String(data: $0, encoding: .utf8) } }

  func testAThrowawayProfileKeepsItsSecretsInMemoryAndNeverReachesTheKeychain() async throws {
    let keychain = SystemOneFile()
    keychain.file = ["device_token": Data("the person's".utf8)]
    let tokens = SecretDeviceTokens(SystemSecrets(keychain, env: ["POCKETTERM_PROFILE": "smoke"]))
    var read = try await tokens.read()
    XCTAssertNil(read)
    try await tokens.write("throwaway")
    read = try await tokens.read()
    XCTAssertEqual(read, "throwaway")
    XCTAssertEqual(keychain.file, ["device_token": Data("the person's".utf8)])
    read = try await SecretDeviceTokens(SystemSecrets(keychain, env: [:])).read()
    XCTAssertEqual(read, "the person's")
    try await tokens.write(nil)
  }

  @MainActor
  func testWritesAtOnceFromTheDeviceTokenAndTheChannelKeysAllStay() async throws {
    let storage = SystemOneFile()
    let tokens = SecretDeviceTokens(SystemSecrets(storage, env: [:]))
    let keys = ChannelKeys(SystemSecrets(storage, env: [:]))
    async let a: Void = tokens.write("token")
    async let b = keys.of("desk-1")
    async let c = keys.of("desk-2")
    _ = try await (a, b, c)
    try await tokens.write("token 2")
    XCTAssertEqual(Set(storage.file.keys), ["device_token", "channel_key_desk-1", "channel_key_desk-2"])
    XCTAssertEqual(text(storage.file["device_token"]), "token 2")
    let read = try await tokens.read()
    XCTAssertEqual(read, "token 2")
  }

  func testAFailedWriteFailsAloneTheNextOnesStillRun() throws {
    let storage = SystemOneFile()
    storage.failNext = true
    let secrets = SystemSecrets(storage, env: [:])
    XCTAssertThrowsError(try secrets.setData("a", Data("1".utf8)))
    try secrets.setData("b", Data("2".utf8))
    XCTAssertEqual(storage.file, ["b": Data("2".utf8)])
  }

  @MainActor
  func testAKeyIsMadeOnceKeptAndTwoAskingAtOnceGetTheSameOne() async throws {
    let store = MemorySecureStore()
    let keys = ChannelKeys(store)
    async let first = keys.of("desk")
    async let second = keys.of("desk")
    let (a, b) = try await (first, second)
    XCTAssertEqual(a, b)
    // Standard base64, as the Flutter app kept it.
    XCTAssertEqual(text(try store.data("channel_key_desk")), a.toBase64())
    let again = try await ChannelKeys(store).of("desk")
    XCTAssertEqual(again, a)
    let other = try await keys.of("other")
    XCTAssertNotEqual(other, a)
  }

  @MainActor
  func testAKeyTheFlutterAppKeptIsUsedAndABrokenOneReplaced() async throws {
    let store = MemorySecureStore()
    let kept = ChannelKey.generate()
    try store.setData("channel_key_desk", Data(kept.toBase64().utf8))
    try store.setData("channel_key_broken", Data("not a key".utf8))
    let keys = ChannelKeys(store)
    let read = try await keys.of("desk")
    XCTAssertEqual(read, kept)
    let made = try await keys.of("broken")
    XCTAssertEqual(text(try store.data("channel_key_broken")), made.toBase64())
  }

  @MainActor
  func testResetMakesANewKeyThatIsKept() async throws {
    let store = MemorySecureStore()
    let keys = ChannelKeys(store)
    let old = try await keys.of("desk")
    let new = try await keys.reset("desk")
    XCTAssertNotEqual(old, new)
    let now = try await keys.of("desk")
    XCTAssertEqual(now, new)
    XCTAssertEqual(text(try store.data("channel_key_desk")), new.toBase64())
  }

  @MainActor
  func testALockedStoreIsAskedAgainNextTime() async throws {
    let store = SystemOneFile()
    store.failNext = true
    let keys = ChannelKeys(store)
    do {
      _ = try await keys.of("desk")
      XCTFail("got a key")
    } catch is SecureStoreError {}
    let key = try await keys.of("desk")
    XCTAssertEqual(text(store.file["channel_key_desk"]), key.toBase64())
  }

  // ---------------------------------------------------------------- the Keychain

  /// A service of this test's own, so the person's items are never touched.
  private func keychain() -> KeychainStore {
    let store = KeychainStore(service: "PocketTermTests-\(UUID().uuidString)")
    addTeardownBlock {
      // The file-based keychain deletes one match per call.
      let all = [kSecClass: kSecClassGenericPassword, kSecAttrService: store.service] as CFDictionary
      while SecItemDelete(all) == errSecSuccess {}
    }
    return store
  }

  /// The query flutter_secure_storage_darwin 0.3.2 built for the Flutter app's options: accountName `service`,
  /// accessibility unlocked, synchronizable false, the login keychain.
  private func flutterQuery(_ service: String, _ key: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword, kSecAttrAccount: key, kSecAttrService: service,
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked, kSecAttrSynchronizable: false,
    ]
  }

  private func skipUnlessKeychain(_ store: KeychainStore) throws {
    do {
      try store.setData("probe", Data("1".utf8))
      try store.remove("probe")
    } catch let e as SecureStoreError where e.status == errSecInteractionNotAllowed || e.status == errSecNoSuchKeychain {
      throw XCTSkip("no login keychain here: \(e)")
    }
  }

  func testTheKeychainKeepsReplacesAndForgetsASecret() throws {
    let store = keychain()
    try skipUnlessKeychain(store)
    XCTAssertNil(try store.data("device_token"))
    try store.setData("device_token", Data("one".utf8))
    XCTAssertEqual(text(try store.data("device_token")), "one")
    try store.setData("device_token", Data("two".utf8))
    XCTAssertEqual(text(try store.data("device_token")), "two")
    try store.remove("device_token")
    XCTAssertNil(try store.data("device_token"))
    try store.remove("device_token")
  }

  func testWhatTheFlutterAppKeptInTheKeychainIsReadAsIsAndWrittenBackTheSameWay() throws {
    let store = keychain()
    try skipUnlessKeychain(store)
    // As flutter_secure_storage wrote it.
    var add = flutterQuery(store.service, "channel_key_desk")
    add[kSecValueData] = Data("é key".utf8)
    XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)
    XCTAssertEqual(text(try store.data("channel_key_desk")), "é key")

    // Written natively: flutter_secure_storage (an older version run again) still reads it.
    try store.setData("device_token", Data("token".utf8))
    var read = flutterQuery(store.service, "device_token")
    read[kSecReturnData] = true
    var ref: AnyObject?
    XCTAssertEqual(SecItemCopyMatching(read as CFDictionary, &ref), errSecSuccess)
    XCTAssertEqual(text(ref as? Data), "token")
    // One item per name, not one per writer.
    var all = [kSecClass: kSecClassGenericPassword, kSecAttrService: store.service, kSecMatchLimit: kSecMatchLimitAll,
      kSecReturnAttributes: true] as [CFString: Any]
    all[kSecAttrAccount] = "device_token"
    var items: AnyObject?
    XCTAssertEqual(SecItemCopyMatching(all as CFDictionary, &items), errSecSuccess)
    XCTAssertEqual((items as? [[String: Any]])?.count, 1)
  }

  func testTheNativeAppKeepsTheFlutterAppsService() {
    XCTAssertEqual(KeychainStore().service, "PocketTerm")
  }
}
#endif
