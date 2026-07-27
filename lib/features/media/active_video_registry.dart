// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/logging/logger_service.dart';

/// App-wide single-active-video coordinator: when one inline video starts
/// playing, any other one that was playing is paused. Without this, several
/// inline players in a chat play (and blast audio) simultaneously.
class ActiveVideoRegistry {
  Player? _active;

  /// Mark [player] as the one now playing; pause the previously active one.
  void setActive(Player player) {
    final previous = _active;
    if (previous != null && !identical(previous, player)) {
      // Best-effort pause; a disposed player just throws and is ignored.
      try {
        previous.pause();
        logger.info('Paused previously active video', tag: 'ActiveVideo');
      } catch (_) {}
    }
    _active = player;
  }

  /// Called when a player pauses or is disposed; clears it if it was active.
  void release(Player player) {
    if (identical(_active, player)) _active = null;
  }
}

final activeVideoRegistryProvider = Provider<ActiveVideoRegistry>((ref) {
  return ActiveVideoRegistry();
});
