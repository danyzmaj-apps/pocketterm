import CryptoKit
import Foundation

// End-to-end encryption between a computer and its phones (docs/ARCHITECTURE.md,
// SECURITY.md). Each computer has one channel key, made on the computer and
// handed to a phone only in its QR code; the server relays what it seals and
// can't read it. Sealed bytes are nonce (12) || ciphertext || tag (16),
// AES-256-GCM, with additional data naming what they are, so a message can't
// be moved to another computer, event, image or push.

/// A computer (its id, Desktops.swift) and its channel key, as the computer's QR code hands them to a phone.
public struct ComputerKey: Sendable, Hashable {
  public let desktop: String
  public let key: ChannelKey
  public init(desktop: String, key: ChannelKey) {
    self.desktop = desktop
    self.key = key
  }
}

/// One computer's channel key: 32 random bytes.
public struct ChannelKey: Sendable, Hashable, CustomStringConvertible {
  public static let length = 32

  public let bytes: Data

  /// [bytes] must be [length] long.
  public init?(_ bytes: Data) {
    guard bytes.count == Self.length else { return nil }
    self.bytes = Data(bytes)
  }

  /// A new random key.
  public static func generate() -> ChannelKey {
    ChannelKey(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })!
  }

  /// A key as [toBase64] or [toBase64Url] write it, with or without padding; nil when it isn't one.
  public static func tryParse(_ text: String?) -> ChannelKey? {
    guard let text, let bytes = base64UrlDecodeLenient(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return nil
    }
    return ChannelKey(bytes)
  }

  /// Standard base64 with padding: how the phone's native side keeps it.
  public func toBase64() -> String { bytes.base64EncodedString() }

  /// URL-safe base64 without padding: how a setup link carries it.
  public func toBase64Url() -> String { base64UrlEncode(bytes, padding: false) }

  var symmetric: SymmetricKey { SymmetricKey(data: bytes) }

  public var description: String { "ChannelKey(…)" }
}

/// [data] in base64url, with or without `=` padding.
public func base64UrlEncode(_ data: Data, padding: Bool = true) -> String {
  var s = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
  if !padding { s = s.replacingOccurrences(of: "=", with: "") }
  return s
}

/// Either base64 alphabet, padding optional (Dart's `base64Url.decode(base64Url.normalize(…))`);
/// nil when it isn't base64.
func base64UrlDecodeLenient(_ text: String) -> Data? {
  var s = text.replacingOccurrences(of: "%3D", with: "=").replacingOccurrences(of: "%3d", with: "=")
  s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  let body = Substring(s)
  let pad = body.reversed().prefix(while: { $0 == "=" }).count
  let core = body.dropLast(pad)
  guard !core.contains("="), pad <= 2 else { return nil }
  if pad > 0, s.count % 4 != 0 { return nil }
  if core.count % 4 == 1 { return nil }
  let padded = String(core) + String(repeating: "=", count: (4 - core.count % 4) % 4)
  return Data(base64Encoded: padded)
}

/// Dart's `base64Decode`: either alphabet, padding optional ([base64UrlDecodeLenient]).
public func base64DecodeLenient(_ text: String) -> Data? { base64UrlDecodeLenient(text) }

/// The additional data of a live channel [event] on [topic].
public func channelAad(_ topic: String, _ event: String) -> String { "pocketterm/v1|\(topic)|\(event)" }

/// The additional data of an image, or a file a prompt takes, stored at [path] (the same for both: the
/// file's name and type travel in the sealed prompt).
public func imageAad(_ path: String) -> String { "pocketterm/v1|image|\(path)" }

/// The additional data of a push from computer [desktopId].
public func pushAad(_ desktopId: String) -> String { "pocketterm/v1|push|\(desktopId)" }

/// The additional data of a followed session's update (Android) from computer [desktopId].
public func activityAad(_ desktopId: String) -> String { "pocketterm/v1|activity|\(desktopId)" }

