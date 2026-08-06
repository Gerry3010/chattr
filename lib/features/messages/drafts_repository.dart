// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/database/database_schema.dart';
import '../../core/database/database_service.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/encryption_service.dart';
import '../../core/security/security_providers.dart';

/// Persists unsent composer text per chat so a draft survives leaving the
/// chat and app restarts. Drafts are plaintext of not-yet-sent messages, so
/// they use the same encrypted-blob storage as chats/messages.
class DraftsRepository {
  final DatabaseService _dbService;
  final EncryptionService _encryptionService;

  DraftsRepository(this._dbService, this._encryptionService);

  /// Returns the stored draft text for [chatId], or null if none.
  Future<String?> getDraft(String chatId) async {
    try {
      final db = await _dbService.database;
      final rows = await db.query(
        DatabaseSchema.draftsTable,
        where: 'chat_id = ?',
        whereArgs: [chatId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final decrypted = await _encryptionService
          .decryptJson(rows.first['encrypted_data'] as String);
      final text = decrypted?['text'] as String?;
      return (text == null || text.isEmpty) ? null : text;
    } catch (e) {
      // Best-effort: a broken draft must never break opening the chat.
      logger.warning('Failed to load draft for $chatId: $e', tag: 'Drafts');
      return null;
    }
  }

  /// Saves (or clears, when [text] is empty) the draft for [chatId].
  Future<void> saveDraft(String chatId, String text) async {
    if (text.trim().isEmpty) {
      return deleteDraft(chatId);
    }
    try {
      final encrypted = await _encryptionService.encryptJson({'text': text});
      if (encrypted == null) return;
      final db = await _dbService.database;
      await db.insert(
        DatabaseSchema.draftsTable,
        {
          'chat_id': chatId,
          'updated_at': DateTime.timestamp().toIso8601String(),
          'encrypted_data': encrypted,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      logger.warning('Failed to save draft for $chatId: $e', tag: 'Drafts');
    }
  }

  /// Removes the draft for [chatId] (after sending, or when cleared).
  Future<void> deleteDraft(String chatId) async {
    try {
      final db = await _dbService.database;
      await db.delete(
        DatabaseSchema.draftsTable,
        where: 'chat_id = ?',
        whereArgs: [chatId],
      );
    } catch (e) {
      logger.warning('Failed to delete draft for $chatId: $e', tag: 'Drafts');
    }
  }
}

/// Provider for the drafts repository.
final draftsRepositoryProvider = Provider<DraftsRepository>((ref) {
  return DraftsRepository(
    ref.read(databaseServiceProvider),
    ref.read(encryptionServiceProvider),
  );
});
