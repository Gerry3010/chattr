// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/utils/app_time.dart';
import '../messages/message_reaction_model.dart';
import '../messages/message_reactions_controller.dart';
import '../profiles/widgets/user_avatar.dart';

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
      logger.debug('Toggled reaction $emoji on message $messageId');
    } catch (e) {
      logger.error('Failed to handle reaction tap: $e');
      rethrow;
    }
  }

  /// Show users who reacted with a specific emoji
  Future<void> showReactionUsers(
    BuildContext context,
    String messageId,
    String emoji,
  ) async {
    try {
      final controller = ref.read(messageReactionsProvider(messageId).notifier);
      final users = await controller.getReactionUsers(emoji);

      if (!context.mounted) return;

      showModalBottomSheet<void>(
        context: context,
        builder: (context) => ReactionUsersSheet(
          emoji: emoji,
          users: users,
        ),
      );
    } catch (e) {
      logger.error('Failed to show reaction users: $e');
    }
  }

  // /// Get reaction callback for chatview's ReactionConfiguration
  // chatview.MessageReactionCallback get onReactionTapCallback {
  //   return (messageId, emoji) async {
  //     await onReactionTap(messageId: messageId, emoji: emoji);
  //   };
  // }

  /// Get reaction popup callback for chatview
  chatview.ReactionCallback get onReactionCallback {
    return (message, String emoji) async {
      await onReactionTap(messageId: message.id, emoji: emoji);
    };
  }
}

/// Bottom sheet to display users who reacted with a specific emoji.
///
/// Fetches and displays the profile names of all users who added the reaction.
class ReactionUsersSheet extends StatelessWidget {
  final String emoji;
  final List<ReactionUser> users;

  const ReactionUsersSheet({
    super.key,
    required this.emoji,
    required this.users,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Text(
                emoji,
                style: const TextStyle(fontSize: 32),
              ),
              const SizedBox(width: 8),
              Text(
                '${users.length} ${users.length == 1 ? 'Person' : 'Personen'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),

          // User list
          Flexible(
            child: users.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Text('Keine Reaktionen'),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: users.length,
                    itemBuilder: (context, index) {
                      final user = users[index];
                      return ListTile(
                        leading: UserAvatar(userId: user.userId, radius: 20),
                        title: Text(user.username),
                        subtitle: Text(
                          _formatTimestamp(context, user.createdAt),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(BuildContext context, DateTime timestamp) {
    final minutes = AppTime.minutesAgo(timestamp);
    if (minutes < 1) {
      return 'dates.just_now'.tr();
    } else if (minutes < 60) {
      return 'dates.minutes_ago'.tr(args: [minutes.toString()]);
    }
    final hours = AppTime.hoursAgo(timestamp);
    if (hours < 24) {
      return 'dates.hours_ago'.tr(args: [hours.toString()]);
    }
    final days = AppTime.daysAgo(timestamp);
    if (days < 7) {
      return 'dates.days_ago'.tr(args: [days.toString()]);
    }
    return AppTime.ymd(timestamp, context.locale.toString());
  }
}

/// Widget to display reaction summary for a message
class MessageReactionDisplay extends ConsumerWidget {
  final String messageId;
  final VoidCallback? onTap;

  const MessageReactionDisplay({
    super.key,
    required this.messageId,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reactionsAsync = ref.watch(messageReactionsProvider(messageId));

    return reactionsAsync.when(
      data: (reactions) {
        if (reactions.isEmpty) {
          return const SizedBox.shrink();
        }

        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: reactions.map((summary) {
            return _ReactionChip(
              messageId: messageId,
              summary: summary,
              onTap: () async {
                final controller = ref.read(
                  messageReactionsProvider(messageId).notifier,
                );
                await controller.toggleReaction(summary.reaction);
              },
            );
          }).toList(),
        );
      },
      loading: () => const SizedBox(
        height: 24,
        width: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (err, stack) => const SizedBox.shrink(),
    );
  }
}

/// Individual reaction chip
class _ReactionChip extends StatelessWidget {
  final String messageId;
  final ReactionSummary summary;
  final VoidCallback? onTap;

  const _ReactionChip({
    required this.messageId,
    required this.summary,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUserReacted = summary.userReacted;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isUserReacted
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isUserReacted
                ? theme.colorScheme.primary
                : theme.colorScheme.outline.withValues(alpha: 0.3),
            width: isUserReacted ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              summary.reaction,
              style: const TextStyle(fontSize: 14),
            ),
            if (summary.count > 1) ...[
              const SizedBox(width: 4),
              Text(
                '${summary.count}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isUserReacted ? FontWeight.bold : FontWeight.normal,
                  color: isUserReacted
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Helper to build EmojiConfiguration for chatview
chatview.EmojiConfiguration buildEmojiConfiguration(
  WidgetRef ref,
  String chatId,
) {
  // Simplified emoji configuration - using defaults
  return chatview.EmojiConfiguration();
}

/// Helper function to build the reaction popup configuration for chatview.
chatview.ReactionPopupConfiguration buildReactionPopupConfiguration(
  WidgetRef ref,
  String chatId,
) {
  final adapter = ChatViewReactionsAdapter(ref, chatId);

  return chatview.ReactionPopupConfiguration(
    // This callback is triggered when user reacts to a message
    userReactionCallback: adapter.onReactionCallback,
    // Show glass morphism effect for modern look
    showGlassMorphismEffect: true,
    // Animation duration for popup
    animationDuration: const Duration(milliseconds: 200),
    // Emoji configuration for the reaction picker
    emojiConfig: buildEmojiConfiguration(ref, chatId),
    // Glass morphism configuration
    glassMorphismConfig: chatview.GlassMorphismConfiguration(
      borderRadius: 20,
    ),
  );
}
