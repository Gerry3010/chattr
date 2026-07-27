// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';

/// Server-synced mute state: chatId -> mute expiry (null = muted forever).
/// Muting suppresses push notifications (filtered server-side in
/// notify_members_new_message) and in-app notification banners; realtime
/// delivery and unread counts are unaffected (WhatsApp-style). A mute whose
/// expiry has passed counts as not muted on both sides.
final mutedChatsProvider =
    StateNotifierProvider<MuteController, Map<String, DateTime?>>((ref) {
  return MuteController(
    ref.read(supabaseClientProvider),
    ref.watch(authControllerProvider),
  );
});

class MuteController extends StateNotifier<Map<String, DateTime?>> {
  final SupabaseClient _client;
  final String? _userId;

  MuteController(this._client, this._userId) : super(const {}) {
    if (_userId != null) _load();
  }

  Future<void> _load() async {
    try {
      final rows = await _client
          .from('chat_mute_prefs')
          .select('chat_id, muted_until')
          .eq('user_id', _userId!);
      final now = DateTime.timestamp();
      final active = <String, DateTime?>{};
      final expired = <String>[];
      for (final r in rows) {
        final chatId = r['chat_id'] as String;
        final untilRaw = r['muted_until'] as String?;
        final until = untilRaw != null ? DateTime.parse(untilRaw) : null;
        if (until != null && until.isBefore(now)) {
          expired.add(chatId);
        } else {
          active[chatId] = until;
        }
      }
      if (!mounted) return;
      state = active;
      // Opportunistic cleanup — the server ignores expired mutes anyway.
      if (expired.isNotEmpty) {
        await _client
            .from('chat_mute_prefs')
            .delete()
            .eq('user_id', _userId)
            .inFilter('chat_id', expired);
      }
    } catch (e) {
      logger.error('Failed to load mute prefs', tag: 'Mute', error: e);
    }
  }

  /// Whether [chatId] is currently muted (expired mutes count as unmuted).
  bool isMuted(String chatId) {
    if (!state.containsKey(chatId)) return false;
    final until = state[chatId];
    return until == null || until.isAfter(DateTime.timestamp());
  }

  /// The active mute's expiry for [chatId]; null when muted forever or not
  /// muted (check [isMuted] first).
  DateTime? mutedUntil(String chatId) => state[chatId];

  /// Mute [chatId] until [until] (null = forever).
  Future<void> mute(String chatId, {DateTime? until}) async {
    if (_userId == null) return;
    // Optimistic update so the UI flips immediately.
    final previous = state;
    state = {...state, chatId: until};
    try {
      await _client.from('chat_mute_prefs').upsert(
        {
          'user_id': _userId,
          'chat_id': chatId,
          'muted_until': until?.toUtc().toIso8601String(),
        },
        onConflict: 'user_id,chat_id',
      );
    } catch (e) {
      logger.error('Failed to update mute pref', tag: 'Mute', error: e);
      if (mounted) state = previous; // revert on failure
    }
  }

  Future<void> unmute(String chatId) async {
    if (_userId == null) return;
    final previous = state;
    state = {...state}..remove(chatId);
    try {
      await _client
          .from('chat_mute_prefs')
          .delete()
          .eq('user_id', _userId)
          .eq('chat_id', chatId);
    } catch (e) {
      logger.error('Failed to update mute pref', tag: 'Mute', error: e);
      if (mounted) state = previous; // revert on failure
    }
  }
}

/// Convenience: whether [chatId] is currently muted, reactive to state
/// changes. (Expiry is evaluated at read time — an expired mute reads as
/// unmuted even before the next reload cleans it up.)
final chatIsMutedProvider = Provider.family<bool, String>((ref, chatId) {
  ref.watch(mutedChatsProvider);
  return ref.read(mutedChatsProvider.notifier).isMuted(chatId);
});
