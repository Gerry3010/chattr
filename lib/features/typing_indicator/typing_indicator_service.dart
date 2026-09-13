// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/logging/logger_service.dart';

/// Service for managing typing indicators using Supabase Presence
///
/// **The plaintext name does NOT travel along.** The presence payload used to
/// carry `username` — on a channel the server sees and whose name follows from
/// the chat id. So it stated in the clear who was typing, although every
/// message in the same chat is encrypted. What is transmitted now is only the
/// user id; the recipient resolves the display name from the profile data they
/// have anyway ([ChatViewController]).
///
/// The ids stay — they are in every message record regardless, and without them
/// the recipient would not know whom to show.
class TypingIndicatorService {
  final SupabaseClient _supabase;
  final Map<String, RealtimeChannel> _channels = {};
  final Map<String, Timer?> _typingTimers = {};

  // Typing indicator expires after 3 seconds
  static const Duration _typingTimeout = Duration(seconds: 3);

  /// What actually goes over the presence channel.
  ///
  /// A function of its own so a test can pin down that **no** display name
  /// stands here. Whoever adds one in future breaks the test — and that is the
  /// point: an extra field does not stand out when reading the code, but on a
  /// server-visible channel it reveals who is typing.
  @visibleForTesting
  static Map<String, dynamic> presencePayload(String userId, DateTime now) => {
        'user_id': userId,
        'typing': true,
        'timestamp': now.toIso8601String(),
      };

  /// The ids that emerge from the presence states as "currently typing".
  ///
  /// Extracted as well: the freshness check is the place where a stuck
  /// indicator comes from when it goes wrong.
  @visibleForTesting
  static List<String> typingIdsFrom(
    Iterable<Map<String, dynamic>> presences,
    DateTime now,
  ) {
    final ids = <String>[];
    for (final state in presences) {
      if (state['typing'] != true) continue;
      final userId = state['user_id'] as String?;
      final timestamp = state['timestamp'] as String?;
      if (userId == null || timestamp == null) continue;
      final typingTime = DateTime.tryParse(timestamp);
      if (typingTime == null) continue;
      if (now.difference(typingTime) >= _typingTimeout) continue;
      if (!ids.contains(userId)) ids.add(userId);
    }
    return ids;
  }

  TypingIndicatorService(this._supabase);

  /// Subscribe to typing indicators for a chat.
  ///
  /// Supplies the **user ids** of those currently typing — not their names. The
  /// caller adds the display name from their profile data.
  Stream<List<String>> subscribeToTypingIndicators(String chatId) async* {
    final channel = _getOrCreateChannel(chatId);
    final controller = StreamController<List<String>>();

    // Listen to presence state changes
    channel.onPresenceSync((payload) {
      final presenceState = channel.presenceState();
      // presenceState is a List<SinglePresenceState>, each with a list of
      // presences — flatten it and leave the evaluation to the helper.
      controller.add(typingIdsFrom(
        [
          for (final item in presenceState)
            for (final presence in item.presences) presence.payload,
        ],
        DateTime.now(),
      ));
    });

    // Subscribe to the channel
    try {
      channel.subscribe();
      logger.info('Subscribed to typing indicators for chat: $chatId');
    } catch (e) {
      logger.error('Failed to subscribe to typing indicators', error: e);
      controller.addError(e);
    }

    yield* controller.stream;
  }

  /// Start typing - updates presence to show user is typing.
  ///
  /// No `username` in the payload: the channel name follows from the chat id,
  /// and the server sees what stands here. A display name at this point would
  /// be plaintext beside nothing but encrypted messages.
  Future<void> startTyping({
    required String chatId,
    required String userId,
  }) async {
    try {
      final channel = _getOrCreateChannel(chatId);

      await channel.track(presencePayload(userId, DateTime.now()));

      // Cancel any existing timer
      _typingTimers[chatId]?.cancel();
      
      // Auto-stop typing after timeout
      _typingTimers[chatId] = Timer(_typingTimeout, () {
        stopTyping(chatId: chatId);
      });

      logger.info('Typing started in chat $chatId');
    } catch (e) {
      logger.error('Failed to start typing indicator', error: e);
    }
  }

  /// Stop typing - removes typing status from presence
  Future<void> stopTyping({required String chatId}) async {
    try {
      _typingTimers[chatId]?.cancel();
      _typingTimers[chatId] = null;

      final channel = _channels[chatId];
      if (channel != null) {
        await channel.track({
          'typing': false,
        });
        logger.info('Stopped typing in chat $chatId');
      }
    } catch (e) {
      logger.error('Failed to stop typing indicator', error: e);
    }
  }

  /// Unsubscribe from a chat's typing indicators
  Future<void> unsubscribe(String chatId) async {
    try {
      _typingTimers[chatId]?.cancel();
      _typingTimers.remove(chatId);

      final channel = _channels.remove(chatId);
      if (channel != null) {
        await _supabase.removeChannel(channel);
        logger.info('Unsubscribed from typing indicators for chat $chatId');
      }
    } catch (e) {
      logger.error('Failed to unsubscribe from typing indicators', error: e);
    }
  }

  /// Get or create a channel for a chat
  RealtimeChannel _getOrCreateChannel(String chatId) {
    if (_channels.containsKey(chatId)) {
      return _channels[chatId]!;
    }

    final channel = _supabase.channel('chat:$chatId:typing');
    _channels[chatId] = channel;
    return channel;
  }

  /// Cleanup all channels
  Future<void> dispose() async {
    for (final timer in _typingTimers.values) {
      timer?.cancel();
    }
    _typingTimers.clear();

    for (final channel in _channels.values) {
      try {
        await _supabase.removeChannel(channel);
      } catch (e) {
        logger.error('Failed to remove channel during dispose', error: e);
      }
    }
    _channels.clear();
  }
}
