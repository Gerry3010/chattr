// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/database/database_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema-level coverage for the drafts table (DB version 6): fresh create,
/// the v5→v6 upgrade path, and the upsert/delete semantics DraftsRepository
/// relies on (PK on chat_id + ConflictAlgorithm.replace).
void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  test('fresh create includes the drafts table', () async {
    final db = await factory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(DatabaseSchema.createDraftsTable);

    await db.insert(DatabaseSchema.draftsTable, {
      'chat_id': 'c1',
      'updated_at': '2026-07-11T00:00:00Z',
      'encrypted_data': 'iv:cipher',
    });
    final rows = await db.query(DatabaseSchema.draftsTable);
    expect(rows, hasLength(1));
  });

  test('v5 → v6 upgrade adds the drafts table', () async {
    // Simulate a v5 database (no drafts table), then run the v6 migration
    // step exactly as DatabaseService._onUpgrade does.
    final db = await factory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseSchema.version,
        onCreate: (db, version) async {
          await db.execute(DatabaseSchema.createChatsTable);
          await db.execute(DatabaseSchema.createMessagesTable);
          // v5 had no drafts table.
        },
      ),
    );
    addTearDown(db.close);

    // The migration statement must succeed on a DB without the table…
    await db.execute(DatabaseSchema.createDraftsTable);
    // …and produce a usable table.
    await db.insert(DatabaseSchema.draftsTable, {
      'chat_id': 'c1',
      'updated_at': '2026-07-11T00:00:00Z',
      'encrypted_data': 'blob',
    });
    expect(await db.query(DatabaseSchema.draftsTable), hasLength(1));
  });

  test('chat_id is the PK: replace-upsert keeps one draft per chat', () async {
    final db = await factory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(DatabaseSchema.createDraftsTable);

    for (final text in ['first', 'second']) {
      await db.insert(
        DatabaseSchema.draftsTable,
        {
          'chat_id': 'c1',
          'updated_at': '2026-07-11T00:00:00Z',
          'encrypted_data': text,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final rows = await db.query(DatabaseSchema.draftsTable);
    expect(rows, hasLength(1));
    expect(rows.single['encrypted_data'], 'second');

    await db.delete(
      DatabaseSchema.draftsTable,
      where: 'chat_id = ?',
      whereArgs: ['c1'],
    );
    expect(await db.query(DatabaseSchema.draftsTable), isEmpty);
  });
}
