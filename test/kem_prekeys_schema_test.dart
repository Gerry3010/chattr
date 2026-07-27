// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/database/database_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema-level coverage for the one-time KEM prekey table (DB version 7,
/// forward secrecy P3): fresh create, the v6→v7 upgrade path, and the
/// FS-critical delete semantics (a consumed prekey's private half is gone for
/// good — the whole point of the feature).
void main() {
  sqfliteFfiInit();
  final factory = databaseFactoryFfi;

  test('fresh create includes the kem_prekeys table', () async {
    final db = await factory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(DatabaseSchema.createKemPrekeysTable);
    await db.execute(DatabaseSchema.createKemPrekeysChatIdIndex);

    await db.insert(DatabaseSchema.kemPrekeysTable, {
      'prekey_id': 'pk1',
      'chat_id': 'c1',
      'encrypted_data': 'iv:cipher',
      'created_at': '2026-07-17T00:00:00Z',
    });
    expect(await db.query(DatabaseSchema.kemPrekeysTable), hasLength(1));
  });

  test('v6 → v7 upgrade adds the kem_prekeys table', () async {
    // Simulate a v6 database (no prekey table), then run the v7 migration step
    // exactly as DatabaseService._onUpgrade does.
    final db = await factory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseSchema.version,
        onCreate: (db, version) async {
          await db.execute(DatabaseSchema.createChatsTable);
          await db.execute(DatabaseSchema.createDraftsTable);
          // v6 had no kem_prekeys table.
        },
      ),
    );
    addTearDown(db.close);

    await db.execute(DatabaseSchema.createKemPrekeysTable);
    await db.execute(DatabaseSchema.createKemPrekeysChatIdIndex);

    await db.insert(DatabaseSchema.kemPrekeysTable, {
      'prekey_id': 'pk1',
      'chat_id': 'c1',
      'encrypted_data': 'iv:cipher',
      'created_at': '2026-07-17T00:00:00Z',
    });
    expect(await db.query(DatabaseSchema.kemPrekeysTable), hasLength(1));
  });

  test('v7(old x_priv/m_priv) → v8 drop+recreate converges on encrypted_data',
      () async {
    final db = await factory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    // Simulate a device stuck on the never-released OLD v7 shape.
    await db.execute('''
      CREATE TABLE ${DatabaseSchema.kemPrekeysTable} (
        prekey_id TEXT PRIMARY KEY, chat_id TEXT NOT NULL,
        x_priv TEXT NOT NULL, m_priv TEXT NOT NULL, created_at TEXT NOT NULL)
    ''');
    await db.insert(DatabaseSchema.kemPrekeysTable, {
      'prekey_id': 'old', 'chat_id': 'c', 'x_priv': 'x', 'm_priv': 'm',
      'created_at': '2026-07-17T00:00:00Z',
    });

    // Run the v8 migration step exactly as DatabaseService._onUpgrade does.
    await db.execute('DROP TABLE IF EXISTS ${DatabaseSchema.kemPrekeysTable}');
    await db.execute(DatabaseSchema.createKemPrekeysTable);
    await db.execute(DatabaseSchema.createKemPrekeysChatIdIndex);

    // Old (cleartext-column) rows are gone; the new encrypted_data shape works.
    expect(await db.query(DatabaseSchema.kemPrekeysTable), isEmpty);
    await db.insert(DatabaseSchema.kemPrekeysTable, {
      'prekey_id': 'new', 'chat_id': 'c',
      'encrypted_data': 'iv:cipher', 'created_at': '2026-07-17T00:00:00Z',
    });
    expect(await db.query(DatabaseSchema.kemPrekeysTable), hasLength(1));
  });

  test('prekey_id is the PK and delete removes the private half (FS act)',
      () async {
    final db = await factory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(DatabaseSchema.createKemPrekeysTable);

    for (final id in ['pk1', 'pk2', 'pk3']) {
      await db.insert(DatabaseSchema.kemPrekeysTable, {
        'prekey_id': id,
        'chat_id': 'c1',
        'encrypted_data': 'iv:cipher_$id',
        'created_at': '2026-07-17T00:00:00Z',
      });
    }
    expect(await db.query(DatabaseSchema.kemPrekeysTable), hasLength(3));

    // Consuming pk2 wipes ONLY pk2 — its private half is gone, the others stay.
    final removed = await db.delete(
      DatabaseSchema.kemPrekeysTable,
      where: 'prekey_id = ?',
      whereArgs: ['pk2'],
    );
    expect(removed, 1);
    final left = await db.query(DatabaseSchema.kemPrekeysTable);
    expect(left.map((r) => r['prekey_id']), unorderedEquals(['pk1', 'pk3']));

    // A second delete of the same prekey is a no-op (0 rows) — the FS guarantee:
    // once consumed, the key material cannot be re-read or re-deleted.
    final again = await db.delete(
      DatabaseSchema.kemPrekeysTable,
      where: 'prekey_id = ?',
      whereArgs: ['pk2'],
    );
    expect(again, 0);
  });
}
