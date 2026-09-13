// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io' show Platform;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

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
  bool _volumeSet = false;

  /// Which of the two sessions is currently installed — `null` means "unknown,
  /// configure before the next sound". Tracked because the iOS session is
  /// process-global: leaving it on the preview session would let an INCOMING
  /// chime play through the silent switch, which is the opposite of what the
  /// switch is for.
  bool? _sessionIsPreview;

  /// Plays [assetPath] (relative to the bundled `assets/` prefix, e.g.
  /// `sounds/rise.mp3`).
  ///
  /// [preview] marks the picker's play button — a sound the user just asked to
  /// hear, as opposed to one the app plays at them. The two need different
  /// audio sessions; see [audioContextFor].
  Future<void> play(String assetPath, {bool preview = false}) async {
    try {
      final player = _player ??= AudioPlayer(playerId: 'notification_chime')
        ..setReleaseMode(ReleaseMode.stop);
      if (!_volumeSet) {
        await player.setVolume(0.7);
        _volumeSet = true;
      }
      if (_sessionIsPreview != preview) {
        await _applyAudioContext(player, preview: preview);
        _sessionIsPreview = preview;
      }
      await player.stop();
      await player.play(AssetSource(assetPath));
    } catch (e) {
      // Forget which session is installed: the failure may have happened
      // halfway through switching it, and guessing wrong here is exactly how a
      // notification chime would end up ignoring the silent switch.
      _sessionIsPreview = null;
      logger.debug('Notification sound failed (ignored): $e');
    }
  }

  /// The audio session for one of the two cases — pure, so the invariant below
  /// can be tested without a platform channel.
  ///
  /// **An incoming chime must honor the silent switch, a preview must not.**
  /// They are different acts: the chime is the app speaking unbidden, so
  /// `ambient` (muted by the ringer switch, never interrupting other audio) is
  /// right. The preview only ever happens because the user tapped play — and a
  /// picker whose play button does nothing looks broken, not considerate. iOS's
  /// own ringtone picker takes the same line. `playback` is the category that
  /// ignores the switch; `mixWithOthers` keeps it from stopping music.
  ///
  /// Android has no silent switch, but the same reasoning applies to the
  /// volume streams: the chime rides the notification stream (and with it DND),
  /// while the preview goes out over media, so a muted notification stream
  /// doesn't turn the play button into a no-op there either.
  @visibleForTesting
  static AudioContext audioContextFor({required bool preview}) => AudioContext(
        iOS: AudioContextIOS(
          category: preview
              ? AVAudioSessionCategory.playback
              : AVAudioSessionCategory.ambient,
          // Only `playback` MAY carry the option at all — audioplayers throws
          // otherwise. `ambient` mixes of its own accord anyway; the option was
          // always superfluous there and made setting the session run into the
          // (swallowed) error in a debug build, so that of all things the
          // default category `playback` remained.
          options: preview
              ? const {AVAudioSessionOptions.mixWithOthers}
              : const <AVAudioSessionOptions>{},
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: false,
          stayAwake: false,
          contentType: preview
              ? AndroidContentType.music
              : AndroidContentType.sonification,
          usageType:
              preview ? AndroidUsageType.media : AndroidUsageType.notification,
          // No focus request → background music keeps playing untouched.
          audioFocus: AndroidAudioFocus.none,
        ),
      );

  Future<void> _applyAudioContext(
    AudioPlayer player, {
    required bool preview,
  }) async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    final ctx = audioContextFor(preview: preview);
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
