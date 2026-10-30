// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/core.dart';
import 'package:sqflite/sqflite.dart';
import '../../core/database/database_service.dart';
import '../../core/database/database_schema.dart';
import '../../core/security/encryption_service.dart';
import 'chat_model.dart';

/// Chats Local Repository
///
/// Manages encrypted storage of chats in local database
class ChatsLocalRepository {
  final DatabaseService _dbService;
  final EncryptionService _encryptionService;

  ChatsLocalRepository(this._dbService, this._encryptionService);

  /// Save chat to local database
  Future<void> saveChat(Chat chat) async {
    final db = await _dbService.database;

    // Encrypt chat data
    final encryptedData = await _encryptionService.encryptJson(chat.toJson());
    if (encryptedData == null) {
      throw Exception('Failed to encrypt chat data');
    }

    // Insert or replace
    final res = await db.insert(
      DatabaseSchema.chatsTable,
      {
        'id': chat.id,
        'created_at': chat.createdAt.toIso8601String(),
        'encrypted_data': encryptedData,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    logger.debug("Inserted Chat #${chat.id}? Res: $res");
  }

  /// Load all chats from local database
  Future<Map<String, Chat>> loadChats() async {
    final db = await _dbService.database;

    // Query all chats
    final results = await db.query(
      DatabaseSchema.chatsTable,
      orderBy: 'created_at DESC',
    );

    // Decrypt and parse
    final chats = <String, Chat>{};
    for (final row in results) {
      final encryptedData = row['encrypted_data'] as String;
      final decryptedJson = await _encryptionService.decryptJson(encryptedData);
      
      if (decryptedJson != null) {
        final chat = Chat.fromJson(decryptedJson);
        chats[chat.id] = chat;
      }
    }

    return chats;
  }

  /// Delete chat from local database
  Future<void> deleteChat(String chatId) async {
    final db = await _dbService.database;

    await db.delete(
      DatabaseSchema.chatsTable,
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  /// Clear all chats from local database
  Future<void> clearAll() async {
    final db = await _dbService.database;

    await db.delete(DatabaseSchema.chatsTable);
  }

  /// Check if chat exists in local database
  Future<bool> hasChat(String chatId) async {
    final db = await _dbService.database;

    final result = await db.query(
      DatabaseSchema.chatsTable,
      where: 'id = ?',
      whereArgs: [chatId],
      limit: 1,
    );

    return result.isNotEmpty;
  }

  /// Remove a chat locally after it was deleted server-side (chatDeleted event).
  ///
  /// There is no soft-delete column, so this hard-deletes the chat together with
  /// its locally cached messages. Previously this was an empty stub, so deleted
  /// chats kept reappearing on the next loadChats()/refreshChats().
  Future<void> markChatAsDeleted(String chatId) async {
    final db = await _dbService.database;

    await db.delete(
      DatabaseSchema.messagesTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
    await db.delete(
      DatabaseSchema.chatsTable,
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }
}
