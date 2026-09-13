// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../messages/message_reaction_model.dart';
import '../messages/message_reactions_controller.dart';

/// Adapter to integrate our message reactions backend with chatview's UI.
///
/// It provides methods to convert our internal reaction models to the format
/// expected by the `chatview` package and handles user interactions (tapping/viewing).
class ChatViewReactionsAdapter {
  final WidgetRef ref;
  final String chatId;

  ChatViewReactionsAdapter(this.ref, this.chatId);

  /// Convert our ReactionSummary to chatview's Reaction format.
  /// chatview expects PARALLEL lists: one emoji entry per reacting user,
  /// with that user's id at the same index.
  chatview.Reaction toChattrReaction(ReactionSummary summary) {
    return chatview.Reaction(
      reactions: summary.userIds.isEmpty
          ? [summary.reaction]
          : List.filled(summary.userIds.length, summary.reaction),
      reactedUserIds: summary.userIds,
    );
  }

  /// Get reactions for a message in chatview format
  Future<List<chatview.Reaction>> getReactionsForMessage(
    String messageId,
  ) async {
    try {
      ref.read(messageReactionsProvider(messageId).notifier);
      final reactionsAsync = ref.read(messageReactionsProvider(messageId));

      return reactionsAsync.when(
        data: (summaries) => summaries.map(toChattrReaction).toList(),
        loading: () => [],
        error: (err, stack) => [],
      );
    } catch (e) {
      logger.error('Failed to get reactions for chatview: $e');
      return [];
    }
  }

  /// Handle reaction tap from chatview
  Future<void> onReactionTap({
    required String messageId,
    required String emoji,
  }) async {
    try {
      final controller = ref.read(messageReactionsProvider(messageId).notifier);
      await controller.toggleReaction(emoji);
      // The bubble reads chatReactionsProvider, not this per-message family, so
      // without this line a newly added reaction only appears once the realtime
      // broadcast returns — and not at all if the connection is asleep.
      await ref
          .read(chatReactionsProvider(chatId).notifier)
          .loadMessageReactions(messageId);
      logger.debug('Toggled reaction $emoji on message $messageId');
    } catch (e) {
      logger.error('Failed to handle reaction tap: $e');
      rethrow;
    }
  }
}
