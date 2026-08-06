// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/services.dart';

/// Mirror the push-render cache into the iOS **App Group** container, so the
/// Notification Service Extension can read it.
///
/// **Why a second copy at all.** The extension is its own process. It cannot see
/// the app's normal `NSUserDefaults` — only the suite shared through the App
/// Group `group.net.geraldhofbauer.chattr` (which already exists for the Share
/// Extension). Same shape of problem as the web service worker, which is why
/// that one gets its own IndexedDB mirror: whoever renders the notification must
/// be able to reach the names.
///
/// **Contract with the native side** (`PushCacheChannel.swift`, Mac-Claude):
/// one method `mirror`, two arguments, both JSON strings — `names` is
/// `{id: displayName}` for chats AND users, `templates` is the localized
/// wording. The extension reads them back from
/// `UserDefaults(suiteName:)` under the same two keys.
///
/// Best-effort throughout: until the channel exists this throws
/// `MissingPluginException`, which is caught here. The cost of a missing mirror
/// is a generic notification, never a missing one — and never a broken chat
/// list, which is what an exception escaping into the caller would risk.
const MethodChannel _channel =
    MethodChannel('net.geraldhofbauer.chattr/push_cache');

/// Key the extension reads the name table from.
const String pushCacheNamesKey = 'push_render_names';

/// Key the extension reads the localized wording from.
const String pushCacheTemplatesKey = 'push_render_templates';

Future<void> mirrorPushCacheForAppGroup({
  required Map<String, String> names,
  required Map<String, String> templates,
}) async {
  try {
    await _channel.invokeMethod<void>('mirror', {
      pushCacheNamesKey: jsonEncode(names),
      pushCacheTemplatesKey: jsonEncode(templates),
    });
  } on MissingPluginException {
    // The native channel is not in this build yet. Expected until the
    // Notification Service Extension ships; nothing to report.
  } catch (_) {
    // Deliberately swallowed — see the doc comment.
  }
}
