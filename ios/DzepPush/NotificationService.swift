import CryptoKit
import UserNotifications

/// Turns a push into its real text. The relay (supabase/functions/relay) only
/// forwards ciphertext: the user's own server sealed {kind, title, body, id?}
/// with the key this iPhone registered (`DzepShared.pushKey`), AES-256-GCM in
/// CryptoKit's combined form. If anything is off, the relay's generic text
/// ("Reminder") shows instead; nothing private ever did.
final class NotificationService: UNNotificationServiceExtension {
  private struct Message: Decodable {
    let kind: String
    let title: String
    let body: String
    let id: String?
  }

  override func didReceive(
    _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    defer { contentHandler(content) }
    guard let enc = request.content.userInfo["enc"] as? String,
      let sealed = Data(base64Encoded: enc),
      let keyData = DzepShared.pushKey,
      let box = try? AES.GCM.SealedBox(combined: sealed),
      let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
      let message = try? JSONDecoder().decode(Message.self, from: plain)
    else { return }
    content.title = message.title
    content.body = message.body
    // What a tap or Done acts on (AppDelegate's Reminders).
    var info = content.userInfo
    info["kind"] = message.kind
    if let id = message.id { info["todo"] = id }
    content.userInfo = info
  }
}
