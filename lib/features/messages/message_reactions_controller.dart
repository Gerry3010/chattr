// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/database/database_service.dart';
import '../../core/events/event_bus_provider.dart';
import '../../core/events/event_types.dart';
import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import 'message_reaction_model.dart';
import 'message_reactions_local_dao.dart';
import 'message_reactions_repository.dart';

/// Provider for MessageReactionsLocalDao
final messageReactionsLocalDaoProvider = Provider<MessageReactionsLocalDao>((
    ref) {
  return MessageReactionsLocalDao(DatabaseService.instance);
});

/// Provider for MessageReactionsRepository
final messageReactionsRepositoryProvider = Provider<MessageReactionsRepository>((ref) {
  return MessageReactionsRepository(
    ref.read(supabaseClientProvider),
    ref.read(messageReactionsLocalDaoProvider),
  );
});

/// Provider for reactions of a specific message
final messageReactionsProvider = StateNotifierProvider.autoDispose
    .family<MessageReactionsController, AsyncValue<List<ReactionSummary>>, String>(
  (ref, messageId) {
    final repo = ref.read(messageReactionsRepositoryProvider);
    final userId = ref.watch(authControllerProvider);
    return MessageReactionsController(
      ref,
      repo,
      userId,
      messageId,
    );
  },
);

