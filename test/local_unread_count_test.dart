// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The unread count moved off the server: it used to come from
// `chat_members.last_read_at` (migration 00053), a server-side record of when
// the user opened which chat. These tests drive the replacement against a real
// SQLite database — including the upgrade path, which is where the sharp edge
// is: existing rows are NOT backfilled with a direction, so without the unread
// epoch every old message would resurface as unread.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chattr/core/database/database_schema.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// Counts exactly the way MessagesLocalRepository.countUnread does, so the
  /// SQL under test is the SQL that ships.
  Future<int> countUnread(Database db, String chatId, DateTime? since) async {
    final sinceIso =
        (since ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
            .toUtc()
            .toIso8601String();
    final rows = await db.rawQuery(
      DatabaseSchema.countUnreadSql,
      [chatId, sinceIso],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<void> insert(
    Database db, {
    required String id,
    required String chatId,
    required DateTime createdAt,
    required bool incoming,
  }) =>
      db.insert(DatabaseSchema.messagesTable, {
        'id': id,
        'chat_id': chatId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'encrypted_data': 'blob',
        'is_favorite': 0,
        'is_incoming': incoming ? 1 : 0,
      });

  final t0 = DateTime.utc(2026, 8, 6, 10);

  group('fresh install (schema v10)', () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: DatabaseSchema.version,
          onCreate: (db, _) async {
            await db.execute(DatabaseSchema.createMessagesTable);
            await db.execute(DatabaseSchema.createMessagesUnreadIndex);
            await db.execute(DatabaseSchema.createSyncMetadataTable);
          },
        ),
      );
    });

    tearDown(() => db.close());

    test('only incoming messages count', () async {
      await insert(db, id: 'm1', chatId: 'c', createdAt: t0, incoming: true);
      await insert(db, id: 'm2', chatId: 'c', createdAt: t0, incoming: false);
      await insert(db, id: 'm3', chatId: 'c', createdAt: t0, incoming: true);

      expect(await countUnread(db, 'c', null), 2);
    });

    test('the read marker excludes everything up to and including itself',
        () async {
      await insert(db, id: 'm1', chatId: 'c', createdAt: t0, incoming: true);
      await insert(
        db,
        id: 'm2',
        chatId: 'c',
        createdAt: t0.add(const Duration(minutes: 1)),
        incoming: true,
      );

      expect(await countUnread(db, 'c', t0), 1);
      expect(
        await countUnread(db, 'c', t0.add(const Duration(minutes: 1))),
        0,
      );
    });

    test('counts are per chat', () async {
      await insert(db, id: 'm1', chatId: 'a', createdAt: t0, incoming: true);
      await insert(db, id: 'm2', chatId: 'b', createdAt: t0, incoming: true);
      await insert(db, id: 'm3', chatId: 'b', createdAt: t0, incoming: true);

      expect(await countUnread(db, 'a', null), 1);
      expect(await countUnread(db, 'b', null), 2);
    });

    test('with no marker at all, everything incoming counts — a fresh install '
        'really has not read any of it', () async {
      await insert(
        db,
        id: 'm1',
        chatId: 'c',
        createdAt: t0.subtract(const Duration(days: 30)),
        incoming: true,
      );
      expect(await countUnread(db, 'c', null), 1);
    });

    test('local timestamps are compared as UTC, not as written', () async {
      // A marker handed in as local time must not shift the boundary: the
      // stored strings are UTC, and string comparison is what SQLite does.
      final localMarker = t0.toLocal();
      await insert(
        db,
        id: 'm1',
        chatId: 'c',
        createdAt: t0.subtract(const Duration(hours: 1)),
        incoming: true,
      );
      await insert(
        db,
        id: 'm2',
        chatId: 'c',
        createdAt: t0.add(const Duration(hours: 1)),
        incoming: true,
      );
      expect(await countUnread(db, 'c', localMarker), 1);
    });
  });

  group('upgrade from schema v9', () {
    late Database db;

    /// A v9 database: messages table without `is_incoming`, holding history.
    setUp(() async {
      db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 9,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE ${DatabaseSchema.messagesTable} (
                id TEXT PRIMARY KEY,
                chat_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                encrypted_data BLOB NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0
              )
            ''');
            await db.execute(DatabaseSchema.createSyncMetadataTable);
          },
        ),
      );
      // Two years of history, all of it long since read.
      for (var i = 0; i < 5; i++) {
        await db.insert(DatabaseSchema.messagesTable, {
          'id': 'old$i',
          'chat_id': 'c',
          'created_at':
              t0.subtract(Duration(days: 30 * i + 1)).toIso8601String(),
          'encrypted_data': 'blob',
          'is_favorite': 0,
        });
      }
    });

    tearDown(() => db.close());

    Future<DateTime> runUpgrade() async {
      for (final sql in DatabaseSchema.migrateV9ToV10) {
        await db.execute(sql);
      }
      final epoch = t0;
      await db.insert(
        DatabaseSchema.syncMetadataTable,
        {
          'chat_id': DatabaseSchema.unreadEpochKey,
          'last_sync_timestamp': epoch.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return epoch;
    }

    test('history is not backfilled — old rows stay marked outgoing', () async {
      await runUpgrade();
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM ${DatabaseSchema.messagesTable} '
        'WHERE is_incoming = 1',
      );
      expect(Sqflite.firstIntValue(rows), 0);
    });

    test('an upgraded install shows zero unread, not its whole history',
        () async {
      final epoch = await runUpgrade();
      expect(await countUnread(db, 'c', epoch), 0);
    });

    test('THE TRAP: re-saving an old message (an edit, a receipt) stamps it '
        'incoming — the epoch is what stops it counting', () async {
      final epoch = await runUpgrade();

      // markAsReceived/markAsRead/edit all round-trip through saveMessage, so
      // an old row CAN acquire is_incoming = 1 long after the upgrade.
      await db.update(
        DatabaseSchema.messagesTable,
        {'is_incoming': 1},
        where: 'id = ?',
        whereArgs: ['old0'],
      );

      // Without the epoch (null marker → count from 1970) this would be 1.
      expect(await countUnread(db, 'c', null), 1);
      // With it, the message stays where it belongs: in the past.
      expect(await countUnread(db, 'c', epoch), 0);
    });

    test('messages arriving after the upgrade do count', () async {
      final epoch = await runUpgrade();
      await insert(
        db,
        id: 'new1',
        chatId: 'c',
        createdAt: t0.add(const Duration(minutes: 5)),
        incoming: true,
      );
      expect(await countUnread(db, 'c', epoch), 1);
    });

    test('the unread index exists after the upgrade', () async {
      await runUpgrade();
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name = 'idx_messages_unread'",
      );
      expect(rows, hasLength(1));
    });
  });
}
