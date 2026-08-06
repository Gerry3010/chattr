// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import UserNotifications

/// "Push ohne Klartext" (Stufe 2) — the iOS renderer.
///
/// The server sends a device with `local_render = true` only ids
/// (`{type, chat_id, message_id, sender_id, media_kind?}`) plus a full-sentence
/// placeholder (`"Chattr" / "Neue Nachricht"`) and `mutable-content: 1`. This
/// extension turns the ids back into readable text using the name table and the
/// localized templates the app mirrors into the App Group
/// (`group.net.geraldhofbauer.chattr`) via `PushCacheChannel`.
///
/// The rendering MUST stay character-identical to the two sibling
/// implementations — `lib/features/push_notifications/push_local_renderer.dart`
/// (Dart, the reference) and `renderPush()` in `web/firebase-messaging-sw.js`
/// (JS). Same fallbacks, same "unknown sender gets its own sentence", same media
/// mapping. The one deliberate platform difference: an unknown `type` returns
/// nil here, and — unlike Android/Web which show nothing — iOS keeps the
/// server's placeholder, because a Notification Service Extension can modify a
/// notification but cannot suppress one that carries an alert.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttempt: UNMutableNotificationContent?

  private static let appGroupId = "group.net.geraldhofbauer.chattr"
  private static let namesKey = "push_render_names"
  private static let templatesKey = "push_render_templates"

  /// English defaults, mirroring `PushTemplates.fallback` (Dart) and
  /// `FALLBACK_TEMPLATES` (JS). Used per-key when the cached templates lack one,
  /// exactly like the sibling `t()` helpers.
  private static let fallback: [String: String] = [
    "new_message": "New message from {user}",
    "new_message_unknown": "New message",
    "new_message_image": "{user} sent a photo",
    "new_message_video": "{user} sent a video",
    "new_message_audio": "{user} sent an audio file",
    "new_message_file": "{user} sent a file",
    "reaction": "{user} reacted to your message",
    "reaction_unknown": "Someone reacted to your message",
    "member_request_title": "New join request",
    "member_request_body": "{user} wants to join {chat}",
    "chat_fallback": "Chattr",
    "someone": "Someone",
  ]

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
    self.bestAttempt = mutable

    guard let content = mutable else {
      contentHandler(request.content)
      return
    }

    let data = request.content.userInfo
    let defaults = UserDefaults(suiteName: Self.appGroupId)
    let names = Self.decodeMap(defaults?.string(forKey: Self.namesKey))
    let templates = Self.decodeMap(defaults?.string(forKey: Self.templatesKey))

    if let rendered = Self.render(data: data, names: names, templates: templates) {
      content.title = rendered.title
      content.body = rendered.body
    }
    // rendered == nil → unknown type: keep the server placeholder (iOS cannot
    // suppress an alert-carrying notification from an NSE).

    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    // Ran out of time before rendering — deliver the placeholder as-is. A full
    // sentence ("Neue Nachricht") is why the server never sends an empty one.
    if let handler = contentHandler, let content = bestAttempt {
      handler(content)
    }
  }

  // MARK: - Rendering (mirror of push_local_renderer.dart)

  private struct Rendered {
    let title: String
    let body: String
  }

  /// Turns the id-only payload back into title + body. Returns nil for an
  /// unknown type (server ahead of this build).
  private static func render(
    data: [AnyHashable: Any],
    names: [String: String],
    templates: [String: String]
  ) -> Rendered? {
    // Non-empty string or nil — mirrors the Dart/JS `str()` helper.
    func str(_ key: String) -> String? {
      if let value = data[key] as? String, !value.isEmpty { return value }
      return nil
    }
    // Cached template for a key, else the English fallback — mirrors `t()`.
    func tmpl(_ key: String) -> String {
      if let value = templates[key], !value.isEmpty { return value }
      return fallback[key] ?? ""
    }
    func fill(_ template: String, user: String? = nil, chat: String? = nil) -> String {
      var out = template
      if let user = user { out = out.replacingOccurrences(of: "{user}", with: user) }
      if let chat = chat { out = out.replacingOccurrences(of: "{chat}", with: chat) }
      return out
    }
    // A cached name that is present AND non-empty, else nil. The name table is a
    // mix of sources and can hold an empty string; treating "" as absent keeps
    // an empty entry from producing a blank title or a leading-space body — the
    // same fix Dart/JS carry (an empty entry must fall back, never render bare).
    func named(_ id: String?) -> String? {
      guard let id = id, let value = names[id], !value.isEmpty else { return nil }
      return value
    }
    // names[id] or the localized "Someone" — mirrors `nameOf()`.
    func nameOf(_ id: String?) -> String {
      return named(id) ?? tmpl("someone")
    }

    let chatId = str("chat_id")
    let chatName = named(chatId)

    switch str("type") {
    case "new_message":
      let sender = named(str("sender_id"))
      // media_kind present only when the server had a category AND this
      // recipient allows it (00067). Any unknown/absent value → plain wording.
      let mediaKey: String?
      switch str("media_kind") {
      case "image": mediaKey = "new_message_image"
      case "video": mediaKey = "new_message_video"
      case "audio": mediaKey = "new_message_audio"
      case "other": mediaKey = "new_message_file"
      default: mediaKey = nil
      }
      let body: String
      if let sender = sender {
        body = fill(tmpl(mediaKey ?? "new_message"), user: sender)
      } else {
        // Naming an unknown sender "Someone" reads worse than not naming one —
        // its own sentence, generic even for media.
        body = tmpl("new_message_unknown")
      }
      return Rendered(title: chatName ?? tmpl("chat_fallback"), body: body)

    case "reaction":
      let sender = named(str("sender_id"))
      let body: String
      if let sender = sender {
        body = fill(tmpl("reaction"), user: sender)
      } else {
        body = tmpl("reaction_unknown")
      }
      return Rendered(title: chatName ?? tmpl("chat_fallback"), body: body)

    case "member_request":
      return Rendered(
        title: tmpl("member_request_title"),
        body: fill(
          tmpl("member_request_body"),
          user: nameOf(str("requester_id")),
          chat: chatName ?? tmpl("chat_fallback")
        )
      )

    default:
      return nil
    }
  }

  /// Tolerant JSON-object → [String:String]. Empty on any problem, so a corrupt
  /// or half-written cache degrades to the generic notification, never a crash.
  private static func decodeMap(_ raw: String?) -> [String: String] {
    guard let raw = raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [:] }
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    var out: [String: String] = [:]
    for (key, value) in obj {
      if let value = value as? String { out[key] = value }
    }
    return out
  }
}
