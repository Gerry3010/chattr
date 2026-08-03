// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

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

  /// Fires once each time the app is resumed from the background.
  Stream<void> get onResume => _resume.stream;

  /// Called by the app-wide lifecycle observer on `resumed`.
  void notifyResumed() {
    if (!_resume.isClosed) _resume.add(null);
  }

  void dispose() {
    _resume.close();
  }
}

/// Session-lifetime provider for the resume signal.
final appLifecycleServiceProvider = Provider<AppLifecycleService>((ref) {
  final service = AppLifecycleService();
  ref.onDispose(service.dispose);
  return service;
});