/// What a push says about the computer that sealed it, instead of its id: the first 8 bytes of
/// HMAC-SHA256([key], `pocketterm/v1|push-tag`) in base64url without padding (11 characters). The same
/// for every push from that computer and meaningless without its key: the phone finds the key whose tag
/// it is, the relay and the push services can't tell which computer it is.
public func pushTag(_ key: ChannelKey) -> String { tag(key, "pocketterm/v1|push-tag", 8) }

/// What a push says about coding session [routedKey] (`<desktop id>/<key>`): the first 16 bytes of
/// HMAC-SHA256([key], `pocketterm/v1|push-session|<routedKey>`) in base64url without padding (22
/// characters). It lets a newer push for the session replace an older one (collapse id) and, on Android,
/// names the session a plain end is for, without telling anyone on the way which session it is.
public func sessionTag(_ key: ChannelKey, _ routedKey: String) -> String {
  tag(key, "pocketterm/v1|push-session|\(routedKey)", 16)
}

private func tag(_ key: ChannelKey, _ what: String, _ length: Int) -> String {
  let mac = HMAC<SHA256>.authenticationCode(for: Data(what.utf8), using: key.symmetric)
  return base64UrlEncode(Data(mac).prefix(length), padding: false)
}

/// HMAC-SHA256 of [message] with [key], in lowercase hex.
public func hmacSha256Hex(key: Data, message: Data) -> String {
  Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))).map { String(format: "%02x", $0) }
    .joined()
}

/// The local API's answer to GET /v1/ping?nonce=N (the computer apps' LocalApi): HMAC-SHA256 with the
/// UTF-8 [token] as key over `pocketterm-ping\n<port>\n<nonce>`, lowercase hex. It proves to an extension
/// that the app on [port] holds its token without sending the token.
public func pingProof(token: String, port: Int, nonce: String) -> String {
  hmacSha256Hex(key: Data(token.utf8), message: Data("pocketterm-ping\n\(port)\n\(nonce)".utf8))
}

/// Whether the local API takes [nonce] for a ping: 16 to 128 characters (else HTTP 400).
public func pingNonceAccepted(_ nonce: String) -> Bool { (16...128).contains(nonce.utf16.count) }

let nonceLength = 12
let tagLength = 16

/// What sealing adds to the bytes: the nonce and the tag.
public let sealedOverhead = nonceLength + tagLength

/// [plain] sealed with [key] for [aad]: nonce || ciphertext || tag. [nonce] is for tests only.
public func sealBytes(_ key: ChannelKey, _ plain: Data, _ aad: String, nonce: Data? = nil) -> Data {
  let n = try! nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
  // Sealing can't fail with a 32-byte key and a 12-byte nonce.
  let box = try! AES.GCM.seal(plain, using: key.symmetric, nonce: n, authenticating: Data(aad.utf8))
  return box.combined!
}

/// What [sealed] holds, or nil when it wasn't sealed with [key] for [aad] (another key, another purpose,
/// changed on the way, too short).
public func openBytes(_ key: ChannelKey, _ sealed: Data, _ aad: String) -> Data? {
  guard sealed.count >= sealedOverhead else { return nil }
  guard let box = try? AES.GCM.SealedBox(combined: Data(sealed)) else { return nil }
  return try? AES.GCM.open(box, using: key.symmetric, authenticating: Data(aad.utf8))
}

/// The version an envelope's `v` says.
public let envelopeVersion = 1

/// [message] as it goes on the live channel: `{"v":1,"n":"<base64 nonce>","c":"<base64 ciphertext and tag>"}`.
public func sealEnvelope(_ key: ChannelKey, _ message: JSONObject, _ aad: String) -> JSONObject {
  let sealed = sealBytes(key, message.encoded().data(using: .utf8)!, aad)
  return [
    "v": .int(envelopeVersion),
    "n": .string(sealed.prefix(nonceLength).base64EncodedString()),
    "c": .string(sealed.dropFirst(nonceLength).base64EncodedString()),
  ]
}

