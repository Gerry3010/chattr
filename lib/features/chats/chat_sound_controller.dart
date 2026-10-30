// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/notifications/notification_sound_controller.dart';
import '../../core/notifications/notification_sounds.dart';
import '../../core/security/security_providers.dart';

/// Which sound applies to ONE chat — `null` means: the general one from the
/// settings.
///
/// **Deliberately local only.** The mute setting lives in `chat_mute_prefs` on
/// the server, because the server needs it: it decides whether a push goes out
/// at all. Which sound your device plays afterwards is none of its business —
/// and it would be a per-chat preference, exactly the kind of trimming from
/// which one can read off which conversation matters to you. It stays here.
///
/// **Applies to the in-app banner.** The system notification hangs on a channel
/// on Android, and channels are immutable once created — a sound of one's own
/// there would mean one channel per sound, created up front. That is worth a
/// round of its own; what stands here is the part that works reliably, and the
/// screen says so.
final chatSoundControllerProvider =
    StateNotifierProvider<ChatSoundController, Map<String, String>>((ref) {
  return ChatSoundController(ref.read(secureStorageProvider));
});

class ChatSoundController extends StateNotifier<Map<String, String>> {
  static const _key = 'chat_notification_sounds_v1';

  final FlutterSecureStorage _storage;

  ChatSoundController(this._storage) : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final valid = <String, String>{};
      map.forEach((chatId, id) {
        // Silently drop a sound that no longer exists: it would otherwise come
        // back as a muted chat, and that would be the wrong direction.
        if (id is String && kNotificationSounds.any((s) => s.id == id)) {
          valid[chatId] = id;
        }
      });
      if (mounted) state = valid;
    } catch (_) {
      // Unreadable: the general sound applies again. An error here must not
      // hold up the start.
    }
  }

  Future<void> _save() =>
      _storage.write(key: _key, value: jsonEncode(state));

  /// The choice for [chatId], or `null` for "as in the settings".
  String? soundIdFor(String chatId) => state[chatId];

  /// [id] `null` resets the chat to the general sound.
  Future<void> select(String chatId, String? id) async {
    if (id != null && !kNotificationSounds.any((s) => s.id == id)) return;
    final neu = Map<String, String>.from(state);
    if (id == null) {
      neu.remove(chatId);
    } else {
      neu[chatId] = id;
    }
    state = neu;
    await _save();
  }

  Future<void> forget(String chatId) => select(chatId, null);
}

/// The sound actually played for [chatId] — the chat's choice, otherwise the
/// general one. ONE place that decides this: if resolving lay with the caller,
/// one of them would eventually have forgotten the fallback.
NotificationSoundOption soundForChat(WidgetRef ref, String? chatId) {
  final eigener = chatId == null
      ? null
      : ref.read(chatSoundControllerProvider.notifier).soundIdFor(chatId);
  return notificationSoundById(
    eigener ?? ref.read(notificationSoundControllerProvider),
  );
}
