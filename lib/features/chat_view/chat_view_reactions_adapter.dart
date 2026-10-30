// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/network/network_errors.dart';
import '../messages/message_reaction_model.dart';
import '../messages/message_reactions_controller.dart';
import '../reactions/reaction_usage_controller.dart';

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

      // Typed explicitly: inferred inside an async function, `when` became
      // FutureOr<…> and the 3.47 analyzer flags returning it from a try.
      return reactionsAsync.when<List<chatview.Reaction>>(
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
      final added = await controller.toggleReaction(emoji);
      // The quick-reaction row orders itself by how often something is used,
      // and this is the one funnel both ways through: the row itself and the
      // "+" picker. Counted only when a reaction was ADDED — taking one back
      // would otherwise push up the very emoji one was correcting.
      if (added) {
        unawaited(ref.read(reactionUsageProvider.notifier).note(emoji));
      }
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

/// Every reaction gesture goes through here when its caller does not wait
/// (double tap, pill, action sheet). Before CHAT-63 a failed toggle was
/// swallowed or left uncaught, so offline a reaction just did nothing, or
/// flashed and vanished, without a word.
extension ReactOrReport on ChatViewReactionsAdapter {
  Future<void> reactOrReport(
    BuildContext context, {
    required String messageId,
    required String emoji,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await onReactionTap(messageId: messageId, emoji: emoji);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(
        content: Text(isNetworkError(e)
            ? 'errors.reaction_offline'.tr()
            : userFacingError(e)),
      ));
    }
  }
}