/// The message in an envelope, or why it was dropped.
public struct OpenedEnvelope: Sendable {
  public let message: JSONObject?
  /// `version` (not one this reads), `sealed` (not sealed with the key for the AAD), `json` (not a JSON
  /// object inside); nil when it opened.
  public let drop: String?
}

/// The message in [envelope], or why it was dropped: `version`, `sealed` or `json`.
public func openEnvelope(_ key: ChannelKey, _ envelope: JSONObject, _ aad: String) -> OpenedEnvelope {
  guard envelope["v"] == .int(envelopeVersion) else { return .init(message: nil, drop: "version") }
  guard let n = envelope["n"]?.string, let c = envelope["c"]?.string else { return .init(message: nil, drop: "sealed") }
  guard let nonce = base64DecodeLenient(n), let rest = base64DecodeLenient(c) else {
    return .init(message: nil, drop: "sealed")
  }
  guard nonce.count == nonceLength, let plain = openBytes(key, nonce + rest, aad) else {
    return .init(message: nil, drop: "sealed")
  }
  guard let text = String(data: plain, encoding: .utf8), let message = JSON.tryParse(text)?.object else {
    return .init(message: nil, drop: "json")
  }
  return .init(message: message, drop: nil)
}

/// A new message id: 16 random URL-safe characters.
public func newMessageId() -> String {
  var bytes = Data(count: 12)
  bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 12, $0.baseAddress!) }
  return base64UrlEncode(bytes)
}

/// Milliseconds since the epoch, as Dart's `DateTime.millisecondsSinceEpoch`.
public func millisecondsSinceEpoch(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded(.down)) }