/// Controller for managing message reactions
class MessageReactionsController
    extends StateNotifier<AsyncValue<List<ReactionSummary>>> {
  final Ref ref;
  final MessageReactionsRepository repo;
  final String? userId;
  final String messageId;

  StreamSubscription<BusEvent>? _eventSub;

  MessageReactionsController(
    this.ref,
    this.repo,
    this.userId,
    this.messageId,
  ) : super(const AsyncValue.loading()) {
    _init();
  }

  Future<void> _init() async {
    try {
      await loadReactions();
      if (!mounted) return;

      // Realtime reaction changes now arrive on the single user event bus
      // (reactionChanged events broadcast by the DB trigger) instead of a
      // dedicated per-message Postgres-changes channel.
      final eventBus = ref.read(eventBusProvider);
      _eventSub = eventBus?.eventStream.listen((event) {
        if (event is ReactionChangedEvent &&
            event.messageId == messageId &&
            mounted) {
          loadReactions();
        }
      });
    } catch (e, stackTrace) {
      logger.error(
        'Failed to initialize reactions controller',
        tag: 'MessageReactionsController',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      state = AsyncValue.error(e, stackTrace);
    }
  }

  /// Load reaction summary for the message
  Future<void> loadReactions() async {
    try {
      if (!mounted) return;
      state = const AsyncValue.loading();
      final reactions = await repo.getReactionSummary(
        messageId,
        currentUserId: userId,
      );
      if (!mounted) return;
      state = AsyncValue.data(reactions);
      logger.debug('Loaded ${reactions.length} reactions for message $messageId');
    } catch (e, stackTrace) {
      logger.error(
        'Failed to load reactions',
        tag: 'MessageReactionsController',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      state = AsyncValue.error(e, stackTrace);
    }
  }

  /// Toggle a reaction (add if not exists, remove if exists)
  Future<bool> toggleReaction(String reaction) async {
    try {
      final added = await repo.toggleReaction(messageId, reaction);
      await loadReactions();
      logger.info(
        added ? 'Added reaction $reaction' : 'Removed reaction $reaction',
        tag: 'MessageReactionsController',
      );
      return added;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to toggle reaction',
        tag: 'MessageReactionsController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Get list of users who reacted with a specific emoji
  Future<List<ReactionUser>> getReactionUsers(String reaction) async {
    try {
      final users = await repo.getReactionUsers(messageId, reaction);
      logger.debug('Fetched ${users.length} users for reaction $reaction');
      return users;
    } catch (e, stackTrace) {
      logger.error(
        'Failed to get reaction users',
        tag: 'MessageReactionsController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}

/// Provider for chat-wide reactions (all messages in a chat)
final chatReactionsProvider = StateNotifierProvider.autoDispose
    .family<ChatReactionsController, Map<String, List<ReactionSummary>>, String>(
  (ref, chatId) {
    final repo = ref.read(messageReactionsRepositoryProvider);
    final userId = ref.watch(authControllerProvider);
    return ChatReactionsController(
      ref,
      repo,
      userId,
      chatId,
    );
  },
);

/// Controller for managing reactions across all messages in a chat
class ChatReactionsController
    extends StateNotifier<Map<String, List<ReactionSummary>>> {
  final Ref ref;
  final MessageReactionsRepository repo;
  final String? userId;
  final String chatId;

  StreamSubscription<BusEvent>? _eventSub;

  ChatReactionsController(
    this.ref,
    this.repo,
    this.userId,
    this.chatId,
  ) : super({}) {
    _init();
  }

  Future<void> _init() async {
    // Reaction changes for any message in this chat arrive on the single user
    // event bus (reactionChanged) instead of a dedicated chat_reactions channel.
    final eventBus = ref.read(eventBusProvider);
    _eventSub = eventBus?.eventStream.listen((event) {
      if (event is ReactionChangedEvent &&
          event.chatId == chatId &&
          mounted) {
        loadMessageReactions(event.messageId);
      }
    });
  }

  /// Load reactions for a specific message
  Future<void> loadMessageReactions(String messageId) async {
    try {
      final reactions = await repo.getReactionSummary(
        messageId,
        currentUserId: userId,
      );
      if (!mounted) return;
      state = {...state, messageId: reactions};
      logger.debug('Loaded reactions for message $messageId in chat');
    } catch (e, stackTrace) {
      logger.error(
        'Failed to load message reactions',
        tag: 'ChatReactionsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Load reactions for multiple messages in a single batched RPC and merge
  /// them into the chat-wide state. Used to prime the state when a chat is
  /// opened / older messages are paged in — realtime events only cover
  /// changes that happen while the chat is open.
  Future<void> loadReactionsForMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return;

    try {
      final newReactions = await repo.getReactionSummaries(
        messageIds,
        currentUserId: userId,
      );

      if (!mounted) return;
      state = {...state, ...newReactions};
      logger.debug(
        'Loaded reactions for ${newReactions.length}/${messageIds.length} messages with reactions',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to load reactions for messages',
        tag: 'ChatReactionsController',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Remove the current user's [reaction] from a message.
  ///
  /// Lives here rather than on [MessageReactionsController] because only
  /// `chatReactionsProvider` feeds the bubbles (`ChatViewController.
  /// _handleReactionsChange`) — a removal routed through the per-message
  /// family would update state nobody renders and leave the bubble waiting on
  /// the realtime round trip.
  Future<void> removeOwnReaction(String messageId, String reaction) =>
      _remove(messageId, reaction);

  /// Remove every reaction the current user left on a message.
  Future<void> removeAllOwnReactions(String messageId) =>
      _remove(messageId, null);

  Future<void> _remove(String messageId, String? reaction) async {
    final currentUserId = userId;
    if (currentUserId == null) return;

    // Paint it gone first — the server confirms afterwards. Without this the
    // bubble only updates once the reactionChanged broadcast comes back, which
    // makes a deliberate "remove" feel unanswered on a slow link.
    final previous = state[messageId];
    if (previous != null) {
      state = {
        ...state,
        messageId: withoutUserReaction(previous, currentUserId, reaction),
      };
    }

    try {
      if (reaction == null) {
        await repo.removeAllUserReactions(messageId, currentUserId);
      } else {
        await repo.removeReaction(messageId, currentUserId, reaction);
      }
      logger.info(
        'Removed ${reaction ?? 'all own reactions'} on message $messageId',
        tag: 'ChatReactionsController',
      );
    } catch (e, stackTrace) {
      logger.error(
        'Failed to remove reaction',
        tag: 'ChatReactionsController',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      // Reconcile in both directions: on success this is the authoritative
      // state, on failure it puts the optimistically removed reaction back.
      await loadMessageReactions(messageId);
    }
  }

  /// Get reactions for a specific message from state
  List<ReactionSummary> getReactions(String messageId) {
    return state[messageId] ?? [];
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
