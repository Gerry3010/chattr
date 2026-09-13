// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../security/security_providers.dart';
import 'notification_sounds.dart';

/// Currently selected in-app notification sound id, persisted in secure
/// storage. Read this to know which asset to play; watch it in the picker.
final notificationSoundControllerProvider =
    StateNotifierProvider<NotificationSoundController, String>((ref) {
  return NotificationSoundController(ref.read(secureStorageProvider));
});

class NotificationSoundController extends StateNotifier<String> {
  final FlutterSecureStorage _storage;
  static const _key = 'notification_sound';

  NotificationSoundController(this._storage)
      : super(kDefaultNotificationSoundId) {
    _load();
  }

  Future<void> _load() async {
    final value = await _storage.read(key: _key);
    if (value != null && kNotificationSounds.any((s) => s.id == value)) {
      state = value;
    }
  }

  /// Resolved option for the current selection.
  NotificationSoundOption get selected => notificationSoundById(state);

  Future<void> select(String id) async {
    if (!kNotificationSounds.any((s) => s.id == id)) return;
    state = id;
    await _storage.write(key: _key, value: id);
  }
}
