// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../logging/logger_service.dart';

/// Plays a short chime for incoming in-app notifications (new message, join
/// request, …). The concrete sound is chosen by the user via the notification
/// sound picker; callers pass the selected asset path. Best-effort: a missing
/// asset or a browser's autoplay restriction (before the first user
/// interaction) is swallowed so a silent failure never breaks the notification
/// itself.
class NotificationSound {
  NotificationSound._();
  static final NotificationSound instance = NotificationSound._();

  // A single reusable player, created lazily on first play. Constructing an
  // AudioPlayer touches platform channels, so it must happen inside play()'s
  // try/catch — never at field-init time — or a headless/test environment
  // without a live binding would throw before we could swallow it.
  AudioPlayer? _player;
  bool _configured = false;

  /// Plays [assetPath] (relative to the bundled `assets/` prefix, e.g.
  /// `sounds/rise.mp3`). Used both for incoming notifications and for previews
  /// in the picker.
  Future<void> play(String assetPath) async {
    try {
      final player = _player ??= AudioPlayer(playerId: 'notification_chime')
        ..setReleaseMode(ReleaseMode.stop);
      if (!_configured) {
        await player.setVolume(0.7);
        await _configureAudioContext(player);
        _configured = true;
      }
      await player.stop();
      await player.play(AssetSource(assetPath));
    } catch (e) {
      logger.debug('Notification sound failed (ignored): $e');
    }
  }

  /// Classifies the chime as a notification sound instead of media playback.
  /// Without this, audioplayers defaults to the `playback` category, which on
  /// iOS plays through the silent switch and on both platforms grabs audio
  /// focus — pausing/ducking whatever the user is listening to in another app.
  Future<void> _configureAudioContext(AudioPlayer player) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    final ctx = AudioContext(
      iOS: AudioContextIOS(
        // `ambient` is muted by the ringer/silent switch and, combined with
        // mixWithOthers, never interrupts other apps' audio.
        category: AVAudioSessionCategory.ambient,
        options: const {AVAudioSessionOptions.mixWithOthers},
      ),
      android: const AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: false,
        contentType: AndroidContentType.sonification,
        // Notification usage → notification volume stream, honors DND.
        usageType: AndroidUsageType.notification,
        // No focus request → background music keeps playing untouched.
        audioFocus: AndroidAudioFocus.none,
      ),
    );
    if (Platform.isIOS) {
      // The iOS audio session is process-global; per-player contexts don't
      // apply there. Note: media_kit (video playback) manages its own session
      // and re-activates it when a video plays — acceptable interplay,
      // verified via TestFlight.
      await AudioPlayer.global.setAudioContext(ctx);
    } else {
      await player.setAudioContext(ctx);
    }
  }
}
