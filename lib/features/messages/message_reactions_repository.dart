// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';
import 'message_reaction_model.dart';
import 'message_reactions_local_dao.dart';

/// Repository for managing message reactions
class MessageReactionsRepository {
  final SupabaseClient client;
  final MessageReactionsLocalDao localDao;

  MessageReactionsRepository(this.client, this.localDao);

  /// Toggle a reaction on a message (add if not exists, remove if exists)
  /// Returns true if added, false if removed
  Future<bool> toggleReaction(String messageId, String reaction) async {
    try {
      final result = await client.rpc<bool>(
        'toggle_message_reaction',
        params: {
          'p_message_id': messageId,
          'p_reaction': reaction,
        },
      );

      logger.debug('Toggled reaction $reaction on message $messageId: $result');
      return result;
    } catch (e) {
      logger.error('Failed to toggle reaction: $e');
      rethrow;
    }
  }

  /// Get reaction summary for a message (grouped by emoji with counts)
  /// Tries remote first, falls back to local cache on network error
  Future<List<ReactionSummary>> getReactionSummary(String messageId, {
    String? currentUserId,
  }) async {
    try {
      // Try to fetch from Supabase
      final result = await client.rpc<List<dynamic>>(
        'get_message_reaction_summary',
        params: {'p_message_id': messageId},
      );

      final reactions = result
          .map((dynamic json) =>
          ReactionSummary.fromJson(json as Map<String, dynamic>))
          .toList();

      logger.debug(
          'Fetched reaction summary for message $messageId from remote');

      // Sync to local database in background
      _syncReactionsToLocal(messageId).catchError((Object e) {
        logger.error('Failed to sync reactions to local: $e');
      });

      return reactions;
    } catch (e) {
      logger.error('Failed to fetch reaction summary from remote: $e');

      // Fall back to local database
      if (currentUserId != null) {
        try {
          final localReactions = await localDao.getReactionSummary(
            messageId,
            currentUserId,
          );
          logger.debug(
              'Fetched reaction summary for message $messageId from local cache');
          return localReactions;
        } catch (localError) {
          logger.error('Failed to fetch from local cache: $localError');
        }
      }
      
      rethrow;
    }
  }

  /// Sync reactions for a message to local database
  Future<void> _syncReactionsToLocal(String messageId) async {
    try {
      final reactions = await getMessageReactions(messageId);
      // Replace the local cache for this message with the authoritative remote
      // set so reactions removed remotely are pruned locally. Previously this
      // only inserted, so removed reactions resurfaced on the offline fallback.
      await localDao.deleteReactionsForMessage(messageId);
      if (reactions.isNotEmpty) {
        await localDao.saveReactions(reactions);
      }
    } catch (e) {
      logger.error('Failed to sync reactions to local: $e');
    }
  }

