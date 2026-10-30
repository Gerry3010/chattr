// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';
import '../push_notifications/push_cache_bridge_ios.dart';

/// Who matters to you — their messages arrive on iOS as **time sensitive** and
/// thereby get through focus modes and the summary.
///
/// **Deliberately on the device only, and that is the heart of the matter.**
/// The server could write the urgency into the push itself — but then it would
/// know which people mean the most to you. That is not a preference like a font
/// size, that is the ranking of your relationships, and it would be readable
/// straight out of the push table. The same decision as with the per-chat sound
/// ([[chat_sound_controller.dart]]): the server goes on treating everybody the
/// same, and the distinction is only made in the notification extension on the
/// device.
///
/// The price for it, named honestly: the marking does not travel to a second
/// device, and without the iOS extension it does nothing. On Android the
/// channel is already on high importance anyway — there the marking changes
/// nothing today, and claiming otherwise would be worse than saying so.
///
/// What is marked is a **person**, not a chat: that way it applies when the
/// same person writes in a group too — which is the more frequent case in which
/// one wants to lift a single voice out of the noise.
final importantPeopleProvider =
    StateNotifierProvider<ImportantPeopleController, Set<String>>((ref) {
  return ImportantPeopleController(ref.read(secureStorageProvider));
});

/// Ist [userId] als wichtig markiert?
final isImportantPersonProvider = Provider.family<bool, String>((ref, userId) {
  return ref.watch(importantPeopleProvider).contains(userId);
});

class ImportantPeopleController extends StateNotifier<Set<String>> {
  static const _key = 'important_people_v1';

  final FlutterSecureStorage _storage;

  /// Overridable for the test — otherwise every change runs into a platform
  /// channel that does not exist in a test.
  final Future<void> Function(Set<String>) _mirror;

  ImportantPeopleController(
    this._storage, {
    Future<void> Function(Set<String>)? mirror,
  })  : _mirror = mirror ?? mirrorImportantSendersForAppGroup,
        super(const {}) {
    _load();
  }

  Future<void> _load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List).whereType<String>().toSet();
      if (!mounted) return;
      state = list;
      // After a restart, bring the extension back to the same state: it reads
      // its own copy, and a stale one would be particularly annoying here — it
      // would quietly demote a person, and absent urgency looks like "the
      // feature can't do anything".
      await _mirror(state);
    } catch (_) {
      // Unreadable: nobody is important. That is the harmless direction — in
      // doubt one notification too quiet rather than a whole list too loud.
    }
  }

  bool isImportant(String userId) => state.contains(userId);

  Future<void> toggle(String userId) =>
      set(userId, important: !state.contains(userId));

  Future<void> set(String userId, {required bool important}) async {
    if (state.contains(userId) == important) return;
    final neu = Set<String>.from(state);
    if (important) {
      neu.add(userId);
    } else {
      neu.remove(userId);
    }
    state = neu;
    await _storage.write(key: _key, value: jsonEncode(neu.toList()));
    await _mirror(neu);
  }
}
