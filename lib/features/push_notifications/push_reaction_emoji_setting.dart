// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';

/// May the reaction emoji travel to the push service, so a notification can say
/// "X reacted with 👍" instead of "X reacted to your message"?
///
/// Server-side for the same reason as [pushMediaKindProvider]: a database
/// trigger reads it while assembling the push (`profiles.push_reaction_emoji`,
/// migration 00072). A setting the push builder cannot see cannot be honoured.
///
/// **Default ON since 00073** (00072 shipped it off). The trade-off has not
/// changed — this hands over message CONTENT, the single character somebody
/// answered with, where the media category hands over one of four labels — but
/// Gerry's call, knowing that, was to make it the default. With the switch off
/// the field is never built server-side, not filtered out later.
final pushReactionEmojiProvider =
    StateNotifierProvider<PushReactionEmojiController, bool>((ref) {
      return PushReactionEmojiController(ref);
    });

class PushReactionEmojiController extends StateNotifier<bool> {
  final Ref _ref;

  // Matches the column default (00073), so the switch reads right before the
  // profile has loaded rather than flipping under the user.
  PushReactionEmojiController(this._ref) : super(true) {
    _load();
  }

  Future<void> _load() async {
    final userId = _ref.read(authControllerProvider);
    if (userId == null) return;
    try {
      final row = await _ref
          .read(supabaseClientProvider)
          .from('profiles')
          .select('push_reaction_emoji')
          .eq('id', userId)
          .maybeSingle();
      final value = row?['push_reaction_emoji'];
      if (mounted && value is bool) state = value;
    } catch (e) {
      // An older server without the column, or simply offline. Keeping the
      // default cannot leak anything: the column is what actually gates the
      // emoji, so a server that does not have it never sends one either — the
      // switch would just be showing an intention the server cannot act on.
      logger.info('push_reaction_emoji not readable, keeping default: $e');
    }
  }

  Future<void> setEnabled(bool enabled) async {
    final userId = _ref.read(authControllerProvider);
    if (userId == null) return;
    final previous = state;
    state = enabled; // optimistic, so the switch responds immediately
    try {
      await _ref
          .read(supabaseClientProvider)
          .from('profiles')
          .update({'push_reaction_emoji': enabled})
          .eq('id', userId);
    } catch (e, st) {
      // Roll back rather than leave the UI claiming a setting the server never
      // took — this one decides what leaves the device.
      if (mounted) state = previous;
      logger.error(
        'Failed to save push_reaction_emoji',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}
