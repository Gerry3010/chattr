// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Drives the REAL MessagesLocalRepository against a real SQLite file: messages
// go in through `saveMessage` (the single choke point every code path uses) and
// come back out as counts through `countUnread`. Only the encryption is
// stubbed — the direction rule, the column write and the query are the shipped
// ones.
//
// This is the part the SQL-level test cannot prove: that `is_incoming` is
// actually written, on both the insert AND the update path, from the signed-in
// user at the time of the write.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' show join;
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chattr/core/database/database_schema.dart';
import 'package:chattr/core/database/database_service.dart';
import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/encryption_service.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';

/// Passes the JSON through untouched. The unread count never looks inside the
/// blob — that is the whole point of the indexed column — so real crypto here
/// would only add a key manager to the setup.
class _PassthroughEncryption extends EncryptionService {
  _PassthroughEncryption()
    : super(
        EncryptionKeyManager(
          const FlutterSecureStorage(),
          BiometricAuthService(),
        ),
      );

  final _store = <String, Map<String, dynamic>>{};
  var _seq = 0;

  @override
  Future<String?> encryptJson(Map<String, dynamic> json) async {
    final handle = 'blob-${_seq++}';
    _store[handle] = json;
    return handle;
  }

  @override
  Future<Map<String, dynamic>?> decryptJson(String ciphertext) async =>
      _store[ciphertext];
}

