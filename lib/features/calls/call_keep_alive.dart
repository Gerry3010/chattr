// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io' show Platform;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';

/// Keeps a call's microphone and sound while the app is in the background.
///
/// On Android an app that leaves the screen loses both — the microphone is a
/// while-in-use permission, and background playback is muted (measured on the
/// Galaxy, 2026-10-05; reported from a Pixel as "the call drops"). The cure is
/// Android's own: a foreground service of type phoneCall|microphone with an
/// ongoing-call notification (`CallForegroundService.kt`). iOS keeps a call
/// alive through its audio session and needs nothing here.
abstract class CallKeepAlive {
  void setActive(bool active);

  /// "Auflegen" tapped in the ongoing-call notification.
  Stream<void> get hangUpRequests;
}

class _AndroidCallKeepAlive implements CallKeepAlive {
  _AndroidCallKeepAlive() {
    if (!_supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'hangUp') _hangUps.add(null);
    });
  }

  static const _channel = MethodChannel('chattr/call_service');
  final _hangUps = StreamController<void>.broadcast();
  bool _active = false;

  @override
  Stream<void> get hangUpRequests => _hangUps.stream;

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  @override
  void setActive(bool active) {
    if (!_supported || active == _active) return;
    _active = active;
    final call = active
        ? _channel.invokeMethod<bool>('start', <String, String>{
            'title': 'Chattr',
            'text': 'call.ongoing'.tr(),
            'hangUp': 'call.hang_up'.tr(),
          })
        : _channel.invokeMethod<bool>('stop');
    call.catchError((Object e) {
      logger.warning('Call keep-alive failed: $e', tag: 'Calls');
      return false;
    });
  }
}

final callKeepAliveProvider = Provider<CallKeepAlive>((ref) {
  final k = _AndroidCallKeepAlive();
  ref.onDispose(() {
    k.setActive(false);
    unawaited(k._hangUps.close());
  });
  return k;
});
