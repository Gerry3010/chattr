// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

import 'package:shared_preferences/shared_preferences.dart';

import 'push_cache_bridge_ios.dart';
import 'push_cache_bridge_stub.dart'
    if (dart.library.js_interop) 'push_cache_bridge_web.dart';

/// What a locally-rendered push needs to become readable text.
///
/// Since "Push ohne Klartext" (migration 00065) the server sends only ids —
/// `{type, chat_id, message_id, sender_id}` — so neither the chat name nor the
/// sender's username travels through Google. The device turns those ids back
/// into words, and this is where it keeps the material to do it.
///
/// **Why a cache and not the real database.** The renderer runs in Flutter's
/// background isolate, woken by FCM while the app is not running. That isolate
/// has no Riverpod container, no `AppInit`, and — the part that actually
/// decides it — no `EasyLocalization`, so it cannot even look up the word
/// "Neue Nachricht". Opening the app's SQLite from there would mean bringing up
/// the whole database stack for one string, on a wakeup that Android gives us a
/// few seconds for. SharedPreferences is available to a background isolate with
/// nothing but `DartPluginRegistrant.ensureInitialized()`.
///
/// So the foreground app writes what the isolate will need — names by id, and
/// the *localized* templates to put them in — and the isolate only substitutes.
/// A stale or missing entry is not a failure: the renderer falls back to a
/// generic wording, which is exactly what the notification used to say for
/// everyone anyway.
class PushRenderCache {
  const PushRenderCache._();

  /// `{id: displayName}` for chats AND users in one map. Both are UUIDs, so
  /// they cannot collide, and a single map keeps the isolate to one read.
  static const String namesKey = 'push_render_names';

  /// Localized templates, see [PushTemplates].
  static const String templatesKey = 'push_render_templates';

  /// Persist the names the renderer may need. Called from the foreground app
  /// whenever the chat list is loaded — that is also when the app knows every
  /// name that a push could plausibly arrive for.
  ///
  /// Merges rather than replaces: chats load in pages, and a peer whose name
  /// was learned elsewhere should not be dropped because this call did not
  /// happen to include them.
  static Future<void> putNames(Map<String, String> names) async {
    if (names.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final merged = <String, String>{...await _readNames(prefs), ...names};
    await prefs.setString(namesKey, jsonEncode(merged));
    await _mirror(prefs, names: merged);
  }

  /// Persist the localized wording. Called once per app start (and on a locale
  /// change), because the isolate cannot translate anything itself.
  static Future<void> putTemplates(PushTemplates templates) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(templatesKey, jsonEncode(templates.toJson()));
    await _mirror(prefs, templates: templates.toJson());
  }

  /// Keep the web service worker's copy in step.
  ///
  /// The worker cannot read what Android's isolate reads: Flutter's
  /// shared_preferences is backed by localStorage, which is window-scoped and
  /// unreachable from a worker. Both values are always written together so the
  /// worker never sees names from one locale and wording from another.
  static Future<void> _mirror(
    SharedPreferences prefs, {
    Map<String, String>? names,
    Map<String, String>? templates,
  }) async {
    final n = names ?? await _readNames(prefs);
    final t = templates ?? _decodeMap(prefs.getString(templatesKey));
    await mirrorPushCacheForServiceWorker(names: n, templates: t);
    // iOS needs a THIRD copy for the same reason web needs a second: the
    // Notification Service Extension is its own process and only sees the App
    // Group's shared suite. No-ops elsewhere, and no-ops on iOS too until the
    // native channel ships with the extension. defaultTargetPlatform instead of
    // dart:io — this file is compiled for web TOO, and an `import 'dart:io'`
    // breaks the web build (which `flutter analyze` does not report, but the
    // build very much does).
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await mirrorPushCacheForAppGroup(names: n, templates: t);
    }
  }

  /// Everything the isolate needs, in one read.
  static Future<({Map<String, String> names, PushTemplates templates})>
  read() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      names: await _readNames(prefs),
      templates: PushTemplates.fromJson(
        _decodeMap(prefs.getString(templatesKey)),
      ),
    );
  }

  /// Drop everything. Called on logout/wipe — the names are a social graph in
  /// plaintext, and there is no reason for them to outlive the account on the
  /// device.
  ///
  /// All three copies (CHAT-38): until 2026-10 nothing called this, and the
  /// web worker's and the iOS App Group's copies had no way to be cleared at
  /// all, so the table survived logout and remote wipe.
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(namesKey);
    await prefs.remove(templatesKey);
    await mirrorPushCacheForServiceWorker(names: const {}, templates: const {});
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      await clearPushCacheForAppGroup();
    }
  }

  static Future<Map<String, String>> _readNames(SharedPreferences prefs) async {
    return _decodeMap(prefs.getString(namesKey));
  }

  /// Tolerant by design: a corrupt or half-written value must degrade to the
  /// generic notification, never throw inside a background isolate where the
  /// exception would surface as "no notification at all".
  static Map<String, String> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      };
    } catch (_) {
      return const {};
    }
  }
}