  /// Get list of users who reacted with a specific emoji
  Future<List<ReactionUser>> getReactionUsers(
    String messageId,
    String reaction,
  ) async {
    try {
      final result = await client.rpc<dynamic>(
        'get_reaction_users',
        params: {
          'p_message_id': messageId,
          'p_reaction': reaction,
        },
      );

      logger.debug(
        'Fetched users for reaction $reaction on message $messageId',
      );
      return (result as List)
          .map((json) => ReactionUser.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logger.error('Failed to fetch reaction users: $e');
      rethrow;
    }
  }

  /// Add a reaction to a message
  Future<MessageReactionModel> addReaction(
    String messageId,
    String userId,
    String reaction,
  ) async {
    try {
      final result = await client.from('message_reactions').insert({
        'message_id': messageId,
        'user_id': userId,
        'reaction': reaction,
      }).select().single();

      logger.debug('Added reaction $reaction to message $messageId');
      return MessageReactionModel.fromJson(result);
    } catch (e) {
      logger.error('Failed to add reaction: $e');
      rethrow;
    }
  }

  /// Remove one of [userId]'s reactions from a message.
  ///
  /// Deliberately NOT `toggleReaction`: that RPC decides by current state
  /// (`IF EXISTS → DELETE ELSE INSERT`), so a second device toggling at the
  /// same moment turns an intended removal into a fresh insert. An explicit
  /// DELETE is idempotent — a double tap, a replayed event or a row another
  /// device already deleted all end in the same place, without an error.
  /// RLS ("Users can delete own reactions", 00007) confines it to `auth.uid()`;
  /// a wrong [userId] silently deletes nothing rather than someone else's row.
  Future<void> removeReaction(
    String messageId,
    String userId,
    String reaction,
  ) async {
    try {
      await client
          .from('message_reactions')
          .delete()
          .eq('message_id', messageId)
          .eq('user_id', userId)
          .eq('reaction', reaction);

      // Prune the offline cache here, not only via _syncReactionsToLocal: that
      // runs after a SUCCESSFUL remote read, so losing the network between the
      // DELETE and the refetch would let the fallback serve the reaction we
      // just removed back to the user.
      await localDao.deleteUserReaction(messageId, userId, reaction);

      logger.debug('Removed reaction $reaction from message $messageId');
    } catch (e) {
      logger.error('Failed to remove reaction: $e');
      rethrow;
    }
  }

  /// Remove every reaction [userId] left on a message — one round trip.
  ///
  /// The DB trigger fires per deleted row, so this produces one
  /// `reactionChanged` broadcast per emoji. Acceptable: a user rarely holds
  /// more than a handful on the same message.
  Future<void> removeAllUserReactions(String messageId, String userId) async {
    try {
      await client
          .from('message_reactions')
          .delete()
          .eq('message_id', messageId)
          .eq('user_id', userId);

      await localDao.deleteUserReactions(messageId, userId);

      logger.debug('Removed all reactions of $userId from message $messageId');
    } catch (e) {
      logger.error('Failed to remove reactions: $e');
      rethrow;
    }
  }

  /// Get all reactions for a message
  Future<List<MessageReactionModel>> getMessageReactions(
    String messageId,
  ) async {
    try {
      final result = await client
          .from('message_reactions')
          .select()
          .eq('message_id', messageId)
          .order('created_at');

      logger.debug('Fetched all reactions for message $messageId');
      return (result as List)
          .map((json) =>
          MessageReactionModel.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logger.error('Failed to fetch message reactions: $e');
      rethrow;
    }
  }

  /// Get aggregated reaction summaries for multiple messages in ONE call.
  /// Uses the SECURITY DEFINER RPC: a direct select can't see reactions on
  /// the caller's own sent messages (messages RLS is recipient-only, and
  /// senders have no recipient row of their own).
  Future<Map<String, List<ReactionSummary>>> getReactionSummaries(
    List<String> messageIds, {
    String? currentUserId,
  }) async {
    try {
      final result = await client.rpc<List<dynamic>>(
        'get_message_reaction_summaries',
        params: {'p_message_ids': messageIds},
      );

      final Map<String, List<ReactionSummary>> grouped = {};
      for (final row in result) {
        final map = row as Map<String, dynamic>;
        grouped
            .putIfAbsent(map['message_id'] as String, () => [])
            .add(ReactionSummary.fromJson(map));
      }
      logger.debug(
          'Fetched reaction summaries for ${messageIds.length} messages');
      return grouped;
    } catch (e) {
      logger.error('Failed to fetch reaction summaries: $e');
      rethrow;
    }
  }

  /// Get reactions for multiple messages (batch)
  Future<Map<String, List<MessageReactionModel>>> getReactionsForMessages(
    List<String> messageIds,
  ) async {
    try {
      final result = await client
          .from('message_reactions')
          .select()
          .inFilter('message_id', messageIds)
          .order('created_at');

      logger.debug('Fetched reactions for ${messageIds.length} messages');

      // Group reactions by message_id
      final Map<String, List<MessageReactionModel>> grouped = {};
      for (final json in result as List) {
        final reaction = MessageReactionModel.fromJson(
            json as Map<String, dynamic>);
        grouped.putIfAbsent(reaction.messageId, () => []).add(reaction);
      }

      return grouped;
    } catch (e) {
      logger.error('Failed to fetch reactions for messages: $e');
      rethrow;
    }
  }

}
