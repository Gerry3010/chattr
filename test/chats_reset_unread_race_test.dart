// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// 2026-10-12: After a call with SeB the chat list showed SeB twice and Yogi
// not at all. Leaving SeB's chat started resetUnreadCount, which remembered
// SeB's POSITION, awaited, and wrote back to that position. Meanwhile the call
// log had bumped SeB to the top, so the old position now held Yogi, and SeB
// overwrote it. These tests replay exactly that interleaving.

import 'dart:async';

import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/features/chats/chat_member_keys_repository.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:chattr/features/chats/chats_local_repository.dart';
import 'package:chattr/features/chats/chats_repository.dart';
import 'package:chattr/features/messages/messages_local_provider.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repo implements ChatsRepository {
  @override
  Future<void> markChatRead(String chatId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds the FIRST save until [release] — that is the await inside
/// resetUnreadCount during which the list gets reordered.
class _GatedLocal implements ChatsLocalRepository {
  final _gate = Completer<void>();
  final saved = <Chat>[];
  var _first = true;

  void release() => _gate.complete();

  @override
  Future<void> saveChat(Chat chat) async {
    if (_first) {
      _first = false;
      await _gate.future;
    }
    saved.add(chat);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Messages implements MessagesLocalRepository {
  @override
  Future<DateTime?> latestMessageCreatedAt(String chatId) async =>
      DateTime.utc(2026, 10, 12, 18);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoKeys implements ChatMemberKeysRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoBiometrics implements BiometricAuthService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoKeyPairs implements ChatKeyPairManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Chat _chat(String id, DateTime last, {int unread = 0}) => Chat(
      id: id,
      createdAt: DateTime.utc(2026, 7, 1),
      insertedAt: DateTime.utc(2026, 7, 1),
      lastMessageAt: last,
      unreadCount: unread,
    );

void main() {
  late _GatedLocal local;
  late ChatsController chats;

  setUp(() {
    local = _GatedLocal();
    final holder = Provider<ChatsController>((ref) {
      return ChatsController(ref, _Repo(), _NoKeys(), local, _NoBiometrics(),
          _NoKeyPairs(), null, null);
    });
    final container = ProviderContainer(overrides: [
      messagesLocalRepositoryProvider.overrideWithValue(_Messages()),
    ]);
    addTearDown(container.dispose);
    chats = container.read(holder);
    // Yogi wrote last, so Yogi is on top and SeB second.
    chats.stateMap = {
      'yogi': _chat('yogi', DateTime.utc(2026, 10, 12, 19)),
      'seb': _chat('seb', DateTime.utc(2026, 10, 12, 18), unread: 2),
    };
  });

  test('Lesen und Hochrücken gleichzeitig: jeder Chat genau einmal', () async {
    expect(chats.state.map((c) => c.id), ['yogi', 'seb']);

    // Leaving SeB's chat …
    final reading = chats.resetUnreadCount('seb');
    await Future<void>.delayed(Duration.zero);
    // … while the call log moves SeB to the top.
    await chats.updateChatMetadata(
      chatId: 'seb',
      lastMessageAt: DateTime.utc(2026, 10, 12, 20),
      bumpToTop: true,
    );
    expect(chats.state.map((c) => c.id), ['seb', 'yogi']);

    local.release();
    await reading;

    expect(chats.state.map((c) => c.id), ['seb', 'yogi'],
        reason: 'früher stand hier [seb, seb] und Yogi fehlte');
  });

  test('das Lesen nimmt das Hochrücken nicht zurück', () async {
    final reading = chats.resetUnreadCount('seb');
    await Future<void>.delayed(Duration.zero);
    await chats.updateChatMetadata(
      chatId: 'seb',
      lastMessageAt: DateTime.utc(2026, 10, 12, 20),
      bumpToTop: true,
    );
    local.release();
    await reading;

    final seb = chats.state.firstWhere((c) => c.id == 'seb');
    expect(seb.unreadCount, 0);
    expect(seb.lastReadAt, DateTime.utc(2026, 10, 12, 18));
    expect(seb.lastMessageAt, DateTime.utc(2026, 10, 12, 20),
        reason: 'der Anruf-Eintrag hat den Chat nach oben geschoben');
    expect(chats.state.firstWhere((c) => c.id == 'yogi').lastMessageAt,
        DateTime.utc(2026, 10, 12, 19));
  });

  test('patchChatById ändert nur den genannten Chat und keine Position', () {
    final list = [
      _chat('a', DateTime.utc(2026, 1, 3)),
      _chat('b', DateTime.utc(2026, 1, 2), unread: 4),
      _chat('c', DateTime.utc(2026, 1, 1)),
    ];
    final out = patchChatById(list, 'b', (c) => c.copyWith(unreadCount: 0));
    expect(out.map((c) => c.id), ['a', 'b', 'c']);
    expect(out[1].unreadCount, 0);
    expect(identical(out[0], list[0]) && identical(out[2], list[2]), isTrue);
    expect(patchChatById(list, 'x', (c) => c.copyWith(unreadCount: 9))
        .map((c) => c.unreadCount), [0, 4, 0]);
  });
}
