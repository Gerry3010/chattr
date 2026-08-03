// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Regression tests for ChatsController.mergeServerChats — the pure merge that
// refreshChats puts into state. The historical bug: a chat that only received
// messages never bumps `updatedAt`, so the old updatedAt-gated diff dropped
// the fresh server unread count from state while writing it to the local DB —
// the badge alternated 118 ↔ 0 on every app resume.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';

void main() {
  final base = DateTime.utc(2026, 7, 10, 12);

  Chat chat(
    String id, {
    int unread = 0,
    bool pinned = false,
    DateTime? lastMessageAt,
  }) =>
      Chat(
        id: id,
        createdAt: base,
        insertedAt: base,
        unreadCount: unread,
        isPinned: pinned,
        lastMessageAt: lastMessageAt,
      );

  group('mergeServerChats', () {
    test(
        'server unread wins even when updatedAt is unchanged '
        '(118↔0 flicker regression)', () {
      final merged = ChatsController.mergeServerChats(
        localChats: {'a': chat('a', unread: 0)},
        serverChats: [chat('a', unread: 118)],
        pendingReadZero: const {},
      );
      expect(merged['a']!.unreadCount, 118);
    });

    test('pendingReadZero forces unread to 0 (mark_chat_read in flight)', () {
      final merged = ChatsController.mergeServerChats(
        localChats: {'a': chat('a', unread: 0)},
        serverChats: [chat('a', unread: 118)],
        pendingReadZero: const {'a'},
      );
      expect(merged['a']!.unreadCount, 0);
    });

    test('local pin and newer local lastMessageAt are preserved', () {
      final newer = base.add(const Duration(minutes: 5));
      final merged = ChatsController.mergeServerChats(
        localChats: {
          'a': chat('a', pinned: true, lastMessageAt: newer),
        },
        serverChats: [chat('a', unread: 3, lastMessageAt: base)],
        pendingReadZero: const {},
      );
      expect(merged['a']!.isPinned, isTrue);
      expect(merged['a']!.lastMessageAt, newer);
      expect(merged['a']!.unreadCount, 3);
    });

    test('local-only chats are kept (targeted/subset fetch)', () {
      final merged = ChatsController.mergeServerChats(
        localChats: {'a': chat('a', unread: 2), 'b': chat('b')},
        serverChats: [chat('b', unread: 1)],
        pendingReadZero: const {},
      );
      expect(merged.keys.toSet(), {'a', 'b'});
      expect(merged['a']!.unreadCount, 2);
      expect(merged['b']!.unreadCount, 1);
    });

    test('alternating resume cycles converge instead of flickering', () {
      // Cycle 1: fresh server fetch over a zeroed local snapshot.
      var local = {'a': chat('a', unread: 0)};
      final server = [chat('a', unread: 118)];
      var merged = ChatsController.mergeServerChats(
        localChats: local,
        serverChats: server,
        pendingReadZero: const {},
      );
      expect(merged['a']!.unreadCount, 118);

      // Cycle 2: the merge result was persisted (state == DB == 118); the next
      // resume must yield 118 again, not swing back to the stale value.
      local = merged;
      merged = ChatsController.mergeServerChats(
        localChats: local,
        serverChats: server,
        pendingReadZero: const {},
      );
      expect(merged['a']!.unreadCount, 118);
    });
  });
}
