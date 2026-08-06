// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/logger_service.dart';
import 'message_model.dart';

class MessagesRepository {
  final SupabaseClient client;

  MessagesRepository(this.client);

  Future<List<MessageInterface>> fetchInitial(
    String chatId,
    String currentUserId, {
    DateTime?
    since, // Optional: only fetch messages updated after this timestamp
  }) async {
    var query = client
        .from('messages')
        .select()
        .eq('chat_id', chatId)
        .eq(
          'recipient_id',
          currentUserId,
        ); // Only fetch messages for current user

    // If since timestamp is provided, only fetch messages newer than it.
    // Normalize to UTC: the timestamps are timestamptz stored in UTC, and a
    // naive local timestamp would be read by Postgres as UTC — skipping every
    // message within the local↔UTC offset window. toUtc() makes it correct.
    //
    // `updated_at` is NULL for messages that were never edited (the insert
    // only sets created_at; the column is only stamped on an edit). A plain
    // `.gt('updated_at', since)` drops those — NULL > x is false in SQL — so
    // messages RECEIVED WHILE OFFLINE never synced (the push fired on insert,
    // but the resync silently skipped them). Mirror the watermark's
    // COALESCE(updated_at, created_at) logic: fetch rows edited after `since`,
    // OR never-edited rows created after it.
    if (since != null) {
      final sinceUtc = since.toUtc().toIso8601String();
      query = query.or(
        'updated_at.gt.$sinceUtc,'
        'and(updated_at.is.null,created_at.gt.$sinceUtc)',
      );
    }

    final List<dynamic> res = await query.order('created_at');

    logger.debug('Messages: $res');

    return res.map((dynamic e) {
      final map = e as Map<String, dynamic>;
      return MessageInterface.fromJson(Map<String, dynamic>.from(map));
    }).toList();
  }

  /// Send encrypted message to all recipients
  /// Creates one message row per recipient with their encrypted copy
  /// All copies share the same message ID (composite PK: id + recipient_id)
  Future<String> sendEncryptedMessage({
    required String chatId,
    required String senderId,
    required DateTime createdAt,
    required Map<String, String>
    encryptedForRecipients, // userId -> encrypted content
    String? replyToMessageId,
    String? replyToSenderId,
    String? replyToSenderName,
    // Encrypted preview per recipient (userId -> ciphertext). Must be keyed
    // like [encryptedForRecipients]: each row can only carry the ciphertext
    // its recipient can decrypt (one shared ciphertext meant only one group
    // member could ever read the quote).
    Map<String, String>? replyToPreviews,
    DateTime? expiresAt, // Disappearing messages: when this self-destructs
    String? messageId, // Pre-set id (media uploads need it before insert)
    // Server-visible row type. Null keeps the column default ('user').
    // 'summary' marks machinery so the push trigger skips it (migration
    // 00068) — the server can't tell from the ciphertext alone.
    String? messageType,
  }) async {
    // A single message ID shared by all recipient copies.
    messageId ??= const Uuid().v4();

    // Create message rows for each recipient (all with same id)
    final messageRows = encryptedForRecipients.entries.map((entry) {
      final row = {
        'id': messageId,
        // Same ID for all recipients (composite PK with recipient_id)
        'chat_id': chatId,
        'sender_id': senderId,
        'recipient_id': entry.key,
        'encrypted_content': entry.value,
        'created_at': createdAt.toIso8601String(),
        if (expiresAt != null) 'expires_at': expiresAt.toIso8601String(),
        'message_type': ?messageType,
      };

      // Add reply fields if replying to a message
      if (replyToMessageId != null) {
        row['reply_to_message_id'] = replyToMessageId;
        if (replyToSenderId != null) {
          row['reply_to_sender_id'] = replyToSenderId;
        }
        if (replyToSenderName != null) {
          row['reply_to_sender_name'] = replyToSenderName;
        }
        final preview = replyToPreviews?[entry.key];
        if (preview != null) {
          row['reply_to_preview'] = preview;
        }
      }

      return row;
    }).toList();

    final mapRows = messageRows.cast<Map<String, dynamic>>();

    // Batch insert all encrypted copies
    await client.from('messages').insert(mapRows);

    return messageId;
  }

