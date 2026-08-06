// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';

/// May the coarse media category travel to the push service, so a notification
/// can say "X sent a photo" instead of "New message from X"?
///
/// **Server-side, unlike the other privacy toggles.** Read receipts and the
/// like live in secure storage because only this device acts on them. This one
/// is read by a database trigger while building the push (`profiles.
/// push_media_kind`, migration 00067) — the decision has to be where the push
/// is assembled, or it cannot be honoured at all.
///
/// Default ON, and the switch says plainly what it costs: our own server knows
/// the category either way (every media blob carries it since 00066, which is
/// what the operator dashboard counts). What the switch decides is whether
/// **Google/Apple** learn it too. Off means the push falls back to the wording
/// it had before — nothing else changes, and the in-app view still shows the
/// type, because no third party is involved there.
final pushMediaKindProvider =
    StateNotifierProvider<PushMediaKindController, bool>((ref) {
      return PushMediaKindController(ref);
    });

class PushMediaKindController extends StateNotifier<bool> {
  final Ref _ref;

  // Optimistic default: matches the column default, so the switch reads right
  // before the profile has loaded rather than flipping under the user.
  PushMediaKindController(this._ref) : super(true) {
    _load();
  }

  Future<void> _load() async {
    final userId = _ref.read(authControllerProvider);
    if (userId == null) return;
    try {
      final row = await _ref
          .read(supabaseClientProvider)
          .from('profiles')
          .select('push_media_kind')
          .eq('id', userId)
          .maybeSingle();
      final value = row?['push_media_kind'];
      if (mounted && value is bool) state = value;
    } catch (e) {
      // An older server without the column, or simply offline. Keeping the
      // default is right either way: the column is what actually gates the
      // push, so a failed read here cannot leak anything the server wouldn't
      // have sent anyway.
      logger.info('push_media_kind not readable, keeping default: $e');
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
          .update({'push_media_kind': enabled})
          .eq('id', userId);
    } catch (e, st) {
      // Roll the switch back rather than leave the UI claiming a setting the
      // server never took — this one is about what leaves the device.
      if (mounted) state = previous;
      logger.error('Failed to save push_media_kind', error: e, stackTrace: st);
      rethrow;
    }
  }
}
