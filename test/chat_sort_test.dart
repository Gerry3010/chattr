// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Chat-list sort key (1.7 #5): sortDate MUST equal the field the row displays
// (lastMessageAt ?? createdAt), so a chat never sorts by one instant while
// showing another. Regression guard for the mis-sort where sortDate used the
// local-only insertedAt while the row showed createdAt.

import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/chats/chats_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Chat chat({
    required String id,
    required DateTime createdAt,
    DateTime? insertedAt,
    DateTime? lastMessageAt,
  }) =>
      Chat(
        id: id,
        createdAt: createdAt,
        insertedAt: insertedAt,
        lastMessageAt: lastMessageAt,
      );

  /// What the ChatList row actually renders as the date.
  DateTime displayedDate(Chat c) => c.lastMessageAt ?? c.createdAt;

  test('sortDate uses lastMessageAt when present', () {
    final c = chat(
      id: 'a',
      createdAt: DateTime.utc(2026, 1, 1),
      lastMessageAt: DateTime.utc(2026, 7, 1),
    );
    expect(c.sortDate, DateTime.utc(2026, 7, 1));
    expect(c.sortDate, displayedDate(c));
  });

  test('sortDate falls back to createdAt (NOT insertedAt) for message-less chat',
      () {
    // insertedAt (local sync time) deliberately diverges from createdAt.
    final c = chat(
      id: 'b',
      createdAt: DateTime.utc(2026, 1, 1),
      insertedAt: DateTime.utc(2026, 7, 20), // much later local insert
    );
    expect(c.sortDate, DateTime.utc(2026, 1, 1));
    expect(c.sortDate, displayedDate(c)); // sort == what the row shows
  });

  test('list order matches displayed dates (no divergence)', () {
    final older = chat(
      id: 'older',
      createdAt: DateTime.utc(2026, 1, 1),
      insertedAt: DateTime.utc(2026, 7, 21), // recently synced but old chat
    );
    final newer = chat(
      id: 'newer',
      createdAt: DateTime.utc(2026, 5, 1),
      lastMessageAt: DateTime.utc(2026, 6, 1),
    );
    final list = [older, newer]
      ..sort((a, b) => b.sortDate.compareTo(a.sortDate));

    // 'newer' (Jun) must sort above 'older' (Jan) — by displayed date, the old
    // chat would previously have jumped to the top via its recent insertedAt.
    expect(list.first.id, 'newer');
    expect(list.last.id, 'older');
    // And every row's sort key equals its displayed date.
    for (final c in list) {
      expect(c.sortDate, displayedDate(c));
    }
  });

  // 1.8 #8: sending to a chat must float it to the very top even when the local
  // clock lags behind the timestamps other chats carry (cross-device skew) or
  // the media timestamp was captured at upload-start. bumpedSortTimestamp() is
  // the real code path used by ChatsController.updateChatMetadata(bumpToTop).
  group('bumpedSortTimestamp (send always goes to top)', () {
    test('forces above the newest OTHER chat when local timestamp lags', () {
      final sent = chat(id: 'sent', createdAt: DateTime.utc(2026, 1, 1));
      final rival = chat(
        id: 'rival',
        createdAt: DateTime.utc(2026, 1, 1),
        lastMessageAt: DateTime.utc(2026, 7, 24, 12, 0, 5), // ahead of us
      );
      // Local send clock is 5s BEHIND the rival's key.
      final localSend = DateTime.utc(2026, 7, 24, 12, 0, 0);

      final bumped = bumpedSortTimestamp(
        chats: [sent, rival],
        chatId: 'sent',
        lastMessageAt: localSend,
      )!;

      expect(bumped.isAfter(rival.sortDate), isTrue,
          reason: 'sent chat must outrank the rival after bumping');

      // Re-sorting with the bumped key puts the sent chat first.
      final list = [
        sent.copyWith(lastMessageAt: bumped),
        rival,
      ]..sort((a, b) => b.sortDate.compareTo(a.sortDate));
      expect(list.first.id, 'sent');
    });

    test('keeps the local timestamp when it is already the newest', () {
      final sent = chat(id: 'sent', createdAt: DateTime.utc(2026, 1, 1));
      final rival = chat(
        id: 'rival',
        createdAt: DateTime.utc(2026, 1, 1),
        lastMessageAt: DateTime.utc(2026, 7, 24, 11, 0, 0), // behind us
      );
      final localSend = DateTime.utc(2026, 7, 24, 12, 0, 0);

      final bumped = bumpedSortTimestamp(
        chats: [sent, rival],
        chatId: 'sent',
        lastMessageAt: localSend,
      );
      // No fabrication needed — we're already on top.
      expect(bumped, localSend);
    });

    test('null timestamp stays null (nothing to bump)', () {
      final sent = chat(id: 'sent', createdAt: DateTime.utc(2026, 1, 1));
      expect(
        bumpedSortTimestamp(chats: [sent], chatId: 'sent', lastMessageAt: null),
        isNull,
      );
    });

    // 1.8 #3: pinned chats sort above all un-pinned ones, then by sortDate.
    group('compareChatsForList (pinned first)', () {
      Chat pinned(String id, DateTime last) => Chat(
            id: id,
            createdAt: DateTime.utc(2026, 1, 1),
            lastMessageAt: last,
            isPinned: true,
          );
      Chat plain(String id, DateTime last) => Chat(
            id: id,
            createdAt: DateTime.utc(2026, 1, 1),
            lastMessageAt: last,
          );

      test('a pinned chat outranks a newer un-pinned chat', () {
        final oldPinned = pinned('p', DateTime.utc(2026, 1, 2));
        final newPlain = plain('n', DateTime.utc(2026, 7, 24));
        final list = [newPlain, oldPinned]..sort(compareChatsForList);
        expect(list.first.id, 'p'); // pin wins despite older activity
        expect(list.last.id, 'n');
      });

      test('within the same pin state, newer sortDate wins', () {
        final a = plain('a', DateTime.utc(2026, 3, 1));
        final b = plain('b', DateTime.utc(2026, 6, 1));
        final pOld = pinned('pold', DateTime.utc(2026, 1, 1));
        final pNew = pinned('pnew', DateTime.utc(2026, 2, 1));
        final list = [a, pOld, b, pNew]..sort(compareChatsForList);
        expect(list.map((c) => c.id).toList(), ['pnew', 'pold', 'b', 'a']);
      });
    });

    test('only OTHER chats set the floor (self is excluded)', () {
      // Self carries a huge existing lastMessageAt; it must NOT block the bump
      // (we exclude the target chat when computing the max of the others).
      final sent = chat(
        id: 'sent',
        createdAt: DateTime.utc(2026, 1, 1),
        lastMessageAt: DateTime.utc(2030, 1, 1),
      );
      final rival = chat(
        id: 'rival',
        createdAt: DateTime.utc(2026, 1, 1),
        lastMessageAt: DateTime.utc(2026, 7, 24, 12, 0, 0),
      );
      final localSend = DateTime.utc(2026, 7, 24, 11, 0, 0); // behind rival

      final bumped = bumpedSortTimestamp(
        chats: [sent, rival],
        chatId: 'sent',
        lastMessageAt: localSend,
      )!;
      expect(bumped.isAfter(rival.sortDate), isTrue);
    });
  });
}
