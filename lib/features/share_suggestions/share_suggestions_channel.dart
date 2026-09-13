// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../../core/logging/logger_service.dart';
import 'share_suggestion_avatar_cache.dart';

/// One recipient in a Share-Suggestions donation: a stable user [id] and a
/// display name. [avatarPath] is a readable LOCAL file path for the native side
/// to load as an `INImage` (iOS) / adaptive icon (Android) — the OS draws the
/// suggestion row itself and cannot fetch a URL, so
/// [ShareSuggestionAvatarCache] puts the picture on disk first. Null when the
/// user has no picture, or when caching it failed; the suggestion is then
/// name-only, as it was before.
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

/// Bridge to the native Share-Suggestions donation, so recent Chattr
/// conversations surface in the system share sheet's people row. Toggleable in
/// settings (**on by default**; see `shareSuggestionsEnabledProvider`);
/// **no message content** is ever donated — only recipient metadata (name +
/// stable ids).
///
/// **One channel, two mechanisms.** iOS donates an `INSendMessageIntent`
/// interaction (`ios/Runner/ShareSuggestionsChannel.swift`); Android publishes a
/// long-lived conversation shortcut matched by a `<share-target>`
/// (`android/.../ShareSuggestionsChannel.kt`). Nothing about that difference
/// reaches Dart — both sides answer the same three methods, so callers stay
/// platform-blind.
///
/// Android deliberately does **not** use `share_handler.recordSentMessage`:
/// that API can publish a shortcut but not withdraw one, which would leave chat
/// partners' names on the device after a logout. [deleteAll] and
/// [deleteConversations] are the reason this bridge is hand-written.
///
/// Every method no-ops off iOS/Android (gated on [defaultTargetPlatform]) and
/// swallows a [MissingPluginException] when the native handler isn't in the
/// build — a donation is best-effort and must never break a send / logout /
/// delete. Uses `defaultTargetPlatform` (not `dart:io`) so the file stays
/// web-safe.
class ShareSuggestionsChannel {
  const ShareSuggestionsChannel._();

  static const MethodChannel _method =
      MethodChannel('net.geraldhofbauer.chattr/share_suggestions');

  /// True where a native handler exists. Kept public so the settings tile shows
  /// the toggle on exactly the platforms that can act on it, instead of
  /// repeating the platform list and drifting from it.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  static bool get _supported => isSupported;

  /// Donate a conversation (recency), so it ranks in the share-sheet suggestion
  /// row. No message content is passed. Called on send AND on opening a chat
  /// with unread messages — the method name kept `Send` because that is the
  /// iOS intent type (`INSendMessageIntent`), not the trigger.
  ///
  /// [conversationImagePath] is the GROUP's own picture as a local file. A 1:1
  /// has none — there the picture is the other person's, which rides along on
  /// their [ShareRecipient]. Added after both native sides shipped, so a build
  /// whose native half predates it simply ignores the extra key.
  static Future<void> donateSend({
    required String conversationId,
    String? conversationName,
    required bool isGroup,
    required List<ShareRecipient> recipients,
    String? conversationImagePath,
  }) =>
      _invoke('donateSend', {
        'conversationId': conversationId,
        'conversationName': conversationName,
        'isGroup': isGroup,
        'recipients': recipients.map((r) => r.toMap()).toList(),
        'conversationImagePath': ?conversationImagePath,
      });

  /// Wipe every donation — on logout, and when the user turns the setting off.
  ///
  /// Also drops the cached avatar files: once the donations are gone, the
  /// pictures that fed them are exactly the trace the deletion was meant to
  /// remove.
  static Future<void> deleteAll() async {
    await _invoke('deleteAll', null);
    await ShareSuggestionAvatarCache.clear();
  }

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