/// The date [ms] milliseconds after the epoch.
public func dateFromMilliseconds(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

/// Drops opened live channel messages that are stale, seen before or out of order. Every message carries
/// `ts` (ms since epoch), `mid` (a random id), `ep` (its sender's epoch: random, new each time a sender
/// starts) and `seq` (that sender's count, from 1). Dropped: a `ts` more than [window] off this clock or
/// before [notBefore] (sent before this guard existed, so before this app started: nothing here remembers
/// it), a `mid` seen in the last [remember], and a `seq` at or below the last one taken for its `ep`.
/// Memory stays bounded: epochs and ids go after [remember] unseen, and past [maxEpochs] / [maxIds] the
/// oldest go first (a message that old is out of [window] by then anyway, or caught by the other check).
public final class ReplayGuard: @unchecked Sendable {
  /// [window] and [remember] in seconds.
  public init(
    window: TimeInterval = 5 * 60,
    remember: TimeInterval = 10 * 60,
    maxEpochs: Int = 64,
    maxIds: Int = 10000,
    clock: (@Sendable () -> Date)? = nil
  ) {
    self.window = window
    self.remember = remember
    self.maxEpochs = maxEpochs
    self.maxIds = maxIds
    self.clock = clock ?? { Date() }
    notBefore = self.clock()
  }

  /// One guard per computer ([topic], its id) for this whole run of the app: it outlives each channel,
  /// so a channel made again (the bridge restarted, another sign-in) still knows what it took.
  public static func of(_ topic: String) -> ReplayGuard {
    registryLock.lock()
    defer { registryLock.unlock() }
    if let g = byTopic[topic] { return g }
    let g = ReplayGuard()
    byTopic[topic] = g
    return g
  }
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var byTopic: [String: ReplayGuard] = [:]

  public let window: TimeInterval

  /// How long an id or an epoch is kept after it was last seen; at least twice [window], so a message
  /// taken once can't come back in time.
  public let remember: TimeInterval
  public let maxEpochs: Int
  public let maxIds: Int

  /// When this guard started: messages from before it are dropped.
  public let notBefore: Date
  private let clock: @Sendable () -> Date
  private let lock = NSLock()

  // Both in the order last seen, oldest first.
  private var ids = OrderedMap<String, Int>()
  private var epochs = OrderedMap<String, (seq: Int, at: Int)>()

  /// Nil when [message] may go on (and it is remembered), else why not: `time`, `replay` or `order`.
  public func check(_ message: JSONObject) -> String? {
    lock.lock()
    defer { lock.unlock() }
    let now = millisecondsSinceEpoch(clock())
    let windowMs = Int(window * 1000)
    let rememberMs = Int(remember * 1000)
    guard let ts = message["ts"]?.int, abs(now - ts) <= windowMs, ts >= millisecondsSinceEpoch(notBefore) else {
      return "time"
    }
    guard let mid = message["mid"]?.string, !mid.isEmpty, let ep = message["ep"]?.string, !ep.isEmpty,
      let seq = message["seq"]?.int, seq >= 1
    else { return "replay" }
    ids.removeAll { now - $0 > rememberMs }
    epochs.removeAll { now - $0.at > rememberMs }
    if ids[mid] != nil { return "replay" }
    let last = epochs.remove(ep)
    if let last, seq <= last.seq {
      epochs[ep] = last
      return "order"
    }
    epochs[ep] = (seq: seq, at: now)
    ids[mid] = now
    while epochs.count > maxEpochs { epochs.removeFirst() }
    while ids.count > maxIds { ids.removeFirst() }
    return nil
  }
}

/// A dictionary that remembers insertion order, as Dart's maps do: a key set again keeps its place, one
/// removed and set again goes last.
struct OrderedMap<Key: Hashable, Value> {
  private(set) var keys: [Key] = []
  private var values: [Key: Value] = [:]

  var count: Int { keys.count }
  var isEmpty: Bool { keys.isEmpty }

  subscript(key: Key) -> Value? {
    get { values[key] }
    set {
      if let newValue {
        if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
      } else {
        remove(key)
      }
    }
  }

  @discardableResult
  mutating func remove(_ key: Key) -> Value? {
    guard let v = values.removeValue(forKey: key) else { return nil }
    keys.removeAll { $0 == key }
    return v
  }

  mutating func removeFirst() {
    guard let k = keys.first else { return }
    keys.removeFirst()
    values.removeValue(forKey: k)
  }

  mutating func removeAll(where drop: (Value) -> Bool) {
    keys.removeAll { k in
      if drop(values[k]!) {
        values.removeValue(forKey: k)
        return true
      }
      return false
    }
  }

  var orderedValues: [Value] { keys.map { values[$0]! } }
  var entries: [(key: Key, value: Value)] { keys.map { ($0, values[$0]!) } }
}

/// A push [notice] (`{title, body, session?, state?}`) from computer [desktopId], sealed with its [key]
/// for the phones (AAD [pushAad]), in base64: the `enc` the server forwards. Inside it gains `ts` (ms
/// since epoch) and `id` (random), so a phone can refuse an old or repeated one.
public func sealNotice(_ key: ChannelKey, _ desktopId: String, _ notice: JSONObject) -> String {
  sealPush(key, notice, pushAad(desktopId))
}

/// A followed session's [activity] (`{session, state, since, kind?}`) from computer [desktopId] for
/// Android phones, sealed like [sealNotice] (also with `ts` and `id` inside) but for [activityAad].
public func sealActivity(_ key: ChannelKey, _ desktopId: String, _ activity: JSONObject) -> String {
  sealPush(key, activity, activityAad(desktopId))
}

private func sealPush(_ key: ChannelKey, _ body: JSONObject, _ aad: String) -> String {
  var b = body
  b["ts"] = .int(millisecondsSinceEpoch(Date()))
  b["id"] = .string(newMessageId())
  return sealBytes(key, Data(b.encoded().utf8), aad).base64EncodedString()
}
