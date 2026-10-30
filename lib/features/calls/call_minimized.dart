// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_controller.dart';
import 'call_rules.dart';

/// Whether a call in [phase] may shrink to the bar at the top. Everything but
/// the end screen, which clears itself anyway.
///
/// A ringing call too, since 2026-10-24 (Gerry): it used to block the whole
/// app until answered or declined. It rings on while minimized (on iOS in
/// CallKit regardless); only the screen gets out of the way, and the bar
/// offers accept and decline itself.
bool canMinimizeCall(CallPhase phase) =>
    phase == CallPhase.incoming ||
    phase == CallPhase.outgoing ||
    phase == CallPhase.connecting ||
    phase == CallPhase.active;

/// The call screen shrunk to a bar, so the rest of the app stays usable
/// during a call. Purely UI: the call itself runs on unchanged — and on iOS
/// a call taken via CallKit stays in CallKit.
///
/// Falls back to the full screen whenever a new call starts ringing or the
/// call is gone, so the next call never starts out hidden. Minimizing a call
/// that is ringing already does not count: its phase does not change.
class CallMinimizedNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(callControllerProvider.select((s) => s.phase), (_, phase) {
      if (phase == CallPhase.incoming || phase == CallPhase.idle) {
        state = false;
      }
    });
    return false;
  }

  void minimize() {
    if (canMinimizeCall(ref.read(callControllerProvider).phase)) state = true;
  }

  void expand() => state = false;
}

final callMinimizedProvider = NotifierProvider<CallMinimizedNotifier, bool>(
  CallMinimizedNotifier.new,
);
