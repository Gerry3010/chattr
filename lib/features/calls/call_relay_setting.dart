// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/security_providers.dart';

/// "Route every call through the Chattr server" (default ON).
///
/// A direct call shows each side the other's IP address — that is what
/// "direct" means. With this on, the device offers relay candidates only, so
/// the peer sees the relay's address and never ours. The audio stays end to
/// end encrypted either way; the relay forwards bytes it cannot open.
///
/// On by default (Gerry, 2026-10-04): the address stays private unless the
/// user decides otherwise. The direct path sounds slightly better and costs
/// the server nothing — that is the trade the switch offers, not the default.
/// Only an explicit 'false' turns it off.
final callRelayOnlyProvider = NotifierProvider<CallRelayOnlyController, bool>(
  CallRelayOnlyController.new,
);

class CallRelayOnlyController extends Notifier<bool> {
  static const _storageKey = 'call_relay_only_v1';

  final Completer<void> _loaded = Completer<void>();

  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  Future<void> _load() async {
    try {
      final raw = await ref.read(secureStorageProvider).read(key: _storageKey);
      if (ref.mounted) state = raw != 'false';
    } catch (_) {
      // Unreadable storage: stay at the default (relay) rather than fail a
      // call.
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
  }

  /// The persisted value. A call must await this: right after a cold start
  /// the synchronous state is still the default, and dialing on it would
  /// reveal the IP address the user asked to hide.
  Future<bool> resolvedValue() async {
    await _loaded.future;
    return state;
  }

  Future<void> setEnabled(bool enabled) async {
    await ref
        .read(secureStorageProvider)
        .write(key: _storageKey, value: enabled.toString());
    state = enabled;
  }
}
