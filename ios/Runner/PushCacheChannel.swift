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
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
