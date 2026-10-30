// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../calls/call_log.dart' show callLogActions, callMissed;
import 'package:sqflite/sqflite.dart';
import '../../core/database/database_service.dart';
import '../../core/database/database_schema.dart';
import '../../core/security/encryption_service.dart';
import '../../core/security/key_locked_exception.dart';
import '../media/media_attachment.dart';
import 'message_expiry.dart';
import 'message_model.dart';
import 'message_search_text.dart';
import 'message_ordering.dart';
import '../media/shot_envelope.dart';

/// Was [message] written by someone other than [myUserId]?
///
/// This is the whole rule behind the `is_incoming` column and therefore behind
/// the unread count. A system message has no human sender — `senderId` returns
/// its systemId — so it counts as incoming, which is what the server-side count
/// did too (system rows are inserted per recipient like any other).
///
/// With no signed-in user id we answer **false**. That is the safe direction: a
/// wrong `false` costs a badge that should have shown, a wrong `true` invents
/// unread messages the user cannot clear — opening the chat would set the read
/// marker past them, but the badge would have lied in the meantime.
bool isIncomingMessage(MessageInterface message, String? myUserId) {
  if (myUserId == null || myUserId.isEmpty) return false;
  // Call entries are written by this device about this device's own calls
  // (call_log.dart). Only a missed call is news; an outgoing call or one we
  // took must not light up the unread badge for ourselves.
  if (message is SystemMessage && callLogActions.contains(message.action)) {
    return message.action == callMissed;
  }
  return message.senderId != myUserId;
}

/// Messages Local Repository
///
/// Manages encrypted storage of messages in local database
class MessagesLocalRepository {
  final DatabaseService _dbService;
  final EncryptionService _encryptionService;

  /// The signed-in user id, read lazily on every use: the repository outlives a
  /// sign-out, and a stale id would mis-label a message's direction.
  final String? Function()? _currentUserId;

  /// The third argument supplies the signed-in user id (see [_currentUserId]);
  /// omitting it leaves every message labelled outgoing, which only costs the
  /// unread count — used by tests that never look at it.
  MessagesLocalRepository(
    this._dbService,
    this._encryptionService, [
    this._currentUserId,
  ]);

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

    // Same idea for the direction, which drives the unread count. A system
    // message has no human sender (`senderId` is its systemId), so it counts as
    // incoming — matching what the server-side count did.
    final isIncoming = _isIncoming(message) ? 1 : 0;

    if (update) {
      // Update existing message
      final updateCount = await db.update(
        DatabaseSchema.messagesTable,
        {
          'encrypted_data': encryptedData,
          'is_favorite': isFavorite,
          'is_incoming': isIncoming,
        },
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
        'is_incoming': isIncoming,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (rowId == 0) {
        throw Exception('Failed to insert message');
      }
    }
  }

  bool _isIncoming(MessageInterface message) =>
      isIncomingMessage(message, _currentUserId?.call());

