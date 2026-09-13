// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The per-chat sound (1.26.1). What is checked above all is the FALLBACK: a
// chat without a choice of its own has to get the general sound — not silence.
// That is exactly the fault one never notices in operation, because an absent
// notification looks like "no message".

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/notifications/notification_sounds.dart';
import 'package:chattr/features/chats/chat_sound_controller.dart';

const _chatA = 'chat-a';
const _chatB = 'chat-b';

ChatSoundController _controller() =>
    ChatSoundController(const FlutterSecureStorage());

/// Waits until the controller has read its storage (that happens asynchronously
/// in the constructor).
Future<ChatSoundController> _loaded() async {
  final c = _controller();
  await Future<void>.delayed(Duration.zero);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('without a choice of its own nothing applies — the caller falls back', () async {
    final c = await _loaded();
    expect(c.soundIdFor(_chatA), isNull);
  });

  test('a choice applies only to its chat', () async {
    final c = await _loaded();
    final ton = kNotificationSounds.firstWhere((s) => !s.isSilent);

    await c.select(_chatA, ton.id);
    expect(c.soundIdFor(_chatA), ton.id);
    expect(c.soundIdFor(_chatB), isNull,
        reason: 'a neighbouring chat must get none of it');
  });

  test('resetting means "as in the settings" again', () async {
    final c = await _loaded();
    final ton = kNotificationSounds.firstWhere((s) => !s.isSilent);

    await c.select(_chatA, ton.id);
    await c.select(_chatA, null);
    expect(c.soundIdFor(_chatA), isNull);
  });

  test('the choice survives a restart', () async {
    final ton = kNotificationSounds.firstWhere((s) => !s.isSilent);
    await (await _loaded()).select(_chatA, ton.id);

    final neu = await _loaded();
    expect(neu.soundIdFor(_chatA), ton.id);
  });

  test('an unknown sound is dropped silently, not adopted',
      () async {
    // If a sound disappeared from the catalogue, the chat would otherwise come
    // back as "unknown" — and, depending on the resolution, as muted. The
    // fallback to the general sound is the safe direction.
    FlutterSecureStorage.setMockInitialValues({
      'chat_notification_sounds_v1':
          jsonEncode({_chatA: 'gibt-es-nicht-mehr'}),
    });

    final c = await _loaded();
    expect(c.soundIdFor(_chatA), isNull);
  });

  test('a broken store does not hold up the start', () async {
    FlutterSecureStorage.setMockInitialValues({
      'chat_notification_sounds_v1': 'kein json',
    });

    final c = await _loaded();
    expect(c.soundIdFor(_chatA), isNull);
  });

  test('the silent choice is a choice too', () async {
    // "Muted" is an entry in the catalogue and has to be distinguishable from
    // "no choice" — otherwise a single chat cannot be silenced without muting
    // it entirely.
    final still = kNotificationSounds.firstWhere((s) => s.isSilent);
    final c = await _loaded();

    await c.select(_chatA, still.id);
    expect(c.soundIdFor(_chatA), still.id);
    expect(c.soundIdFor(_chatA), isNotNull);
  });
}
