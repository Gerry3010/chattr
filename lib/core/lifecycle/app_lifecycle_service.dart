// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Emits a signal whenever the app returns to the foreground
/// (`AppLifecycleState.resumed`).
///
/// The OS drops the Supabase Realtime WebSocket while the app is backgrounded,
/// and Supabase does not replay broadcasts sent during that window. Controllers
/// therefore need a catch-up hook on resume: reconnect the realtime channel and
/// re-fetch anything that arrived while we were away. Widgets only *fire* this
/// signal (see [AppLockGate]); the data reactions live in the controllers
/// ([ChatsController], [MessagesController]) — keeping realtime/data logic out
/// of the widget layer per the architecture's golden rule.
class AppLifecycleService {
  final StreamController<void> _resume = StreamController<void>.broadcast();
  final StreamController<void> _return = StreamController<void>.broadcast();

  /// Fires once each time the app is resumed, also after a system dialog
  /// (permission, Face ID / fingerprint) that only made it inactive.
  Stream<void> get onResume => _resume.stream;

  /// Fires only when the user comes BACK to the app: after it was really in
  /// the background (paused/hidden), or after the lock screen let them in.
  ///
  /// Anything that asks for biometrics on its own must listen here, never to
  /// [onResume]: the system's fingerprint prompt makes the app inactive, and
  /// closing it resumes the app. Asking again on that resume brought the
  /// prompt straight back after every cancel, without end (Galaxy,
  /// 2026-10-24).
  Stream<void> get onReturn => _return.stream;

  /// Called by the app-wide lifecycle observer on `resumed`. [fromBackground]
  /// is false when the app was only inactive.
  void notifyResumed({bool fromBackground = true}) {
    if (!_resume.isClosed) _resume.add(null);
    if (fromBackground && !_return.isClosed) _return.add(null);
  }

  void dispose() {
    _resume.close();
    _return.close();
  }
}

/// Session-lifetime provider for the resume signal.
final appLifecycleServiceProvider = Provider<AppLifecycleService>((ref) {
  final service = AppLifecycleService();
  ref.onDispose(service.dispose);
  return service;
});

/// Whether the app is in front right now. Unknown (no lifecycle report yet)
/// counts as in front, which is what a normal cold start looks like. A
/// provider so a test can say "backgrounded" without a running binding.
final appInForegroundProvider = Provider<bool Function()>((_) => () {
      final state = WidgetsBinding.instance.lifecycleState;
      return state == null ||
          state == AppLifecycleState.resumed ||
          state == AppLifecycleState.inactive;
    });