  /// Edit an existing message: replace each recipient's ciphertext with a
  /// freshly re-encrypted version and stamp edited_at. Goes through the
  /// SECURITY DEFINER RPC `edit_message` — a direct UPDATE can't reach the
  /// sender's rows because the WHERE clause is also subject to the
  /// recipient-only SELECT policy (the statement silently matched 0 rows).
  /// The server-side UPDATE fires notify_message_update (content_changed)
  /// so recipients re-fetch and re-decrypt.
  Future<void> editEncryptedMessage({
    required String chatId,
    required String messageId,
    required Map<String, String> encryptedForRecipients,
  }) async {
    final updated = await client.rpc<int>(
      'edit_message',
      params: {
        'p_message_id': messageId,
        'p_chat_id': chatId,
        'p_contents': encryptedForRecipients,
      },
    );
    if (updated == 0) {
      throw Exception('Edit updated no rows on the server (not the sender?)');
    }
  }

  /// Fetch the current ciphertext (and the edit marker) of a single
  /// recipient's message row. Used to re-decrypt after an edit. Returns null
  /// if the row is gone or the content has already been cleared.
  Future<({String content, DateTime? editedAt})?> fetchEncryptedContent(
    String chatId,
    String messageId,
    String userId,
  ) async {
    final res = await client
        .from('messages')
        .select('encrypted_content, edited_at')
        .eq('id', messageId)
        .eq('chat_id', chatId)
        .eq('recipient_id', userId)
        .limit(1)
        .maybeSingle();
    final content = res?['encrypted_content'] as String?;
    if (content == null || content.isEmpty) return null;
    final editedAtRaw = res?['edited_at'] as String?;
    return (
      content: content,
      editedAt: editedAtRaw != null ? DateTime.parse(editedAtRaw) : null,
    );
  }

  /// Mark message as received (when fetched from server)
  /// Uses DB function to set received_at and clear encrypted_content
  Future<DateTime?> markAsReceived(
    String chatId,
    String messageId,
    String userId,
  ) async {
    try {
      await client.rpc<void>(
        'mark_message_received',
        params: {'p_message_id': messageId, 'p_chat_id': chatId},
      );
    } on PostgrestException catch (e) {
      if (e.code != 'P0001') {
        rethrow;
      }

      final res = await client
          .from('messages')
          .select('received_at')
          .eq('id', messageId)
          .eq('chat_id', chatId)
          .eq('recipient_id', userId)
          .limit(1)
          .maybeSingle();
      if (res == null) {
        return null;
      }
      if (res['received_at'] == null) {
        rethrow;
      }
      return DateTime.parse(res['received_at'] as String);
    }
    return null;
  }

  /// Backfill the delivery/read status of the CURRENT USER'S SENT messages.
  ///
  /// Receipts normally reach the sender only via the realtime broadcast; a
  /// closed client misses it and — since 00010 dropped the sender SELECT policy
  /// — cannot read its own sent rows directly. This calls the status-only
  /// SECURITY DEFINER RPC (00042) which returns every recipient row for the
  /// caller's sent messages (all recipients, so group ticks reconcile), updated
  /// at/after [since] (a client-held watermark; null = all still-tracked rows).
  ///
  /// Returns raw rows: `{id, chat_id, recipient_id, received_at, read_at}`.
  Future<List<Map<String, dynamic>>> fetchSentMessageStatus({
    DateTime? since,
  }) async {
    final res = await client.rpc<dynamic>(
      'get_sent_message_status',
      params: {'p_since': since?.toUtc().toIso8601String()},
    );
    if (res is! List) return const [];
    return res
        .map((dynamic e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Mark message as read (when displayed in chat)
  /// Uses DB function to set read_at and clear encrypted_content
  Future<DateTime?> markAsRead(
    String chatId,
    String messageId,
    String userId,
  ) async {
    try {
      await client.rpc<void>(
        'mark_message_read',
        params: {'p_message_id': messageId, 'p_chat_id': chatId},
      );
    } on PostgrestException catch (e) {
      if (e.code != 'P0001') {
        rethrow;
      }

      final res = await client
          .from('messages')
          .select('read_at')
          .eq('id', messageId)
          .eq('chat_id', chatId)
          .eq('recipient_id', userId)
          .limit(1)
          .maybeSingle();
      if (res == null) {
        return null;
      }
      if (res['read_at'] == null) {
        rethrow;
      }
      return DateTime.parse(res['read_at'] as String);
    }
    return null;
  }

  /// Delete a message for everyone (only if sender and not read yet).
  /// Uses the SECURITY DEFINER RPC `delete_message_for_everyone` — a direct
  /// DELETE can't reach the sender's rows (recipient-only SELECT policy
  /// applies to the WHERE clause, so it silently deleted 0 rows). Returns
  /// how many recipient copies were removed (0 = already read or not owner;
  /// the message then survives on the server and is only removed locally).
  Future<int> deleteMessage(String chatId, String messageId) async {
    return client.rpc<int>(
      'delete_message_for_everyone',
      params: {
        'p_message_id': messageId,
        'p_chat_id': chatId,
      },
    );
  }
}
