// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/database/database_schema.dart';
import 'package:chattr/features/messages/message_ordering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Ordering + pagination coverage for the chat message list.
///
/// Two layers:
///  1. [compareMessagesNewestFirst] / [isOlderMessage] — the single ordering
///     primitive the render `messageSorter`, `MessagesController.loadMore`'s
///     keyset boundary, and the search sort all funnel through.
///  2. Keyset pagination — the exact `WHERE` / `ORDER BY` that
///     `MessagesLocalRepository.loadMessages` builds, exercised against an
///     in-memory SQLite DB. The regression this locks: with two messages
///     sharing a `created_at` straddling a page boundary, the *old* strict
///     `created_at < ?` cursor silently dropped the tied message; the
///     `(created_at, id)` keyset must load every message exactly once.
void main() {
  group('message ordering primitive', () {
    final t1 = DateTime.utc(2026, 7, 18, 10, 0, 0);
    final t2 = DateTime.utc(2026, 7, 18, 10, 0, 1); // 1s newer

    test('newer createdAt sorts first (newest-first)', () {
      expect(
        compareMessagesNewestFirst(t2, 'a', t1, 'b'),
        lessThan(0),
        reason: 't2 is newer → sorts before t1',
      );
      expect(compareMessagesNewestFirst(t1, 'a', t2, 'b'), greaterThan(0));
    });

    test('equal createdAt breaks the tie by id (higher id first)', () {
      // Deterministic total order even when timestamps collide.
      expect(compareMessagesNewestFirst(t1, 'm002', t1, 'm001'), lessThan(0));
      expect(compareMessagesNewestFirst(t1, 'm001', t1, 'm002'), greaterThan(0));
      expect(compareMessagesNewestFirst(t1, 'x', t1, 'x'), 0);
    });

    test('isOlderMessage: strictly older by (createdAt, id)', () {
      expect(isOlderMessage(t1, 'b', t2, 'a'), isTrue); // older time
      expect(isOlderMessage(t2, 'a', t1, 'b'), isFalse); // newer time
      expect(isOlderMessage(t1, 'm001', t1, 'm002'), isTrue); // tie, lower id
      expect(isOlderMessage(t1, 'm002', t1, 'm001'), isFalse);
    });

    test('sorting a shuffled list is deterministic newest-first', () {
      final base = DateTime.utc(2026, 7, 18, 12);
      final items = <({DateTime t, String id})>[
        (t: base.add(const Duration(seconds: 2)), id: 'm09'),
        (t: base, id: 'm02'), // tie with m01/m03 below
        (t: base.add(const Duration(seconds: 5)), id: 'm20'),
        (t: base, id: 'm03'),
        (t: base, id: 'm01'),
      ]..shuffle();

      items.sort((a, b) => compareMessagesNewestFirst(a.t, a.id, b.t, b.id));

      expect(
        items.map((e) => e.id).toList(),
        // 5s, 2s, then the 0s tie group by id DESC (m03, m02, m01).
        ['m20', 'm09', 'm03', 'm02', 'm01'],
      );
    });
  });

  group('keyset pagination (created_at, id)', () {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    const chatId = 'chat-main';
    const otherChat = 'chat-other';
    const pageSize = 20;

    // 50 messages; a 4-message group shares one timestamp straddling the
    // page-1/page-2 boundary (the 20th/21st newest), the exact case the old
    // strict cursor mishandled.
    final base = DateTime.utc(2026, 7, 18, 9, 0, 0);
    final tieSecond = base.add(const Duration(seconds: 30));
    final tieIds = {28, 29, 30, 31};

    DateTime createdAtFor(int i) =>
        tieIds.contains(i) ? tieSecond : base.add(Duration(seconds: i));
    String idFor(int i) => 'm${i.toString().padLeft(3, '0')}';

    Future<Database> seededDb() async {
      final db = await factory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(DatabaseSchema.createMessagesTable);
      await db.execute(DatabaseSchema.createMessagesCreatedAtIndex);
      for (var i = 0; i < 50; i++) {
        await db.insert(DatabaseSchema.messagesTable, {
          'id': idFor(i),
          'chat_id': chatId,
          'created_at': createdAtFor(i).toIso8601String(),
          'encrypted_data': 'x',
        });
      }
      // Noise in another chat — must never leak into paging.
      for (var i = 0; i < 5; i++) {
        await db.insert(DatabaseSchema.messagesTable, {
          'id': 'o${i.toString().padLeft(3, '0')}',
          'chat_id': otherChat,
          'created_at': base.add(Duration(seconds: i)).toIso8601String(),
          'encrypted_data': 'x',
        });
      }
      return db;
    }

    // Mirror of MessagesLocalRepository.loadMessages — keep the WHERE/ORDER BY
    // in sync with that method. Returns a page (newest-first) of {id, t}.
    Future<List<({String id, DateTime t})>> pageOlder(
      Database db, {
      DateTime? beforeDate,
      String? beforeId,
      bool keyset = true,
    }) async {
      var where = 'chat_id = ?';
      final args = <Object?>[chatId];
      if (beforeDate != null) {
        final before = beforeDate.toIso8601String();
        if (keyset && beforeId != null) {
          where += ' AND (created_at < ? OR (created_at = ? AND id < ?))';
          args.addAll([before, before, beforeId]);
        } else {
          where += ' AND created_at < ?';
          args.add(before);
        }
      }
      final rows = await db.query(
        DatabaseSchema.messagesTable,
        where: where,
        whereArgs: args,
        orderBy: 'created_at DESC, id DESC',
        limit: pageSize,
      );
      return [
        for (final r in rows)
          (id: r['id'] as String, t: DateTime.parse(r['created_at'] as String)),
      ];
    }

    // Page through exactly like MessagesController.loadMore: reverse each page
    // to ascending, prepend, and derive the next cursor as the oldest loaded
    // message via the real isOlderMessage helper.
    Future<List<({String id, DateTime t})>> pageAll(
      Database db, {
      required bool keyset,
    }) async {
      final loaded = <({String id, DateTime t})>[];
      DateTime? beforeDate;
      String? beforeId;
      while (true) {
        final page = await pageOlder(
          db,
          beforeDate: beforeDate,
          beforeId: beforeId,
          keyset: keyset,
        );
        if (page.isEmpty) break;
        loaded.insertAll(0, page.reversed);
        final oldest = loaded.reduce(
          (p, c) => isOlderMessage(c.t, c.id, p.t, p.id) ? c : p,
        );
        beforeDate = oldest.t;
        beforeId = oldest.id;
        if (page.length < pageSize) break;
      }
      return loaded;
    }

    test('loads every message exactly once, strictly ascending', () async {
      final db = await seededDb();
      final loaded = await pageAll(db, keyset: true);

      final expected = [
        for (var i = 0; i < 50; i++) (id: idFor(i), t: createdAtFor(i)),
      ]..sort((a, b) {
          final byTime = a.t.compareTo(b.t);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });

      // No dup, no skip.
      expect(loaded.length, 50);
      expect(loaded.map((e) => e.id).toSet(), expected.map((e) => e.id).toSet());
      // Correct ascending (createdAt, id) order.
      expect(loaded.map((e) => e.id).toList(), expected.map((e) => e.id).toList());
      // Other chat never leaked.
      expect(loaded.any((e) => e.id.startsWith('o')), isFalse);
    });

    test('tied messages at the page boundary are not skipped', () async {
      final db = await seededDb();
      final loaded = await pageAll(db, keyset: true);
      // All four members of the tie group survive.
      for (final i in tieIds) {
        expect(
          loaded.any((e) => e.id == idFor(i)),
          isTrue,
          reason: '${idFor(i)} (tied created_at) must be loaded',
        );
      }
    });

    test(
      'regression: the naive created_at<? cursor DROPS tied messages',
      () async {
        final db = await seededDb();
        final naive = await pageAll(db, keyset: false);
        // The pre-fix cursor loses at least one tied message straddling the
        // boundary — this is exactly the bug the keyset closes.
        expect(
          naive.length,
          lessThan(50),
          reason: 'naive strict-less-than cursor should skip tied rows',
        );
        final loadedIds = naive.map((e) => e.id).toSet();
        expect(
          tieIds.any((i) => !loadedIds.contains(idFor(i))),
          isTrue,
          reason: 'at least one tied message is dropped by the naive cursor',
        );
      },
    );
  });
}
