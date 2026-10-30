// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:proximity_screen_lock/proximity_screen_lock.dart';

import '../../core/logging/logger_service.dart';

/// Turns the screen off while the phone is held to the ear, so a cheek does
/// not hang up, mute or switch the speaker (Gerry, 2026-10-05). The sensor
/// does the "at the ear" part; this only says when listening for it makes
/// sense — see `wantsProximityLock`.
abstract class CallProximity {
  void setActive(bool active);
}

/// When the screen may go dark at the ear: a call is under way and the sound
/// comes from the earpiece. Not while it rings — "accept" must stay visible —
/// and not on the speaker, where the phone is in front of the face.
bool wantsProximityLock({required bool callUnderWay, required bool speakerOn}) =>
    callUnderWay && !speakerOn;

class _PluginProximity implements CallProximity {
  bool _active = false;

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void setActive(bool active) {
    if (!_supported || active == _active) return;
    _active = active;
    ProximityScreenLock.setActive(active).catchError((Object e) {
      logger.warning('Proximity lock failed: $e', tag: 'Calls');
    });
  }
}

final callProximityProvider = Provider<CallProximity>((ref) {
  final p = _PluginProximity();
  ref.onDispose(() => p.setActive(false));
  return p;
});
