import UserNotifications

/// Turns a push into its real text. The relay (apps/pocketterm-relay) only
/// forwards ciphertext: a computer sealed {title, body, session?, state?, ts,
/// id} with its channel key, AES-256-GCM in CryptoKit's combined form, AAD
/// "pocketterm/v1|push|<computer id>". The push names that computer only by
/// its tag `t` (`PocketTermShared.pushTag`), which this iPhone matches against
/// the keys it holds. A computer whose code this iPhone never scanned,
/// anything else off, or a notice that is old or seen before
/// (`PocketTermShared.isFreshPush`: held back and sent again) keeps the
/// relay's generic "PocketTerm" alert; nothing private ever shows.
final class NotificationService: UNNotificationServiceExtension {
  private struct Message: Decodable {
    let title: String
    let body: String
    /// The coding session (its routed key) a tap opens.
    let session: String?
    /// When the computer sealed it, in ms since 1970.
    let ts: Double?
    /// Unique per notice.
    let id: String?
  }

  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    defer { contentHandler(content) }
    guard let enc = request.content.userInfo["enc"] as? String,
      let tag = request.content.userInfo["t"] as? String,
      let sealed = Data(base64Encoded: enc),
      let computer = PocketTermShared.computer(tagged: tag, in: PocketTermShared.channelKeys()),
      let plain = PocketTermShared.open(sealed, key: computer.key, aad: "pocketterm/v1|push|\(computer.desktop)"),
      let message = try? JSONDecoder().decode(Message.self, from: plain),
      PocketTermShared.isFreshPush(ts: message.ts, id: message.id)
    else { return }
    content.title = message.title
    content.body = message.body
    // What a tap opens (AppDelegate's Notifications).
    var info = content.userInfo
    info["kind"] = "terminal"
    if let session = message.session { info["session"] = session }
    content.userInfo = info
  }
}
