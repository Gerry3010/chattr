// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/database/database_schema.dart';
import '../../core/database/database_service.dart';
import '../../core/security/encryption_service.dart';
import '../../core/security/security_providers.dart';

/// Local store for the PRIVATE halves of one-time KEM prekeys (forward secrecy,
/// audit P3). The matching public halves are published to the server
/// (`chat_member_prekeys`); the private halves never leave the device.
///
/// A row is DELETED the moment an incoming v5 message consumes its prekey — that
/// deletion is the forward-secrecy act: once gone, a logged ciphertext wrapped
/// to that prekey can never be unwrapped again, even under full device
/// compromise.
///
/// The private key material is stored **encrypted at rest** (audit M4 slice):
/// the `{"x":..,"m":..}` blob is encrypted via [EncryptionService] (AES-256-CBC
/// under the app-side content key, in hardened secure storage) before it touches
/// SQLite, so a private prekey is never in cleartext on disk — independent of
/// whole-file SQLCipher.
class PrekeyLocalRepository {
  final DatabaseService _dbService;
  final EncryptionService _encryptionService;

  PrekeyLocalRepository(this._dbService, this._encryptionService);

  /// Persist one prekey's private key blob (`{"x":..,"m":..}`) under [prekeyId],
  /// encrypted at rest.
  Future<void> insert({
    required String prekeyId,
    required String chatId,
    required String privateBlob,
  }) async {
    final encrypted = await _encryptionService.encrypt(privateBlob);
    if (encrypted == null) {
      throw Exception('Failed to encrypt prekey private for $prekeyId');
    }
    final db = await _dbService.database;
    await db.insert(
      DatabaseSchema.kemPrekeysTable,
      {
        'prekey_id': prekeyId,
        'chat_id': chatId,
        'encrypted_data': encrypted,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The combined private-key blob (`{"x":..,"m":..}`) for [prekeyId], or null
  /// if it was already consumed/deleted (or never existed on this device).
  Future<String?> privateBlobFor(String prekeyId) async {
    final db = await _dbService.database;
    final rows = await db.query(
      DatabaseSchema.kemPrekeysTable,
      columns: ['encrypted_data'],
      where: 'prekey_id = ?',
      whereArgs: [prekeyId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _encryptionService.decrypt(rows.first['encrypted_data'] as String);
  }

  /// Delete a prekey's private half. This is the forward-secrecy act — call it
  /// once, AFTER an incoming v5 message has been successfully decrypted and
  /// persisted. Returns the number of rows removed (0 if already gone).
  Future<int> delete(String prekeyId) async {
    final db = await _dbService.database;
    return db.delete(
      DatabaseSchema.kemPrekeysTable,
      where: 'prekey_id = ?',
      whereArgs: [prekeyId],
    );
  }

  /// Delete every local private prekey for a chat (e.g. on leave / key wipe).
  Future<void> deleteForChat(String chatId) async {
    final db = await _dbService.database;
    await db.delete(
      DatabaseSchema.kemPrekeysTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }
}

final prekeyLocalRepositoryProvider = Provider<PrekeyLocalRepository>((ref) {
  return PrekeyLocalRepository(
    ref.read(databaseServiceProvider),
    ref.read(encryptionServiceProvider),
  );
});
