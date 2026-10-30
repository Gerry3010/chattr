// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Regression tests for ChatsController.mergeServerChats — the pure merge that
// refreshChats puts into state.
//
// The historical bug: a chat that only received messages never bumps
// `updatedAt`, so the old updatedAt-gated diff dropped the fresh server unread
// count from state while writing it to the local DB — the badge alternated
// 118 ↔ 0 on every app resume. That whole class of bug is now structurally
// gone: the unread count no longer comes from the server at all. The merge
// keeps the LOCAL count (recomputed from the local message store right after)
// and the LOCAL read marker, so there is nothing left to disagree about.

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
    DateTime? lastReadAt,
  }) =>
      Chat(
        id: id,
        createdAt: base,
        insertedAt: base,
        unreadCount: unread,
        isPinned: pinned,
        lastMessageAt: lastMessageAt,
        lastReadAt: lastReadAt,
      );

  group('mergeServerChats', () {
    test('the server unread count is discarded, the local one survives', () {
      final merged = ChatsController.mergeServerChats(
        localChats: {'a': chat('a', unread: 4)},
        // Still arrives in the payload until the server side is dropped.
        serverChats: [chat('a', unread: 118)],
      );
      expect(merged['a']!.unreadCount, 4);
    });

    test('a chat the server has but we do not starts at zero, not at the '
        'server count', () {
      final merged = ChatsController.mergeServerChats(
        localChats: const {},
        serverChats: [chat('a', unread: 118)],
      );
      // _withLocalUnread recomputes it from the local store; 118 must never be
      // the seed, or a chat would show a count derived from last_read_at.
      expect(merged['a']!.unreadCount, 0);
    });

    test('the local read marker is preserved (server data never carries it)',
        () {
      final read = base.add(const Duration(hours: 2));
      final merged = ChatsController.mergeServerChats(
        localChats: {'a': chat('a', lastReadAt: read)},
        serverChats: [chat('a')],
      );
      expect(merged['a']!.lastReadAt, read);
    });

    test('local pin and newer local lastMessageAt are preserved', () {
      final newer = base.add(const Duration(minutes: 5));
      final merged = ChatsController.mergeServerChats(
        localChats: {
          'a': chat('a', pinned: true, lastMessageAt: newer),
        },
        serverChats: [chat('a', lastMessageAt: base)],
      );
      expect(merged['a']!.isPinned, isTrue);
      expect(merged['a']!.lastMessageAt, newer);
    });

    test('server metadata still wins for everything else', () {
      final merged = ChatsController.mergeServerChats(
        localChats: {'a': chat('a')},
        serverChats: [
          Chat(
            id: 'a',
            createdAt: base,
            name: 'Renamed on another device',
            admins: const ['u1'],
          ),
        ],
      );
      expect(merged['a']!.name, 'Renamed on another device');
      expect(merged['a']!.admins, ['u1']);
    });

    test('local-only chats are kept (targeted/subset fetch)', () {
      final merged = ChatsController.mergeServerChats(
        localChats: {'a': chat('a', unread: 2), 'b': chat('b', unread: 1)},
        serverChats: [chat('b')],
      );
      expect(merged.keys.toSet(), {'a', 'b'});
      expect(merged['a']!.unreadCount, 2);
      expect(merged['b']!.unreadCount, 1);
    });

    test('repeated resume cycles converge instead of flickering', () {
      // The old flicker needed the server and the local snapshot to disagree.
      // Now the count is local, so re-merging the same server payload is a
      // fixed point no matter how often a resume fires.
      var local = {'a': chat('a', unread: 7)};
      final server = [chat('a', unread: 118)];
      for (var cycle = 0; cycle < 3; cycle++) {
        local = ChatsController.mergeServerChats(
          localChats: local,
          serverChats: server,
        );
        expect(local['a']!.unreadCount, 7, reason: 'cycle $cycle');
      }
    });
  });
}
