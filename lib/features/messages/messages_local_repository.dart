// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:sqflite/sqflite.dart';
import '../../core/database/database_service.dart';
import '../../core/database/database_schema.dart';
import '../../core/security/encryption_service.dart';
import '../../core/security/key_locked_exception.dart';
import 'message_model.dart';
import 'message_ordering.dart';

/// Messages Local Repository
///
/// Manages encrypted storage of messages in local database
class MessagesLocalRepository {
  final DatabaseService _dbService;
  final EncryptionService _encryptionService;

  MessagesLocalRepository(this._dbService, this._encryptionService);

  /// Save message to local database
  Future<void> saveMessage(
    MessageInterface message, {
    bool update = false,
  }) async {
    final db = await _dbService.database;

    // Encrypt message data
    final encryptedData = await _encryptionService.encryptJson(
      message.toJson(),
    );
    if (encryptedData == null) {
      throw Exception('Failed to encrypt message data');
    }

    // Mirror the (local-only) favorite flag to the indexed column so the
    // favorites view can query without decrypting every row (#4).
    final isFavorite = message is Message && message.isFavorite ? 1 : 0;

    if (update) {
      // Update existing message
      final updateCount = await db.update(
        DatabaseSchema.messagesTable,
        {'encrypted_data': encryptedData, 'is_favorite': isFavorite},
        where: 'id = ?',
        whereArgs: [message.id],
      );
      if (updateCount == 0) {
        throw Exception('Failed to update message');
      }
    } else {
      // Insert or replace
      final rowId = await db.insert(DatabaseSchema.messagesTable, {
        'id': message.id,
        'chat_id': message.chatId,
        'created_at': message.createdAt.toIso8601String(),
        'encrypted_data': encryptedData,
        'is_favorite': isFavorite,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (rowId == 0) {
        throw Exception('Failed to insert message');
      }
    }
  }

  /// Loads all favorited messages across every chat, newest first (#4). Uses
  /// the indexed `is_favorite` column so only the flagged rows are decrypted.
  Future<List<Message>> getFavoriteMessages() async {
    final db = await _dbService.database;
    final rows = await db.query(
      DatabaseSchema.messagesTable,
      where: 'is_favorite = 1',
      orderBy: 'created_at DESC',
    );
    final messages = <Message>[];
    for (final row in rows) {
      final encryptedData = row['encrypted_data'] as String;
      final decryptedJson = await _encryptionService.decryptJson(encryptedData);
      if (decryptedJson == null) continue;
      final msg = MessageInterface.fromJson(decryptedJson);
      if (msg is Message) messages.add(msg);
    }
    return messages;
  }

  /// Loads a message from the local database
  Future<MessageInterface?> getMessage(String chatId, String messageId) async {
    final db = await _dbService.database;

    final results = await db.query(
      DatabaseSchema.messagesTable,
      where: 'chat_id = ? AND id = ?',
      whereArgs: [chatId, messageId],
      limit: 1,
    );

    // Decrypt and parse
    final message = results.firstOrNull;
    if (message == null) {
      return null;
    }
    final encryptedData = message['encrypted_data'] as String;
    final decryptedJson = await _encryptionService.decryptJson(encryptedData);

    if (decryptedJson == null) {
      return null;
    }
    return MessageInterface.fromJson(decryptedJson);
  }

  /// Load messages for a specific chat with pagination
  /// Returns the most recent [limit] messages, optionally before the
  /// ([beforeDate], [beforeId]) keyset cursor.
  ///
  /// Ordering uses the composite key `(created_at, id)`, not `created_at`
  /// alone: `created_at` is not unique (ms/us collisions, plus mixed
  /// client-clock vs server-`NOW()` timestamps), so a plain `created_at < ?`
  /// cursor could skip or duplicate messages that share a timestamp at a page
  /// boundary. Pass [beforeId] (the id of the oldest already-loaded message) to
  /// page deterministically.
  Future<List<MessageInterface>> loadMessages(
    String chatId, {
    int limit = 50,
    DateTime? beforeDate,
    String? beforeId,
  }) async {
    final db = await _dbService.database;

    // Build query with keyset pagination
    String whereClause = 'chat_id = ?';
    List<dynamic> whereArgs = [chatId];

    if (beforeDate != null) {
      final before = beforeDate.toIso8601String();
      if (beforeId != null) {
        // Keyset on (created_at, id): everything strictly older than the cursor.
        whereClause += ' AND (created_at < ? OR (created_at = ? AND id < ?))';
        whereArgs.addAll([before, before, beforeId]);
      } else {
        whereClause += ' AND created_at < ?';
        whereArgs.add(before);
      }
    }

    // Query messages for chat (DESC order to get most recent first). The `id`
    // tiebreak matches the keyset above so paging is stable across ties.
    final results = await db.query(
      DatabaseSchema.messagesTable,
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );

    // Decrypt and parse
    final messages = <MessageInterface>[];
    for (final row in results) {
      final encryptedData = row['encrypted_data'] as String;
      final decryptedJson = await _encryptionService.decryptJson(encryptedData);

      if (decryptedJson != null) {
        messages.add(MessageInterface.fromJson(decryptedJson));
      }
    }

    // Reverse to get chronological order (oldest to newest)
    return messages.reversed.toList();
  }

  /// Load all messages for a specific chat (without pagination)
  /// Use this only for exports or special cases
  Future<List<MessageInterface>> loadAllMessages(String chatId) async {
    final db = await _dbService.database;

    // Query all messages for chat
    final results = await db.query(
      DatabaseSchema.messagesTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at ASC',
    );

    // Decrypt and parse
    final messages = <MessageInterface>[];
    for (final row in results) {
      final encryptedData = row['encrypted_data'] as String;
      final decryptedJson = await _encryptionService.decryptJson(encryptedData);

      if (decryptedJson != null) {
        messages.add(MessageInterface.fromJson(decryptedJson));
      }
    }

    return messages;
  }

  /// Search messages in a chat by decrypted text content.
  ///
  /// Messages are stored encrypted at rest, so this decrypts in-memory and
  /// filters by a case-insensitive substring match — the server never has the
  /// plaintext. Returns newest-first.
  Future<List<Message>> searchMessages(String chatId, String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    final all = await loadAllMessages(chatId);
    final matches = all
        .whereType<Message>()
        .where((m) => (m.decryptedContent ?? '').toLowerCase().contains(q))
        .toList()
      ..sort(
        (a, b) =>
            compareMessagesNewestFirst(a.createdAt, a.id, b.createdAt, b.id),
      );
    return matches;
  }

  /// Global search across ALL chats' locally-decrypted messages.
  ///
  /// Content is AES-encrypted at rest with a random IV per row, so no SQL LIKE
  /// is possible — every row is decrypted in memory and substring-matched.
  /// Newest-first, capped at [limit] to bound the cost on large stores.
  Future<List<Message>> searchAllMessages(String query, {int limit = 100}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];

    final db = await _dbService.database;
    // Newest rows first so an early cap keeps the most recent hits.
    final results = await db.query(
      DatabaseSchema.messagesTable,
      orderBy: 'created_at DESC',
    );

    final matches = <Message>[];
    for (final row in results) {
      final decryptedJson =
          await _encryptionService.decryptJson(row['encrypted_data'] as String);
      if (decryptedJson == null) continue;
      final message = MessageInterface.fromJson(decryptedJson);
      if (message is! Message) continue;
      if ((message.decryptedContent ?? '').toLowerCase().contains(q)) {
        matches.add(message);
        if (matches.length >= limit) break;
      }
    }
    return matches;
  }

  /// Delete locally-stored messages whose self-destruct time has passed.
  /// Returns the ids that were removed so the controller can update its state.
  /// (The server-side pg_cron reaper handles the server rows + propagation;
  /// this keeps the decrypted local copy in sync, e.g. for the sender.)
  Future<List<String>> deleteExpiredMessages(String chatId) async {
    final now = DateTime.timestamp();
    final all = await loadAllMessages(chatId);
    final expiredIds = <String>[];
    for (final m in all) {
      if (m is Message && m.expiresAt != null && m.expiresAt!.isBefore(now)) {
        expiredIds.add(m.id);
      }
    }
    for (final id in expiredIds) {
      await deleteMessage(chatId, id);
    }
    return expiredIds;
  }

  /// Load message ids for a specific chat
  Future<Set<String>> loadMessageIds(String chatId) async {
    final db = await _dbService.database;

    final results = await db.query(
      DatabaseSchema.messagesTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
      columns: ['id'],
      distinct: true,
    );

    return results.map((row) => row['id'] as String).toSet();
  }

  /// Delete message from local database
  Future<void> deleteMessage(String chatId, String messageId) async {
    final db = await _dbService.database;

    await db.delete(
      DatabaseSchema.messagesTable,
      where: 'id = ? AND chat_id = ?',
      whereArgs: [messageId, chatId],
    );
  }

  /// Delete all messages for a specific chat
  Future<int> deleteMessagesForChat(String chatId) async {
    final db = await _dbService.database;

    return await db.delete(
      DatabaseSchema.messagesTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }

  /// Clear all messages from local database
  Future<void> clearAll() async {
    final db = await _dbService.database;

    await db.delete(DatabaseSchema.messagesTable);
    await db.delete(DatabaseSchema.syncMetadataTable);
  }

  /// Check if message exists in local database
  Future<bool> hasMessage(String messageId) async {
    final db = await _dbService.database;

    final result = await db.query(
      DatabaseSchema.messagesTable,
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );

    return result.isNotEmpty;
  }

  /// Get message count for a chat
  Future<int> getMessageCount(String chatId) async {
    final db = await _dbService.database;

    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM ${DatabaseSchema.messagesTable} WHERE chat_id = ?',
      [chatId],
    );

    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Get last sync timestamp for a chat
  /// Returns null if never synced
  Future<DateTime?> getLastSyncTimestamp(String chatId) async {
    final db = await _dbService.database;

    final results = await db.query(
      DatabaseSchema.syncMetadataTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
      limit: 1,
    );

    if (results.isEmpty) {
      return null;
    }

    final timestampStr = results.first['last_sync_timestamp'] as String;
    return DateTime.parse(timestampStr);
  }

  /// Set last sync timestamp for a chat
  Future<void> setLastSyncTimestamp(String chatId, DateTime timestamp) async {
    final db = await _dbService.database;

    await db.insert(
      DatabaseSchema.syncMetadataTable,
      {'chat_id': chatId, 'last_sync_timestamp': timestamp.toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// App-global watermark for the sent-receipts reconcile (see
  /// [GlobalMessageHandler.reconcileSentReceipts]). Stored in the same
  /// key-value sync table under a reserved sentinel key (not a real chat id;
  /// the table has no FK), so it survives restarts and bounds the backfill
  /// query to statuses that changed since the last successful reconcile.
  static const String sentReceiptsWatermarkKey = '__sent_receipts_reconcile__';

  Future<DateTime?> getSentReceiptsWatermark() =>
      getLastSyncTimestamp(sentReceiptsWatermarkKey);

  Future<void> setSentReceiptsWatermark(DateTime timestamp) =>
      setLastSyncTimestamp(sentReceiptsWatermarkKey, timestamp);

  /// Mark message as received (when fetched from server)
  Future<void> markAsReceived(
    String chatId,
    String messageId,
    String userId, {
    DateTime? timestamp,
  }) async {
    final MessageInterface? message;
    try {
      message = await getMessage(chatId, messageId);
    } on KeyLockedException {
      // Content key locked (app lock): skip the receipt for now. No data is
      // lost — the server copy remains and the receipt is re-recorded after
      // unlock; only the confirmation is delayed.
      return;
    }
    if (message == null) {
      return;
    }
    await saveMessage(
      message.copyWith(
        receivedAt: {
          ...message.receivedAt,
          // Store UTC so it round-trips consistently (parse → display .toLocal()).
          userId: timestamp ?? DateTime.now().toUtc(),
        },
      ),
    );
  }

  Future<void> markAsRead(
    String chatId,
    String messageId,
    String userId, {
    DateTime? timestamp,
  }) async {
    final MessageInterface? message;
    try {
      message = await getMessage(chatId, messageId);
    } on KeyLockedException {
      // Locked: skip the read receipt for now (no loss, re-recorded on unlock).
      return;
    }
    if (message == null) {
      return;
    }
    await saveMessage(
      message.copyWith(
        // Store UTC so it round-trips consistently (parse → display .toLocal()).
        readAt: {...message.readAt, userId: timestamp ?? DateTime.now().toUtc()},
      ),
    );
  }
}
