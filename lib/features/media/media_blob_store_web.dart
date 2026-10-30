// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import 'media_blob_store.dart';

MediaBlobStore createMediaBlobStore() => SqliteMediaBlobStore();

/// The web has no file system: blobs go into their own SQLite database (the
/// same IndexedDB-backed engine the app's message database runs on, set up by
/// AppInit), separate from the message database so it needs no migration
/// there and can be dropped whole on logout.
class SqliteMediaBlobStore implements MediaBlobStore {
  static const _name = 'chattr_media_store.db';
  Future<Database>? _db;

  Future<Database> _open() => _db ??= openDatabase(
        _name,
        version: 1,
        onCreate: (db, _) => db.execute(
          'CREATE TABLE blobs ('
          'path TEXT PRIMARY KEY, '
          'chat_id TEXT NOT NULL, '
          'message_id TEXT NOT NULL, '
          'stored_at INTEGER NOT NULL, '
          'data BLOB NOT NULL)',
        ),
      );

  @override
  Future<Uint8List?> read(String path) async {
    if (!isStorableMediaPath(path)) return null;
    final rows = await (await _open())
        .query('blobs', columns: ['data'], where: 'path = ?', whereArgs: [path]);
    if (rows.isEmpty) return null;
    final data = rows.first['data'];
    return data is Uint8List ? data : Uint8List.fromList(data! as List<int>);
  }

  @override
  Future<void> write(String path, Uint8List blob) async {
    if (!isStorableMediaPath(path)) return;
    final parts = path.split('/');
    await (await _open()).insert(
      'blobs',
      {
        'path': path,
        'chat_id': parts[0],
        'message_id': parts[1],
        'stored_at': DateTime.now().millisecondsSinceEpoch,
        'data': blob,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<bool> contains(String path) async {
    if (!isStorableMediaPath(path)) return false;
    final rows = await (await _open())
        .query('blobs', columns: ['path'], where: 'path = ?', whereArgs: [path]);
    return rows.isNotEmpty;
  }

  @override
  Future<void> deleteMessage(String chatId, String messageId) async {
    await (await _open()).delete('blobs',
        where: 'chat_id = ? AND message_id = ?', whereArgs: [chatId, messageId]);
  }

  @override
  Future<Map<String, DateTime>> storedMessages() async {
    final rows = await (await _open()).rawQuery(
        'SELECT chat_id, message_id, MAX(stored_at) AS at FROM blobs '
        'GROUP BY chat_id, message_id');
    return {
      for (final r in rows)
        '${r['chat_id']}/${r['message_id']}':
            DateTime.fromMillisecondsSinceEpoch(r['at']! as int),
    };
  }

  @override
  Future<void> clear() async {
    await (await _open()).delete('blobs');
  }
}
