// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Unit tests for the refreshChats deletion reconciliation
// (ChatsController.computeRemovedChatIds): a chat missing from a successful
// server fetch means it was deleted or we were removed, so it must be dropped
// locally — but only within the scope the fetch could have returned, and not
// for freshly inserted chats (create race).

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';

void main() {
  final now = DateTime.utc(2026, 7, 10, 12);
  final old = now.subtract(const Duration(days: 1));

  Chat chat(String id, {DateTime? insertedAt}) => Chat(
        id: id,
        createdAt: insertedAt ?? old,
        insertedAt: insertedAt ?? old,
      );

  group('computeRemovedChatIds', () {
    test('full refresh removes chats missing from the fetch', () {
      final removed = ChatsController.computeRemovedChatIds(
        requestedIds: null,
        localChats: {'a': chat('a'), 'b': chat('b'), 'c': chat('c')},
        fetchedIds: {'a'},
        now: now,
      );
      expect(removed.toSet(), {'b', 'c'});
    });

    test('targeted refresh only considers the requested ids', () {
      // A targeted fetch returns only the requested chats — other local
      // chats being absent from the response means nothing.
      final removed = ChatsController.computeRemovedChatIds(
        requestedIds: ['b'],
        localChats: {'a': chat('a'), 'b': chat('b'), 'c': chat('c')},
        fetchedIds: <String>{},
        now: now,
      );
      expect(removed, ['b']);
    });

    test('keeps chats that the fetch returned', () {
      final removed = ChatsController.computeRemovedChatIds(
        requestedIds: null,
        localChats: {'a': chat('a')},
        fetchedIds: {'a'},
        now: now,
      );
      expect(removed, isEmpty);
    });

    test('skips freshly inserted chats (create race)', () {
      final removed = ChatsController.computeRemovedChatIds(
        requestedIds: null,
        localChats: {
          'fresh': chat(
            'fresh',
            insertedAt: now.subtract(const Duration(seconds: 30)),
          ),
          'old': chat('old'),
        },
        fetchedIds: <String>{},
        now: now,
      );
      expect(removed, ['old']);
    });

    test('ignores requested ids that are not cached locally', () {
      final removed = ChatsController.computeRemovedChatIds(
        requestedIds: ['unknown'],
        localChats: {'a': chat('a')},
        fetchedIds: <String>{},
        now: now,
      );
      expect(removed, isEmpty);
    });
  });
}
