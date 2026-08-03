// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Prompt-free clipboard *type* probe (iOS).
///
/// Deciding whether to offer the composer's "Einfügen" entry only needs to know
/// **whether** an image is on the clipboard — not what it is. The portable way
/// to answer that (`SystemClipboard.read()`, see [clipboardHasPasteableMedia])
/// reads the *content*, which on iOS 16+ pops the paste transparency banner
/// ("Chattr möchte aus X einfügen") every single time the menu opens, even
/// though the user never asked to paste.
///
/// The native side ([ios/Runner/ClipboardProbeChannel.swift]) answers from
/// `UIPasteboard.hasImages`/`hasStrings`/`hasURLs`, which report type presence
/// only and never trigger the banner. The actual paste still reads content and
/// may prompt once — user-initiated, which is fine.
///
/// The channel is registered on iOS only. Everywhere else (Android, desktop,
/// web) the call raises [MissingPluginException] and [hasPasteableMedia]
/// returns `null`, meaning "no native answer — use the portable path". No
/// `dart:io` platform check is used, so this stays web-safe.
class ClipboardProbe {
  const ClipboardProbe._();

  @visibleForTesting
  static const MethodChannel channel =
      MethodChannel('net.geraldhofbauer.chattr/clipboard_probe');

  /// Latches false once the channel proves absent, so platforms without it pay
  /// the failed-invocation cost once instead of on every menu open.
  static bool _available = true;

  /// `true`/`false` when the native probe answered, `null` when there is no
  /// native probe on this platform and the caller should fall back.
  ///
  /// Only the *image* flag is consulted: the composer entry pastes media, so a
  /// clipboard holding plain text must NOT surface it (the authoritative read
  /// would find no media and we'd show a pointless "nothing to paste").
  static Future<bool?> hasPasteableMedia() async {
    if (!_available) return null;
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('probe');
      if (result == null) return null;
      return result['hasImage'] == true;
    } on MissingPluginException {
      _available = false;
      return null;
    } on PlatformException {
      // Native side failed — fall back rather than silently hiding the entry.
      return null;
    }
  }

  @visibleForTesting
  static void resetForTesting() => _available = true;
}