  /// Loads favorited messages, newest first (#4). Uses the indexed
  /// `is_favorite` column so only the flagged rows are decrypted.
  ///
  /// [chatId] narrows it to one chat (the section "in this chat"), `null` spans
  /// all. The compound filter costs nothing extra: both columns sit in the
  /// clear next to the ciphertext, and what is decrypted is still only what
  /// remains.
  Future<List<Message>> getFavoriteMessages({String? chatId}) async {
    final db = await _dbService.database;
    final rows = await db.query(
      DatabaseSchema.messagesTable,
      where: chatId == null ? 'is_favorite = 1' : 'is_favorite = 1 AND chat_id = ?',
      whereArgs: chatId == null ? null : [chatId],
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

  /// How many favorites this chat has — WITHOUT decrypting a single row. The
  /// number stands in a section header and must not cost what opening the list
  /// costs.
  Future<int> countFavorites(String chatId) async {
    final db = await _dbService.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${DatabaseSchema.messagesTable} '
      'WHERE is_favorite = 1 AND chat_id = ?',
      [chatId],
    );
    return (rows.first['n'] as int?) ?? 0;
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

  /// A chat's media messages, newest first — the basis for "media & files".
  ///
  /// Filtering happens while decrypting, not in SQL: whether a message carries
  /// a file is inside the ciphertext. A plaintext column would be faster, but
  /// in the locally still unencrypted database (#119) it would reveal per row
  /// that a file hangs there — after the envelope padding, which is meant to
  /// take away exactly such inferences, that would be a step backwards. The in-
  /// chat search takes the same route anyway.
  ///
  /// [scanLimit] bounds how many rows are touched for this. The caller learns
  /// via `complete` whether it has seen everything — a silent truncation would
  /// make an incomplete list look like a complete one.
  Future<({List<Message> matches, bool complete})> getMediaMessages(
    String chatId, {
    int scanLimit = 1000,
  }) async {
    final db = await _dbService.database;
    final rows = await db.query(
      DatabaseSchema.messagesTable,
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at DESC',
      limit: scanLimit + 1,
    );
    final complete = rows.length <= scanLimit;

    final matches = <Message>[];
    for (final row in rows.take(scanLimit)) {
      final encryptedData = row['encrypted_data'] as String;
      // A single broken or unreadable row must not tip the whole list over.
      try {
        final decryptedJson = await _encryptionService.decryptJson(encryptedData);
        if (decryptedJson == null) continue;
        final msg = MessageInterface.fromJson(decryptedJson);
        if (msg is! Message) continue;
        if (MediaAlbum.tryParse(msg.decryptedContent) == null) continue;
        matches.add(msg);
      } catch (_) {
        continue;
      }
    }
    return (matches: matches, complete: complete);
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
        // Not raw over the body: a media envelope is JSON, and "jpg" or "items"
        // appear in every one of them. The search runs over the readable part —
        // see [durchsuchbarerText].
        .where((m) => matchesSearch(m.decryptedContent, q))
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
      if (matchesSearch(message.decryptedContent, q)) {
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
  ///
  /// Additionally covers the **shots** (1.27): their content burns on opening,
  /// but the badge still stands — and that disappears a day later on both
  /// sides. The deadline hangs on the read mark and not on a field of its own,
  /// so sender and recipient use the same clock (see [shotDisappearsAt]).
  Future<List<String>> deleteExpiredMessages(String chatId) async {
    final now = DateTime.timestamp();
    final all = await loadAllMessages(chatId);
    final expiredIds = <String>[];
    for (final m in all) {
      if (m is! Message) continue;
      // Self-destruct OR shot afterlife — the rule lives in [messageGoesAt] and
      // applies to this pass as it does to the five-second tick in the
      // controller.
      if (messageIsGone(m, now)) expiredIds.add(m.id);
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

  /// Instant from which chats without their own read marker start counting —
  /// stamped once by the v9→v10 upgrade (see [DatabaseSchema.unreadEpochKey]).
  /// Absent on a fresh install, where everything incoming is genuinely unread.
  Future<DateTime?> getUnreadEpoch() =>
      getLastSyncTimestamp(DatabaseSchema.unreadEpochKey);

  /// `created_at` of the newest message this device actually holds for [chatId],
  /// or null for a chat with no messages yet.
  ///
  /// This is what the read marker is stamped from — see
  /// [ChatsController.resetUnreadCount] for why "now" was the wrong answer.
  Future<DateTime?> latestMessageCreatedAt(String chatId) async {
    final db = await _dbService.database;
    final rows = await db.rawQuery(
      'SELECT MAX(created_at) AS newest FROM ${DatabaseSchema.messagesTable} '
      'WHERE chat_id = ?',
      [chatId],
    );
    final raw = rows.isEmpty ? null : rows.first['newest'];
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  /// Which of [ids] still exist locally, for the media orphan sweep.
  Future<Set<String>> existingMessageIds(Set<String> ids) async {
    if (ids.isEmpty) return const {};
    final db = await _dbService.database;
    final out = <String>{};
    final list = ids.toList();
    // SQLite caps bound parameters (999 on older builds): ask in slices.
    for (var i = 0; i < list.length; i += 500) {
      final slice = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
      final rows = await db.rawQuery(
        'SELECT id FROM ${DatabaseSchema.messagesTable} '
        'WHERE id IN (${List.filled(slice.length, '?').join(',')})',
        slice,
      );
      out.addAll(rows.map((r) => r['id']! as String));
    }
    return out;
  }

  Future<int> messageCount() async {
    final db = await _dbService.database;
    final rows = await db
        .rawQuery('SELECT COUNT(*) AS n FROM ${DatabaseSchema.messagesTable}');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Unread messages per chat, counted locally.
  ///
  /// This replaces the server's `unread_count` (migration 00053), which needed
  /// `chat_members.last_read_at` — a server-side record of *when* the user
  /// opened *which* chat, not derivable from anything the server must know
  /// anyway. Everything needed to count is on the device already.
  ///
  /// [lastReadAt] is the per-chat "I opened this" marker; chats missing one
  /// fall back to [fallback] (the unread epoch). Chats are handed in rather
  /// than discovered so the caller stays the single source of truth for which
  /// chats exist.
  Future<Map<String, int>> countUnread(
    Map<String, DateTime?> lastReadAt, {
    DateTime? fallback,
  }) async {
    if (lastReadAt.isEmpty) return const {};
    final db = await _dbService.database;

    final counts = <String, int>{};
    for (final entry in lastReadAt.entries) {
      final since = entry.value ?? fallback;
      // No marker and no epoch → count everything incoming (fresh install).
      final sinceIso =
          (since ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true))
              .toUtc()
              .toIso8601String();
      final rows = await db.rawQuery(
        DatabaseSchema.countUnreadSql,
        [entry.key, sinceIso],
      );
      counts[entry.key] = Sqflite.firstIntValue(rows) ?? 0;
    }
    return counts;
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
