import Foundation

/// Where an app keeps its preferences (UserDefaults, SharedPreferences, a settings file). The core reads
/// and writes plain keys through it; each app migrates Flutter's `flutter.<key>` entries once on first
/// launch and implements this over its native store.
public protocol PreferenceStore: AnyObject, Sendable {
  func string(_ key: String) -> String?
  func setString(_ key: String, _ value: String)
  func bool(_ key: String) -> Bool?
  func setBool(_ key: String, _ value: Bool)
  func int(_ key: String) -> Int?
  func setInt(_ key: String, _ value: Int)
  func stringList(_ key: String) -> [String]?
  func setStringList(_ key: String, _ value: [String])
  func contains(_ key: String) -> Bool
  func remove(_ key: String)
}

/// Where an app keeps secrets (the Keychain, Keystore-wrapped storage, a DPAPI file), by account name.
public protocol SecureStore: AnyObject, Sendable {
  func data(_ account: String) throws -> Data?
  func setData(_ account: String, _ value: Data) throws
  func remove(_ account: String) throws
}

/// Preferences in memory: tests, and a run that keeps nothing.
public final class MemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Any] = [:]

  public init() {}

  private func get<T>(_ key: String) -> T? {
    lock.lock()
    defer { lock.unlock() }
    return values[key] as? T
  }

  private func set(_ key: String, _ value: Any?) {
    lock.lock()
    defer { lock.unlock() }
    values[key] = value
  }

  public func string(_ key: String) -> String? { get(key) }
  public func setString(_ key: String, _ value: String) { set(key, value) }
  public func bool(_ key: String) -> Bool? { get(key) }
  public func setBool(_ key: String, _ value: Bool) { set(key, value) }
  public func int(_ key: String) -> Int? { get(key) }
  public func setInt(_ key: String, _ value: Int) { set(key, value) }
  public func stringList(_ key: String) -> [String]? { get(key) }
  public func setStringList(_ key: String, _ value: [String]) { set(key, value) }
  public func contains(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return values[key] != nil
  }
  public func remove(_ key: String) { set(key, nil) }
}

/// Secrets in memory: tests.
public final class MemorySecureStore: SecureStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  public init() {}

  public func data(_ account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[account]
  }

  public func setData(_ account: String, _ value: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    values[account] = value
  }

  public func remove(_ account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values[account] = nil
  }
}
