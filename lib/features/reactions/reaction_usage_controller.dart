// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../core/security/security_providers.dart';
import 'reaction_usage_rules.dart';

/// The quick-reaction row and the weights behind it, kept across restarts.
///
/// The row used to be six constants. Gerry, 2026-09-24: "the emoji row is based
/// on the most frequently chosen emoji over the last X days/weeks or so. by
/// default the current selection is simply defined as last used, so everyone
/// starts with this order."
///
/// Counted are **reactions only** — a tap in the row and a pick from the "+"
/// picker, both of which come through the one funnel
/// `ChatViewReactionsAdapter.onReactionTap`. Emoji typed into messages stay out
/// of it: the row answers "what do you react with", and a 😂 in a sentence is a
/// different act.
final reactionUsageProvider =
    StateNotifierProvider<ReactionUsageController, ReactionUsage>((ref) {
  return ReactionUsageController(
    ref.read(secureStorageProvider),
    resumes: ref.read(appLifecycleServiceProvider).onResume,
  );
});

/// The six emoji to render, in order. Everything else about the sheet is
/// unchanged, including the "+" button beside them.
final quickReactionRowProvider = Provider<List<String>>((ref) {
  return ref.watch(reactionUsageProvider).order;
});

class ReactionUsageController extends StateNotifier<ReactionUsage> {
  static const _key = 'reaction_usage_v1';

  final FlutterSecureStorage _storage;

  /// Overridable so a test can drive the ageing without waiting a month.
  final DateTime Function() _now;

  ReactionUsageController(
    this._storage, {
    DateTime Function()? now,
    Stream<void>? resumes,
  })  : _now = now ?? DateTime.now,
        super(ReactionUsage.seed(quickReactionEmojis, (now ?? DateTime.now)())) {
    _resumeSub = resumes?.listen((_) {
      if (!_loaded) _load();
    });
    _load();
  }

  StreamSubscription<void>? _resumeSub;

  /// The stored row has been read (or there was none). Until then nothing is
  /// written: the row in memory is only the seed, and saving it would
  /// overwrite everything counted so far.
  ///
  /// That happened on iOS: a VoIP push starts the app in the background with
  /// the phone locked, the keychain refuses the read, the seed stayed in
  /// memory, and the next reaction saved "seed + 1" over the real row. The row
  /// never seemed to learn anything (Gerry, 2026-10-22).
  bool _loaded = false;

  /// Reactions noted before the stored row was read, replayed on top of it.
  final List<(String, DateTime)> _pending = [];

  Future<void> _load() async {
    final String? raw;
    try {
      raw = await _storage.read(key: _key);
    } catch (_) {
      // Locked keychain or similar: try again on the next return to the app.
      return;
    }
    var base = state;
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final order = (map['order'] as List).cast<String>();
        // A row of the wrong length would leave the sheet with a gap or an
        // overflow. Anything but exactly six is treated as unreadable.
        if (order.length == reactionRowLength) {
          final counts = (map['counts'] as Map).map(
            (k, v) => MapEntry(k as String, (v as num).toDouble()),
          );
          // Age on the way in, so a long pause is already priced in before the
          // row is shown for the first time.
          base = ageCounts(
            ReactionUsage(
              order: List<String>.unmodifiable(order),
              counts: counts,
              agedAt: DateTime.parse(map['agedAt'] as String),
            ),
            _now(),
          );
        }
      } catch (_) {
        // Unreadable: the familiar row stands. That is the harmless direction —
        // in doubt the order everyone knows rather than no row at all.
      }
    }
    if (!mounted || _loaded) return;
    if (raw != null && _pending.isNotEmpty) {
      // `state` already holds the seed plus these; start again from what was
      // stored and count them once more on top of it.
      base = _pending.fold(base, (u, p) => noteReaction(u, p.$1, p.$2));
    }
    _loaded = true;
    final hadPending = _pending.isNotEmpty;
    _pending.clear();
    state = base;
    if (hadPending) await _persist(base);
  }

  /// One added reaction. Taking a reaction back does NOT count: otherwise a
  /// mis-tap would push the very emoji one was correcting up the ranking.
  Future<void> note(String emoji) async {
    final at = _now();
    final neu = noteReaction(state, emoji, at);
    state = neu;
    if (!_loaded) {
      _pending.add((emoji, at));
      return;
    }
    await _persist(neu);
  }

  @override
  void dispose() {
    _resumeSub?.cancel();
    super.dispose();
  }

  Future<void> _persist(ReactionUsage u) async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({
          'order': u.order,
          'counts': u.counts,
          'agedAt': u.agedAt.toIso8601String(),
        }),
      );
    } catch (_) {
      // Swallowed on purpose: a row that forgets the last tap is a nuisance,
      // a reaction that fails to register is a bug.
    }
  }
}
