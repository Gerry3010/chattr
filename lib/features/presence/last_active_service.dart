// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/supabase/supabase_client_provider.dart';

/// Marks the signed-in user "active today" for the admin DAU/WAU/MAU metric.
///
/// Deliberately coarse and privacy-minimal: the server RPC `touch_last_active`
/// stamps only a DATE (no time of day) and is idempotent — at most one write per
/// user per calendar day. We additionally throttle in memory so a chatty
/// foreground/background cycle doesn't spam the RPC. Fire-and-forget: a failed
/// ping is never surfaced to the user (analytics must never break the app).
final lastActiveServiceProvider = Provider<LastActiveService>((ref) {
  return LastActiveService(ref);
});

class LastActiveService {
  LastActiveService(this._ref);

  final Ref _ref;
  DateTime? _lastPingedDay;

  Future<void> ping() async {
    final client = _ref.read(supabaseClientProvider);
    if (client.auth.currentUser == null) return; // only for signed-in users

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (_lastPingedDay == today) return; // already pinged today (client-side)
    _lastPingedDay = today;

    try {
      await client.rpc<void>('touch_last_active');
    } catch (_) {
      _lastPingedDay = null; // let a later resume retry
    }
  }
}

/// Invisible host that pings [LastActiveService] on mount and on every app
/// resume. Mount it high in the tree (see app.dart). Kept separate from
/// AppLockGate so analytics and the lock feature stay decoupled.
class LastActivePinger extends ConsumerStatefulWidget {
  const LastActivePinger({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LastActivePinger> createState() => _LastActivePingerState();
}

class _LastActivePingerState extends ConsumerState<LastActivePinger>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer so the first frame (and auth restore) is settled before we ping.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(lastActiveServiceProvider).ping());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(lastActiveServiceProvider).ping());
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
