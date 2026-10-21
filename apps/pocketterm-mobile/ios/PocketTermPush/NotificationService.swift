import UserNotifications

/// Turns a push into its real text. The relay (supabase/functions/relay) only
/// forwards ciphertext: the computer `d` sealed {title, body, session?, state?}
/// with its channel key (`PocketTermShared.channelKey`), AES-256-GCM in
/// CryptoKit's combined form, AAD "pocketterm/v1|push|<d>". A computer whose
/// code this iPhone never scanned, or anything else off, keeps the relay's
/// generic "PocketTerm" alert; nothing private ever shows.
final class NotificationService: UNNotificationServiceExtension {
  private struct Message: Decodable {
    let title: String
    let body: String
    /// The coding session (its routed key) a tap opens.
    let session: String?
  }

  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    defer { contentHandler(content) }
    guard let enc = request.content.userInfo["enc"] as? String,
      let desktop = request.content.userInfo["d"] as? String,
      let sealed = Data(base64Encoded: enc),
      let key = PocketTermShared.channelKey(for: desktop),
      let plain = PocketTermShared.open(sealed, key: key, aad: "pocketterm/v1|push|\(desktop)"),
      let message = try? JSONDecoder().decode(Message.self, from: plain)
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
