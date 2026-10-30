// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../push_notifications/push_notifications_provider.dart';
import 'call_controller.dart';
import 'call_system_ui.dart';

/// Connects the system call UI (stage 3) to the running app: accept/decline
/// taps go to [CallController], and on iOS the PushKit token is registered so
/// the server can wake this device.
///
/// Alive while someone is signed in — watched by the call overlay, which sits
/// above every route. Without a session there is nothing to fetch an invite
/// with, and no account a token could belong to.
final callSystemBridgeProvider = Provider<void>((ref) {
  if (!systemCallUiSupported) return;
  final userId = ref.watch(authControllerProvider);
  if (userId == null) return;

  final sub = systemCallActions().listen((action) {
    final controller = ref.read(callControllerProvider.notifier);
    switch (action) {
      case SystemCallAccepted():
        unawaited(controller.acceptFromSystem(action.signalId));
      case SystemCallDeclined():
        unawaited(controller.declineFromSystem(action.signalId));
      case SystemCallEnded():
        controller.endFromSystem(action.signalId);
    }
  });
  ref.onDispose(sub.cancel);

  Future<void> registerVoipToken() async {
    final token = await voipPushToken();
    if (token == null) return;
    try {
      await ref
          .read(deviceTokenRepositoryProvider)
          .saveToken(token, platform: 'ios_voip');
    } catch (_) {
      // Logged in the repository; the next start tries again.
    }
  }

  unawaited(registerVoipToken());
  // PushKit may hand out a new token at any time; the old one then stops
  // working, and with it every call to this phone.
  final tokenSub = FlutterCallkitIncoming.onEvent
      .where((e) => e is CallEventActionDidUpdateDevicePushTokenVoip)
      .listen((_) => unawaited(registerVoipToken()));
  ref.onDispose(tokenSub.cancel);
});
