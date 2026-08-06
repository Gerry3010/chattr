// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'database_schema.dart';

/// Database Service
///
/// Singleton service managing the SQLite database connection
class DatabaseService {
  static DatabaseService? _instance;
  static Database? _database;

  DatabaseService._();

  /// Get singleton instance
  static DatabaseService get instance {
    _instance ??= DatabaseService._();
    return _instance!;
  }

  /// Get database instance
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// Initialize database
  Future<Database> _initDatabase() async {
    final path = join(await _databasesDir(), DatabaseSchema.databaseName);

    return await openDatabase(
      path,
      version: DatabaseSchema.version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Directory that holds the SQLite file.
  ///
  /// On desktop, `sqflite_common_ffi`'s [getDatabasesPath] is **relative to the
  /// current working directory** (`.dart_tool/sqflite_common_ffi/databases`),
  /// so the DB would live inside the build output — lost on every rebuild and
  /// inconsistent depending on where the app is launched from. Anchor it to a
  /// stable per-user application-support directory instead. Mobile already uses
  /// a private app dir via [getDatabasesPath]; web uses the ffi-web factory
  /// (a logical name, not a real path), so both keep the default.
  Future<String> _databasesDir() async {
    final isDesktop = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (isDesktop) {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    }
    return getDatabasesPath();
  }

  /// Create tables on first launch
  Future<void> _onCreate(Database db, int version) async {
    // Create chats table
    await db.execute(DatabaseSchema.createChatsTable);
    await db.execute(DatabaseSchema.createChatsCreatedAtIndex);

    // Create messages table
    await db.execute(DatabaseSchema.createMessagesTable);
    await db.execute(DatabaseSchema.createMessagesChatIdIndex);
    await db.execute(DatabaseSchema.createMessagesCreatedAtIndex);
    await db.execute(DatabaseSchema.createMessagesFavoriteIndex);

    // Create sync metadata table
    await db.execute(DatabaseSchema.createSyncMetadataTable);

    // Create message reactions table
    await db.execute(DatabaseSchema.createMessageReactionsTable);
    await db.execute(DatabaseSchema.createReactionsMessageIdIndex);
    await db.execute(DatabaseSchema.createReactionsUserIdIndex);

    // Create drafts table
    await db.execute(DatabaseSchema.createDraftsTable);

    // Create one-time KEM prekey table (forward secrecy, P3)
    await db.execute(DatabaseSchema.createKemPrekeysTable);
    await db.execute(DatabaseSchema.createKemPrekeysChatIdIndex);
  }

  /// Handle database migrations
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // Migration to version 2: No schema changes needed
    // Admin fields (created_by, admins) are stored in encrypted_data JSON
    // This migration just updates the version number
    if (oldVersion < 2) {
      // No actual schema changes needed - data is stored as encrypted JSON
      // which already supports new fields
    }

    // Migration to version 3: Add sync metadata table
    if (oldVersion < 3) {
      await db.execute(DatabaseSchema.createSyncMetadataTable);
    }

    // Migration to version 4: Add message reactions table
    if (oldVersion < 4) {
      await db.execute(DatabaseSchema.createMessageReactionsTable);
      await db.execute(DatabaseSchema.createReactionsMessageIdIndex);
      await db.execute(DatabaseSchema.createReactionsUserIdIndex);
    }

    // Migration to version 5: Message replies support
    if (oldVersion < 5) {
      // No schema changes needed - reply fields are part of encrypted_data JSON
      // which already supports new fields dynamically
    }

    // Migration to version 6: Message drafts table
    if (oldVersion < 6) {
      await db.execute(DatabaseSchema.createDraftsTable);
    }

    // Migration to version 7: One-time KEM prekeys (forward secrecy, P3)
    if (oldVersion < 7) {
      await db.execute(DatabaseSchema.createKemPrekeysTable);
      await db.execute(DatabaseSchema.createKemPrekeysChatIdIndex);
    }

    // Migration to version 8: kem_prekeys stores an encrypted_data blob instead
    // of cleartext x_priv/m_priv columns. Any device already on the (never
    // released) v7 shape has the old columns; prekeys are ephemeral (republished
    // on next chat open), so drop + recreate to converge on the new shape. A
    // v6→v8 device created the new shape in the v7 step above; this DROP just
    // resets that freshly-created empty table — harmless.
    if (oldVersion < 8) {
      await db.execute('DROP TABLE IF EXISTS ${DatabaseSchema.kemPrekeysTable}');
      await db.execute(DatabaseSchema.createKemPrekeysTable);
      await db.execute(DatabaseSchema.createKemPrekeysChatIdIndex);
    }

    // Migration to version 9: local favorites (#4) — add the is_favorite column
    // + index. The flag also lives in the encrypted blob; this column is a
    // query accelerator for the favorites view.
    if (oldVersion < 9) {
      for (final sql in DatabaseSchema.migrateV8ToV9) {
        await db.execute(sql);
      }
    }
  }

  /// Close database connection
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  /// Delete database (for testing or data wipe)
  Future<void> deleteDatabase() async {
    final path = join(await _databasesDir(), DatabaseSchema.databaseName);
    await databaseFactory.deleteDatabase(path);
    _database = null;
  }
}
