#if os(macOS)
import Foundation
import PocketTermKit
import Security

/// Secrets as generic passwords in the login Keychain (not the data-protection keychain, so no keychain
/// entitlement is needed and any signing works, an ad-hoc dev build too).
///
/// The items are exactly the ones the Flutter app's flutter_secure_storage wrote (flutter_secure_storage_darwin
/// 0.3.2 with `MacOsOptions(accountName: 'PocketTerm', usesDataProtectionKeychain: false)`): service `PocketTerm`,
/// account the secret's name, accessible when unlocked, not synchronized, the value's UTF-8 bytes, no label. So an
/// upgrade from the Flutter app reads its sign-in and channel keys as they are, with nothing to migrate.
public final class KeychainStore: SecureStore, @unchecked Sendable {
  /// The Flutter app's service, which the native app keeps.
  public static let defaultService = "PocketTerm"

  public let service: String

  /// `service`: `PocketTerm`; tests pass one of their own.
  public init(service: String = KeychainStore.defaultService) {
    self.service = service
  }

  private func query(_ account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
    ]
  }

  public func data(_ account: String) throws -> Data? {
    var q = query(account)
    q[kSecReturnData] = true
    q[kSecMatchLimit] = kSecMatchLimitOne
    var ref: AnyObject?
    let status = SecItemCopyMatching(q as CFDictionary, &ref)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Self.error(status) }
    return ref as? Data
  }

  public func setData(_ account: String, _ value: Data) throws {
    let q = query(account)
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData: value] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw Self.error(status) }
    var add = q
    add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
    add[kSecValueData] = value
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw Self.error(added) }
  }

  public func remove(_ account: String) throws {
    let status = SecItemDelete(query(account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
  }

  /// What the Keychain said, as Session recognises a Keychain that refused (locked, its dialog cancelled).
  static func error(_ status: OSStatus) -> SecureStoreError {
    let text = SecCopyErrorMessageString(status, nil) as String? ?? "Unexpected security result code"
    return SecureStoreError(status: status, message: text)
  }
}
#endif
