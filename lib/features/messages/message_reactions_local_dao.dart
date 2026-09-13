// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:sqflite/sqflite.dart';

import '../../core/database/database_schema.dart';
import '../../core/database/database_service.dart';
import '../../core/logging/logger_service.dart';
import 'message_reaction_model.dart';

/// Local Data Access Object for message reactions
class MessageReactionsLocalDao {
  final DatabaseService _dbService;

  MessageReactionsLocalDao(this._dbService);

  /// Save a reaction to local database
  Future<void> saveReaction(MessageReactionModel reaction) async {
    try {
      final db = await _dbService.database;
      await db.insert(
        DatabaseSchema.messageReactionsTable,
        {
          'id': reaction.id,
          'message_id': reaction.messageId,
          'user_id': reaction.userId,
          'reaction': reaction.reaction,
          'created_at': reaction.createdAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      logger.debug('Saved reaction ${reaction.id} locally');
    } catch (e) {
      logger.error('Failed to save reaction locally: $e');
      rethrow;
    }
  }

  /// Save multiple reactions (batch)
  Future<void> saveReactions(List<MessageReactionModel> reactions) async {
    if (reactions.isEmpty) return;

    try {
      final db = await _dbService.database;
      final batch = db.batch();

      for (final reaction in reactions) {
        batch.insert(
          DatabaseSchema.messageReactionsTable,
          {
            'id': reaction.id,
            'message_id': reaction.messageId,
            'user_id': reaction.userId,
            'reaction': reaction.reaction,
            'created_at': reaction.createdAt.toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await batch.commit(noResult: true);
      logger.debug('Saved ${reactions.length} reactions locally');
    } catch (e) {
      logger.error('Failed to save reactions batch locally: $e');
      rethrow;
    }
  }

  /// Get reactions for a specific message
  Future<List<MessageReactionModel>> getReactionsForMessage(
    String messageId,
  ) async {
    try {
      final db = await _dbService.database;
      final results = await db.query(
        DatabaseSchema.messageReactionsTable,
        where: 'message_id = ?',
        whereArgs: [messageId],
        orderBy: 'created_at ASC',
      );

      return results
          .map(
            (json) => MessageReactionModel(
              id: json['id'] as String,
              messageId: json['message_id'] as String,
              userId: json['user_id'] as String,
              reaction: json['reaction'] as String,
              createdAt: DateTime.parse(json['created_at'] as String),
            ),
          )
          .toList();
    } catch (e) {
      logger.error('Failed to get reactions for message locally: $e');
      return [];
    }
  }

  /// Get reactions for multiple messages (batch)
  Future<Map<String, List<MessageReactionModel>>> getReactionsForMessages(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return {};

    try {
      final db = await _dbService.database;
      final results = await db.query(
        DatabaseSchema.messageReactionsTable,
        where:
            'message_id IN (${List.filled(messageIds.length, '?').join(', ')})',
        whereArgs: messageIds,
        orderBy: 'created_at ASC',
      );

      final Map<String, List<MessageReactionModel>> grouped = {};
      for (final json in results) {
        final reaction = MessageReactionModel(
          id: json['id'] as String,
          messageId: json['message_id'] as String,
          userId: json['user_id'] as String,
          reaction: json['reaction'] as String,
          createdAt: DateTime.parse(json['created_at'] as String),
        );
        grouped.putIfAbsent(reaction.messageId, () => []).add(reaction);
      }

      return grouped;
    } catch (e) {
      logger.error('Failed to get reactions for messages locally: $e');
      return {};
    }
  }

  /// Get reaction summary for a message (grouped by emoji)
  Future<List<ReactionSummary>> getReactionSummary(
    String messageId,
    String currentUserId,
  ) async {
    try {
      final db = await _dbService.database;
      final results = await db.rawQuery(
        '''
        SELECT
          reaction,
          COUNT(*) as count,
          MAX(CASE WHEN user_id = ? THEN 1 ELSE 0 END) as user_reacted,
          GROUP_CONCAT(user_id) as user_ids
        FROM ${DatabaseSchema.messageReactionsTable}
        WHERE message_id = ?
        GROUP BY reaction
        ORDER BY count DESC, reaction ASC
      ''',
        [currentUserId, messageId],
      );

      return results
          .map(
            (row) => ReactionSummary(
              reaction: row['reaction'] as String,
              count: row['count'] as int,
              userReacted: (row['user_reacted'] as int) == 1,
              userIds: (row['user_ids'] as String?)?.split(',') ?? const [],
            ),
          )
          .toList();
    } catch (e) {
      logger.error('Failed to get reaction summary locally: $e');
      return [];
    }
  }

  /// Delete a reaction
  Future<void> deleteReaction(String reactionId) async {
    try {
      final db = await _dbService.database;
      await db.delete(
        DatabaseSchema.messageReactionsTable,
        where: 'id = ?',
        whereArgs: [reactionId],
      );
      logger.debug('Deleted reaction $reactionId locally');
    } catch (e) {
      logger.error('Failed to delete reaction locally: $e');
      rethrow;
    }
  }

  /// Delete a specific user's reaction on a message
  Future<void> deleteUserReaction(
    String messageId,
    String userId,
    String reaction,
  ) async {
    try {
      final db = await _dbService.database;
      await db.delete(
        DatabaseSchema.messageReactionsTable,
        where: 'message_id = ? AND user_id = ? AND reaction = ?',
        whereArgs: [messageId, userId, reaction],
      );
      logger.debug(
        'Deleted reaction $reaction from message $messageId locally',
      );
    } catch (e) {
      logger.error('Failed to delete user reaction locally: $e');
      rethrow;
    }
  }

  /// Delete every reaction a user left on a message
  Future<void> deleteUserReactions(String messageId, String userId) async {
    try {
      final db = await _dbService.database;
      await db.delete(
        DatabaseSchema.messageReactionsTable,
        where: 'message_id = ? AND user_id = ?',
        whereArgs: [messageId, userId],
      );
      logger.debug(
        'Deleted all reactions of $userId on message $messageId locally',
      );
    } catch (e) {
      logger.error('Failed to delete user reactions locally: $e');
      rethrow;
    }
  }

  /// Delete all reactions for a message
  Future<void> deleteReactionsForMessage(String messageId) async {
    try {
      final db = await _dbService.database;
      await db.delete(
        DatabaseSchema.messageReactionsTable,
        where: 'message_id = ?',
        whereArgs: [messageId],
      );
      logger.debug('Deleted all reactions for message $messageId locally');
    } catch (e) {
      logger.error('Failed to delete reactions for message locally: $e');
      rethrow;
    }
  }

  /// Check if a user has reacted to a message with a specific emoji
  Future<bool> hasUserReacted(
    String messageId,
    String userId,
    String reaction,
  ) async {
    try {
      final db = await _dbService.database;
      final results = await db.query(
        DatabaseSchema.messageReactionsTable,
        where: 'message_id = ? AND user_id = ? AND reaction = ?',
        whereArgs: [messageId, userId, reaction],
        limit: 1,
      );
      return results.isNotEmpty;
    } catch (e) {
      logger.error('Failed to check user reaction locally: $e');
      return false;
    }
  }

  /// Get reaction ID for a specific user reaction
  Future<String?> getReactionId(
    String messageId,
    String userId,
    String reaction,
  ) async {
    try {
      final db = await _dbService.database;
      final results = await db.query(
        DatabaseSchema.messageReactionsTable,
        columns: ['id'],
        where: 'message_id = ? AND user_id = ? AND reaction = ?',
        whereArgs: [messageId, userId, reaction],
        limit: 1,
      );
      return results.isNotEmpty ? results.first['id'] as String : null;
    } catch (e) {
      logger.error('Failed to get reaction ID locally: $e');
      return null;
    }
  }

  /// Clear all local reactions (for testing or data wipe)
  Future<void> clearAll() async {
    try {
      final db = await _dbService.database;
      await db.delete(DatabaseSchema.messageReactionsTable);
      logger.debug('Cleared all local reactions');
    } catch (e) {
      logger.error('Failed to clear local reactions: $e');
      rethrow;
    }
  }
}