/// The localized wording a background isolate cannot look up itself.
///
/// Placeholders are `{user}` and `{chat}` — the same convention the app's
/// translation files already use.
class PushTemplates {
  const PushTemplates({
    required this.newMessage,
    required this.newMessageUnknown,
    required this.newMessageImage,
    required this.newMessageVideo,
    required this.newMessageAudio,
    required this.newMessageFile,
    required this.reaction,
    required this.reactionEmoji,
    required this.reactionUnknown,
    required this.memberRequestTitle,
    required this.memberRequestBody,
    required this.chatRequestTitle,
    required this.chatRequestBody,
    required this.chatFallback,
    required this.someone,
  });

  final String newMessage;
  final String newMessageUnknown;

  /// "X sent a photo" instead of "New message from X", when the server sent the
  /// coarse category along (00067, switchable per recipient).
  final String newMessageImage;
  final String newMessageVideo;
  final String newMessageAudio;
  final String newMessageFile;
  final String reaction;

  /// "X reacted with 👍" — only reachable when the recipient explicitly lets the
  /// emoji through (00072). Without consent the key is missing from the push
  /// and it stays at [reaction].
  final String reactionEmoji;
  final String reactionUnknown;
  final String memberRequestTitle;
  final String memberRequestBody;
  final String chatRequestTitle;
  final String chatRequestBody;
  final String chatFallback;
  final String someone;

  /// English defaults, used only when nothing has been cached yet — i.e. a
  /// push that arrives before the app has ever reached its first chat list.
  /// Better a readable English notification than none.
  static const PushTemplates fallback = PushTemplates(
    newMessage: 'New message from {user}',
    newMessageUnknown: 'New message',
    newMessageImage: '{user} sent a photo',
    newMessageVideo: '{user} sent a video',
    newMessageAudio: '{user} sent an audio file',
    newMessageFile: '{user} sent a file',
    reaction: '{user} reacted to your message',
    reactionEmoji: '{user} reacted with {emoji}',
    reactionUnknown: 'Someone reacted to your message',
    memberRequestTitle: 'New join request',
    memberRequestBody: '{user} wants to join {chat}',
    chatRequestTitle: 'New chat request',
    chatRequestBody: '{user} wants to message you',
    chatFallback: 'Chattr',
    someone: 'Someone',
  );

  Map<String, String> toJson() => {
    'new_message': newMessage,
    'new_message_unknown': newMessageUnknown,
    'new_message_image': newMessageImage,
    'new_message_video': newMessageVideo,
    'new_message_audio': newMessageAudio,
    'new_message_file': newMessageFile,
    'reaction': reaction,
    'reaction_emoji': reactionEmoji,
    'reaction_unknown': reactionUnknown,
    'member_request_title': memberRequestTitle,
    'member_request_body': memberRequestBody,
    'chat_request_title': chatRequestTitle,
    'chat_request_body': chatRequestBody,
    'chat_fallback': chatFallback,
    'someone': someone,
  };

  factory PushTemplates.fromJson(Map<String, String> json) {
    String pick(String key, String fallbackValue) {
      final value = json[key];
      return (value == null || value.isEmpty) ? fallbackValue : value;
    }

    const f = PushTemplates.fallback;
    return PushTemplates(
      newMessage: pick('new_message', f.newMessage),
      newMessageUnknown: pick('new_message_unknown', f.newMessageUnknown),
      newMessageImage: pick('new_message_image', f.newMessageImage),
      newMessageVideo: pick('new_message_video', f.newMessageVideo),
      newMessageAudio: pick('new_message_audio', f.newMessageAudio),
      newMessageFile: pick('new_message_file', f.newMessageFile),
      reaction: pick('reaction', f.reaction),
      reactionEmoji: pick('reaction_emoji', f.reactionEmoji),
      reactionUnknown: pick('reaction_unknown', f.reactionUnknown),
      memberRequestTitle: pick('member_request_title', f.memberRequestTitle),
      memberRequestBody: pick('member_request_body', f.memberRequestBody),
      chatRequestTitle: pick('chat_request_title', f.chatRequestTitle),
      chatRequestBody: pick('chat_request_body', f.chatRequestBody),
      chatFallback: pick('chat_fallback', f.chatFallback),
      someone: pick('someone', f.someone),
    );
  }
}
