// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../../core/logging/logger_service.dart';

/// One recipient in a Share-Suggestions donation: a stable user [id] and a
/// display name. [avatarPath] is a readable LOCAL file path for the native side
/// to load as an `INImage` — currently always null (Chattr avatars are network
/// URLs with no on-disk cache), so suggestions are name-only for now.
class ShareRecipient {
  final String id;
  final String displayName;
  final String? avatarPath;

  const ShareRecipient({
    required this.id,
    required this.displayName,
    this.avatarPath,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'displayName': displayName,
        if (avatarPath != null) 'avatarPath': avatarPath,
      };
}

/// Bridge to the native iOS Share-Suggestions donation (`INSendMessageIntent` /
/// `INInteraction`), so recent Chattr conversations surface in the system
/// share-sheet suggestion row. Toggleable in settings (**on by default**; see
/// `shareSuggestionsEnabledProvider`) and **iOS-only**; **no message content** is
/// ever donated — only recipient metadata (name + stable ids).
///
/// Every method no-ops off iOS (gated on [defaultTargetPlatform]) and swallows a
/// [MissingPluginException] when the native handler isn't in the build — a
/// donation is best-effort and must never break a send / logout / delete. Uses
/// `defaultTargetPlatform` (not `dart:io`) so the file stays web-safe.
class ShareSuggestionsChannel {
  const ShareSuggestionsChannel._();

  static const MethodChannel _method =
      MethodChannel('net.geraldhofbauer.chattr/share_suggestions');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Donate a conversation on send (recency), so it ranks in the share-sheet
  /// suggestion row. No message content is passed.
  static Future<void> donateSend({
    required String conversationId,
    String? conversationName,
    required bool isGroup,
    required List<ShareRecipient> recipients,
  }) =>
      _invoke('donateSend', {
        'conversationId': conversationId,
        'conversationName': conversationName,
        'isGroup': isGroup,
        'recipients': recipients.map((r) => r.toMap()).toList(),
      });

  /// Wipe every donation — on logout, and when the user turns the setting off.
  static Future<void> deleteAll() => _invoke('deleteAll', null);

  /// Drop donations for the given conversations (chat deleted / user blocked).
  static Future<void> deleteConversations(List<String> conversationIds) =>
      _invoke('deleteConversations', {'conversationIds': conversationIds});

  static Future<void> _invoke(String method, Map<String, dynamic>? args) async {
    if (!_supported) return;
    try {
      await _method.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Native handler not in this build yet — best-effort, ignore.
    } on PlatformException catch (e) {
      logger.warning('share_suggestions.$method failed: ${e.code}',
          tag: 'ShareSuggestions');
    }
  }
}
