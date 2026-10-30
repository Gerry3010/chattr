// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/database/database_schema.dart';
import '../../core/database/database_service.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/encryption_service.dart';
import '../../core/security/security_providers.dart';
import '../profiles/profile_model.dart';

/// Who is in which chat and what they are called, kept on the device
/// (CHAT-62).
///
/// A 1:1 has no name of its own: its title is the peer's username, found via
/// the member list and the peer's profile. Both used to come from the server
/// only and lived in memory, so a start without network titled every 1:1
/// "Chat `<id>`" in the list, the header and the search, and painted it in the
/// chat's colour instead of the person's.
///
/// What is stored is a display cache, never an authority: sending encrypts to
/// keys fetched separately, and everything that pins or compares identity keys
/// fetches the profile fresh (see `ProfilesController`).
abstract class RosterStore {
  Future<Map<String, List<String>>> loadMembers();
  Future<void> saveMembers(String chatId, List<String> memberIds);
  Future<void> deleteMembers(String chatId);

  Future<Map<String, Profile>> loadProfiles();
  Future<void> saveProfiles(Iterable<Profile> profiles);
  Future<void> deleteProfiles(Iterable<String> userIds);

  /// Logout and wipe: the roster is a social graph and must not outlive the
  /// account on the device.
  Future<void> clearAll();
}

/// The roster in the app's SQLite, in the same encrypted blob format as chats.
class SqliteRosterStore implements RosterStore {
  SqliteRosterStore(this._db, this._crypto);

  final DatabaseService _db;
  final EncryptionService _crypto;

  @override
  Future<Map<String, List<String>>> loadMembers() async {
    final db = await _db.database;
    final rows = await db.query(DatabaseSchema.chatMembersCacheTable);
    final result = <String, List<String>>{};
    for (final row in rows) {
      final json = await _crypto.decryptJson(row['encrypted_data'] as String);
      final ids = json?['m'];
      if (ids is List) {
        result[row['chat_id'] as String] = [
          for (final id in ids)
            if (id is String) id,
        ];
      }
    }
    return result;
  }

  @override
  Future<void> saveMembers(String chatId, List<String> memberIds) async {
    final data = await _crypto.encryptJson({'m': memberIds});
    if (data == null) return;
    final db = await _db.database;
    await db.insert(
      DatabaseSchema.chatMembersCacheTable,
      {'chat_id': chatId, 'encrypted_data': data},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteMembers(String chatId) async {
    final db = await _db.database;
    await db.delete(
      DatabaseSchema.chatMembersCacheTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }

  @override
  Future<Map<String, Profile>> loadProfiles() async {
    final db = await _db.database;
    final rows = await db.query(DatabaseSchema.profilesCacheTable);
    final result = <String, Profile>{};
    for (final row in rows) {
      final json = await _crypto.decryptJson(row['encrypted_data'] as String);
      if (json == null) continue;
      try {
        final profile = Profile.fromJson(json);
        result[profile.id] = profile;
      } catch (_) {
        // A row from an older shape: skip it, the next fetch rewrites it.
      }
    }
    return result;
  }

  @override
  Future<void> saveProfiles(Iterable<Profile> profiles) async {
    final rows = <Map<String, Object?>>[];
    for (final profile in profiles) {
      if (!profile.exists) continue;
      final data = await _crypto.encryptJson(profile.toJson());
      if (data != null) rows.add({'id': profile.id, 'encrypted_data': data});
    }
    if (rows.isEmpty) return;
    final db = await _db.database;
    final batch = db.batch();
    for (final row in rows) {
      batch.insert(
        DatabaseSchema.profilesCacheTable,
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> deleteProfiles(Iterable<String> userIds) async {
    final ids = userIds.toList();
    if (ids.isEmpty) return;
    final db = await _db.database;
    await db.delete(
      DatabaseSchema.profilesCacheTable,
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  @override
  Future<void> clearAll() async {
    final db = await _db.database;
    await db.delete(DatabaseSchema.chatMembersCacheTable);
    await db.delete(DatabaseSchema.profilesCacheTable);
  }
}

final rosterStoreProvider = Provider<RosterStore>((ref) {
  return SqliteRosterStore(
    ref.read(databaseServiceProvider),
    ref.read(encryptionServiceProvider),
  );
});

/// The member lists in memory, backed by [RosterStore].
///
/// Read by `chatMembersProvider`, which serves a known list at once and
/// confirms it with the server in the background.
class ChatMembersCache {
  ChatMembersCache(this._store);

  final RosterStore _store;
  final Map<String, List<String>> _members = {};

  List<String>? membersOf(String chatId) => _members[chatId];

  /// Fill from disk. Never overrides a list the server already answered with
  /// in this session.
  void hydrate(Map<String, List<String>> stored) {
    for (final entry in stored.entries) {
      if (entry.value.isEmpty) continue;
      _members.putIfAbsent(entry.key, () => List.unmodifiable(entry.value));
    }
  }

  /// Record the server's answer. Returns whether anything changed, which is
  /// what decides if a list already handed out has to be replaced.
  ///
  /// An empty answer means we are no longer a member (we would see ourselves
  /// otherwise), so it removes the entry instead of storing an empty list.
  bool put(String chatId, List<String> memberIds) {
    if (memberIds.isEmpty) return forget(chatId);
    final known = _members[chatId];
    if (known != null && setEquals(known.toSet(), memberIds.toSet())) {
      return false;
    }
    _members[chatId] = List.unmodifiable(memberIds);
    unawaited(_guard(_store.saveMembers(chatId, memberIds)));
    return true;
  }

  bool forget(String chatId) {
    final had = _members.remove(chatId) != null;
    if (had) unawaited(_guard(_store.deleteMembers(chatId)));
    return had;
  }

  void clear() => _members.clear();

  Future<void> _guard(Future<void> write) async {
    try {
      await write;
    } catch (e) {
      // A cache that could not be written costs the name on the next
      // offline start, nothing more.
      logger.warning('Roster write failed: $e', tag: 'ChatMembersCache');
    }
  }
}

final chatMembersCacheProvider = Provider<ChatMembersCache>((ref) {
  return ChatMembersCache(ref.read(rosterStoreProvider));
});
