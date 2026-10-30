// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Flutter
import UIKit

/// Mirrors the push-render cache into the App Group container so the
/// Notification Service Extension (a separate process) can turn an id-only
/// push back into readable text — "Push ohne Klartext", Stufe 2.
///
/// The extension cannot see the app's normal `UserDefaults`; it only shares the
/// suite named by the App Group `group.net.geraldhofbauer.chattr` (which already
/// exists for the Share Extension). The Dart side
/// (`push_cache_bridge_ios.dart`) calls `mirror` with two JSON strings — the
/// name table and the localized templates — and this writes them verbatim under
/// the same two keys the extension reads back.
///
/// We store the JSON strings as-is (no re-encoding): the extension parses them,
/// and keeping them opaque here means the two sides never disagree on shape.
/// Registration is additive; the Dart side swallows `MissingPluginException`
/// where this channel is absent.
enum PushCacheChannel {
  static let channelName = "net.geraldhofbauer.chattr/push_cache"
  static let appGroupId = "group.net.geraldhofbauer.chattr"

  /// Must match `PushRenderCache.namesKey` / `.templatesKey` (Dart) and the keys
  /// the Notification Service Extension reads.
  static let namesKey = "push_render_names"
  static let templatesKey = "push_render_templates"

  /// The device's exact local unread total, republished by the app on every
  /// change (`mirrorUnreadTotalForAppGroup`, Dart). The Notification Service
  /// Extension reads this as the BASE it adds delivered pushes onto — see
  /// `NotificationService.swift`. Must match `pushUnreadTotalKey` (Dart).
  static let unreadTotalKey = "push_unread_total"

  /// Sender ids the user marked as important, published over the same `mirror`
  /// call (`mirrorImportantSendersForAppGroup`, Dart). A JSON array of UUID
  /// strings; the Notification Service Extension reads it to raise those
  /// senders' pushes to time-sensitive. Must match `pushImportantSendersKey`
  /// (Dart) and `importantSendersKey` (NotificationService.swift).
  static let importantSendersKey = "push_important_senders"

  /// "List Chattr calls in the Phone app's Recents" (CHAT-38), a Bool set from
  /// the settings (`mirrorCallsInRecentsForAppGroup`, Dart). AppDelegate reads
  /// it when it reports a VoIP push to CallKit; absent means listed. Must match
  /// `pushCallsInRecentsKey` (Dart).
  static let callsInRecentsKey = "calls_in_recents"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "mirror":
        guard
          let args = call.arguments as? [String: Any],
          let defaults = UserDefaults(suiteName: appGroupId)
        else {
          result(FlutterError(code: "bad_args",
                              message: "args + app-group suite required",
                              details: nil))
          return
        }
        // Both values arrive already JSON-encoded from Dart. Missing/nil keys
        // are left untouched rather than cleared — a partial call must not wipe
        // a cache the extension still needs.
        if let names = args[namesKey] as? String {
          defaults.set(names, forKey: namesKey)
        }
        if let templates = args[templatesKey] as? String {
          defaults.set(templates, forKey: templatesKey)
        }
        if let important = args[importantSendersKey] as? String {
          defaults.set(important, forKey: importantSendersKey)
        }
        if let inRecents = args[callsInRecentsKey] as? Bool {
          defaults.set(inRecents, forKey: callsInRecentsKey)
        }
        result(true)
      case "clear":
        // Logout/wipe (CHAT-38): the name table is a plaintext social graph and
        // must not outlive the account. Device settings (callsInRecentsKey) stay.
        guard let defaults = UserDefaults(suiteName: appGroupId) else {
          result(FlutterError(code: "bad_args",
                              message: "app-group suite required",
                              details: nil))
          return
        }
        for key in [namesKey, templatesKey, importantSendersKey, unreadTotalKey] {
          defaults.removeObject(forKey: key)
        }
        result(true)
      case "unreadTotal":
        guard
          let args = call.arguments as? [String: Any],
          let total = args[unreadTotalKey] as? Int,
          let defaults = UserDefaults(suiteName: appGroupId)
        else {
          result(FlutterError(code: "bad_args",
                              message: "unread total (Int) + app-group suite required",
                              details: nil))
          return
        }
        // Publish the exact base the extension adds its deliveries onto. The
        // Dart side already clamps, but a negative badge is nonsense either way.
        defaults.set(max(0, total), forKey: unreadTotalKey)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
