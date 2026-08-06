// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/logging/logger_service.dart';

/// Service for managing typing indicators using Supabase Presence
class TypingIndicatorService {
  final SupabaseClient _supabase;
  final Map<String, RealtimeChannel> _channels = {};
  final Map<String, Timer?> _typingTimers = {};
  
  // Typing indicator expires after 3 seconds
  static const Duration _typingTimeout = Duration(seconds: 3);

  TypingIndicatorService(this._supabase);

  /// Subscribe to typing indicators for a chat
  /// Returns a stream of usernames who are currently typing
  Stream<List<String>> subscribeToTypingIndicators(String chatId) async* {
    final channel = _getOrCreateChannel(chatId);
    final controller = StreamController<List<String>>();

    // Listen to presence state changes
    channel.onPresenceSync((payload) {
      final presenceState = channel.presenceState();
      final typingUsers = <String>[];

      // presenceState is a List<SinglePresenceState>
      for (final presenceItem in presenceState) {
        // Each presenceItem has a list of presences
        for (final presence in presenceItem.presences) {
          final state = presence.payload;
          if (state['typing'] == true) {
            final username = state['username'] as String?;
            final timestamp = state['timestamp'] as String?;
            
            // Check if typing indicator is still fresh (within 3 seconds)
            if (username != null && timestamp != null) {
              final typingTime = DateTime.tryParse(timestamp);
              if (typingTime != null && 
                  DateTime.now().difference(typingTime) < _typingTimeout) {
                typingUsers.add(username);
              }
            }
          }
        }
      }

      controller.add(typingUsers);
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

  /// Start typing - updates presence to show user is typing
  Future<void> startTyping({
    required String chatId,
    required String userId,
    required String username,
  }) async {
    try {
      final channel = _getOrCreateChannel(chatId);
      
      await channel.track({
        'user_id': userId,
        'username': username,
        'typing': true,
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Cancel any existing timer
      _typingTimers[chatId]?.cancel();
      
      // Auto-stop typing after timeout
      _typingTimers[chatId] = Timer(_typingTimeout, () {
        stopTyping(chatId: chatId);
      });

      logger.info('User $username started typing in chat $chatId');
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