void main() {
  const me = 'user-me';
  const peer = 'user-peer';
  final t0 = DateTime.utc(2026, 8, 6, 10);

  late MessagesLocalRepository repo;
  String? signedInAs;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    FlutterSecureStorage.setMockInitialValues({});
  });

  setUp(() async {
    // A fresh file per test — DatabaseService is a singleton, so the previous
    // test's rows would otherwise leak into this one.
    await DatabaseService.instance.close();
    await DatabaseService.instance.deleteDatabase();
    signedInAs = me;
    repo = MessagesLocalRepository(
      DatabaseService.instance,
      _PassthroughEncryption(),
      () => signedInAs,
    );
  });

  tearDownAll(() async {
    await DatabaseService.instance.close();
    await DatabaseService.instance.deleteDatabase();
  });

  Message message({
    required String id,
    required String sender,
    Duration offset = Duration.zero,
    String chatId = 'c1',
  }) => Message(
    id: id,
    chatId: chatId,
    senderId: sender,
    recipientId: me,
    createdAt: t0.add(offset),
    decryptedContent: 'hello',
  );

  Future<int> unread(String chatId, DateTime? since) async =>
      (await repo.countUnread({chatId: since}))[chatId]!;

  test('a peer message counts, my own does not', () async {
    await repo.saveMessage(message(id: 'm1', sender: peer));
    await repo.saveMessage(
      message(id: 'm2', sender: me, offset: const Duration(minutes: 1)),
    );

    expect(await unread('c1', null), 1);
  });

  test('the read marker moves the boundary', () async {
    await repo.saveMessage(message(id: 'm1', sender: peer));
    await repo.saveMessage(
      message(id: 'm2', sender: peer, offset: const Duration(minutes: 5)),
    );

    expect(await unread('c1', null), 2);
    expect(await unread('c1', t0), 1);
    expect(await unread('c1', t0.add(const Duration(minutes: 5))), 0);
  });

  test('a system message counts as unread', () async {
    await repo.saveMessage(
      SystemMessage(
        id: 'sys1',
        chatId: 'c1',
        recipientId: me,
        createdAt: t0,
        action: 'joined',
      ),
    );
    expect(await unread('c1', null), 1);
  });

  test('the update path keeps the direction — a receipt on my own message '
      'must not turn it into an unread one', () async {
    final mine = message(id: 'm1', sender: me);
    await repo.saveMessage(mine);
    expect(await unread('c1', null), 0);

    // markAsReceived/markAsRead round-trip through saveMessage; an edit uses
    // the update branch. Neither may flip the direction.
    await repo.markAsReceived('c1', 'm1', peer);
    await repo.saveMessage(mine, update: true);

    expect(await unread('c1', null), 0);
  });

  test('counts are independent per chat', () async {
    await repo.saveMessage(message(id: 'm1', sender: peer, chatId: 'a'));
    await repo.saveMessage(message(id: 'm2', sender: peer, chatId: 'b'));
    await repo.saveMessage(
      message(
        id: 'm3',
        sender: peer,
        chatId: 'b',
        offset: const Duration(minutes: 1),
      ),
    );

    final counts = await repo.countUnread({'a': null, 'b': null});
    expect(counts, {'a': 1, 'b': 2});
  });

  test('an unknown chat reports zero, not an absent key', () async {
    expect(await repo.countUnread({'nope': null}), {'nope': 0});
  });

  test('signed out, nothing is labelled incoming', () async {
    signedInAs = null;
    await repo.saveMessage(message(id: 'm1', sender: peer));
    // Better a missing badge than unread messages the user cannot clear.
    expect(await unread('c1', null), 0);
  });

  test('the fallback applies only to chats without their own marker', () async {
    await repo.saveMessage(message(id: 'm1', sender: peer, chatId: 'a'));
    await repo.saveMessage(message(id: 'm2', sender: peer, chatId: 'b'));

    final counts = await repo.countUnread(
      // 'a' has its own marker past everything; 'b' falls back.
      {'a': t0.add(const Duration(hours: 1)), 'b': null},
      fallback: t0.subtract(const Duration(hours: 1)),
    );
    expect(counts, {'a': 0, 'b': 1});
  });

  test('the unread epoch is absent on a fresh database', () async {
    // Only the v9→v10 upgrade stamps it; a fresh install has read nothing.
    expect(await repo.getUnreadEpoch(), isNull);
    expect(DatabaseSchema.unreadEpochKey, startsWith('__'));
  });

  // The upgrade path as it actually ships: a v9 file with real history is put
  // where DatabaseService looks for it and opened through DatabaseService
  // itself, so sqflite's own version gate runs `_onUpgrade` exactly once. The
  // SQL-level test (local_unread_count_test.dart) drives the migration
  // statements directly; this proves they are wired to the version bump.
  //
  // These live in THIS file on purpose: `flutter test` runs files in parallel
  // processes, and every test here opens the same singleton database path — a
  // second file doing that would race for the same SQLite file.
  group('upgrade from a real v9 file, through DatabaseService', () {
    /// Writes a v9 database — the shape shipped before this change — at the path
    /// DatabaseService will open, holding [months] of history in one chat.
    Future<void> seedV9({int months = 6}) async {
      final path = join(
        await databaseFactory.getDatabasesPath(),
        DatabaseSchema.databaseName,
      );
      final db = await databaseFactory.openDatabase(
        path,
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
      for (var i = 0; i < months; i++) {
        await db.insert(DatabaseSchema.messagesTable, {
          'id': 'old$i',
          'chat_id': 'c1',
          'created_at': t0
              .subtract(Duration(days: 30 * (i + 1)))
              .toIso8601String(),
          'encrypted_data': 'blob',
          'is_favorite': 0,
        });
      }
      await db.close();
    }

    test('opening a v9 file through DatabaseService upgrades it and stamps the '
        'unread epoch', () async {
      await seedV9();

      // The real open path: version comes from DatabaseSchema, _onUpgrade runs.
      final db = await DatabaseService.instance.database;

      expect(await db.getVersion(), DatabaseSchema.version);

      final columns = await db.rawQuery(
        'PRAGMA table_info(${DatabaseSchema.messagesTable})',
      );
      expect(columns.map((c) => c['name']), contains('is_incoming'));

      final epochRows = await db.query(
        DatabaseSchema.syncMetadataTable,
        where: 'chat_id = ?',
        whereArgs: [DatabaseSchema.unreadEpochKey],
      );
      expect(
        epochRows,
        hasLength(1),
        reason: 'without the epoch, history resurfaces as unread',
      );
    });

    test('history survives the upgrade and reports zero unread', () async {
      await seedV9(months: 6);
      final db = await DatabaseService.instance.database;

      final total = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM ${DatabaseSchema.messagesTable}',
        ),
      );
      expect(total, 6, reason: 'the upgrade must not drop messages');

      final epoch = DateTime.parse(
        (await db.query(
              DatabaseSchema.syncMetadataTable,
              where: 'chat_id = ?',
              whereArgs: [DatabaseSchema.unreadEpochKey],
            )).single['last_sync_timestamp']
            as String,
      );

      final unread = Sqflite.firstIntValue(
        await db.rawQuery(DatabaseSchema.countUnreadSql, [
          'c1',
          epoch.toUtc().toIso8601String(),
        ]),
      );
      expect(unread, 0);
    });

    test(
      'a fresh database is created at the current version WITHOUT an epoch',
      () async {
        // Nothing to declare read on a fresh install — and messages fetched right
        // after installing really are unread.
        final db = await DatabaseService.instance.database;

        expect(await db.getVersion(), DatabaseSchema.version);
        final epochRows = await db.query(
          DatabaseSchema.syncMetadataTable,
          where: 'chat_id = ?',
          whereArgs: [DatabaseSchema.unreadEpochKey],
        );
        expect(epochRows, isEmpty);

        final indexes = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name = 'idx_messages_unread'",
        );
        expect(
          indexes,
          hasLength(1),
          reason: 'onCreate must build the same index as the upgrade',
        );
      },
    );
  });

  group('latestMessageCreatedAt — the anchor the read marker is stamped from',
      () {
    test('an empty chat has none', () async {
      expect(await repo.latestMessageCreatedAt('c1'), isNull);
    });

    test('it is the newest message, mine included', () async {
      // The marker must cover everything on screen, not just incoming — an own
      // message sent after the last received one is still "read up to here".
      await repo.saveMessage(message(id: 'm1', sender: peer));
      await repo.saveMessage(
        message(id: 'm2', sender: me, offset: const Duration(minutes: 3)),
      );
      expect(
        await repo.latestMessageCreatedAt('c1'),
        t0.add(const Duration(minutes: 3)),
      );
    });

    test('it does not leak across chats', () async {
      await repo.saveMessage(message(id: 'm1', sender: peer, chatId: 'a'));
      await repo.saveMessage(
        message(
          id: 'm2',
          sender: peer,
          chatId: 'b',
          offset: const Duration(hours: 9),
        ),
      );
      expect(await repo.latestMessageCreatedAt('a'), t0);
    });

    test('opening the chat leaves a message in flight countable', () async {
      // End-to-end shape of the reported bug, at the layer that decides it.
      // Two messages are here when the chat opens; a third was already created
      // on the server and lands a moment later. With a wall-clock marker it
      // would be older than the marker and vanish from the badge for good.
      await repo.saveMessage(message(id: 'm1', sender: peer));
      await repo.saveMessage(
        message(id: 'm2', sender: peer, offset: const Duration(minutes: 1)),
      );
      final marker = await repo.latestMessageCreatedAt('c1');
      expect(await unread('c1', marker), 0);

      await repo.saveMessage(
        message(id: 'm3', sender: peer, offset: const Duration(minutes: 2)),
      );
      expect(await unread('c1', marker), 1);
    });
  });
}
