// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/logging/logger_service.dart';

/// App-wide single-active-video coordinator: when one inline video starts
/// playing, any other one that was playing is paused. Without this, several
/// inline players in a chat play (and blast audio) simultaneously.
///
/// Engine-agnostic: media_kit players (chat + stream link videos) use the
/// [setActive]/[release] `Player` API; a non-media_kit player (the YouTube
/// webview) uses [setActiveExternal]/[releaseExternal] with any identity token
/// and its own pause callback. Both share the single active slot, so starting a
/// YouTube video pauses a playing chat video and vice versa.
class ActiveVideoRegistry {
  /// Identity of the currently-active player (a media_kit [Player] or an
  /// external token) and the callback that pauses it.
  Object? _activeToken;
  void Function()? _pauseActive;

  void _activate(Object token, void Function() pause) {
    final previous = _activeToken;
    final pausePrevious = _pauseActive;
    if (previous != null && !identical(previous, token)) {
      // Best-effort pause; a disposed player just throws and is ignored.
      try {
        pausePrevious?.call();
        logger.info('Paused previously active video', tag: 'ActiveVideo');
      } catch (_) {}
    }
    _activeToken = token;
    _pauseActive = pause;
  }

  void _releaseToken(Object token) {
    if (identical(_activeToken, token)) {
      _activeToken = null;
      _pauseActive = null;
    }
  }

  /// Mark [player] as the one now playing; pause the previously active one.
  void setActive(Player player) => _activate(player, player.pause);

  /// Called when a player pauses or is disposed; clears it if it was active.
  void release(Player player) => _releaseToken(player);

  /// Non-media_kit variant: [token] identifies the player (e.g. a
  /// `YoutubePlayerController`), [pause] pauses it when another video takes over.
  void setActiveExternal(Object token, void Function() pause) =>
      _activate(token, pause);

  /// Clears [token] if it was the active one (on pause/dispose).
  void releaseExternal(Object token) => _releaseToken(token);
}

final activeVideoRegistryProvider = Provider<ActiveVideoRegistry>((ref) {
  return ActiveVideoRegistry();
});
