// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';

/// The sounds of a call while the app is open: a looping ringtone plus a
/// haptic tick for an incoming call, and a short falling tone when a call
/// ends — on both sides, so hanging up is heard, not only seen.
///
/// Stage 1 only rings in the foreground — a closed app hears nothing, which
/// is what CallKit / ConnectionService are for (stage 3). The tones were made
/// with ElevenLabs (2026-10-04, Gerry's pick); later the ringtone becomes a
/// setting.
abstract class CallRinger {
  /// Incoming call: ringtone loop plus haptics.
  void start();

  /// Outgoing call: the caller hears the same tone, quieter and without
  /// vibration, while the other side rings — silence there reads as "broken".
  void startRingback();

  void stop();

  /// Plays the end-of-call tone once. Independent of [stop], which only ends
  /// the ringing.
  void playEndTone();
}

final callRingerProvider = Provider<CallRinger>((ref) {
  final ringer = _ToneRinger();
  ref.onDispose(ringer.dispose);
  return ringer;
});

class _ToneRinger implements CallRinger {
  // WAV on purpose: an MP3 carries encoder padding at both ends, and in a
  // loop that is an audible gap every three seconds.
  // The file ends in a faded tail plus a second of silence. The original cut
  // the second ring off mid-decay and jumped straight into the first, and
  // the players' own loop seam (audible on iOS and the web) fell into sound.
  // Now the seam falls into the pause, where nobody hears it.
  static const _ringAsset = 'sounds/call_ring.wav';
  static const _endAsset = 'sounds/call_end.mp3';
  static const _hapticInterval = Duration(milliseconds: 1500);

  AudioPlayer? _ring;
  Timer? _haptics;

  static const double _ringbackVolume = 0.35;

  @override
  void start() {
    if (_haptics != null) return;
    unawaited(HapticFeedback.heavyImpact());
    _haptics = Timer.periodic(
        _hapticInterval, (_) => unawaited(HapticFeedback.heavyImpact()));
    _loop(volume: 1);
  }

  @override
  void startRingback() {
    if (_ring != null) return;
    _loop(volume: _ringbackVolume);
  }

  void _loop({required double volume}) {
    () async {
      try {
        final player = _ring ??= AudioPlayer();
        await player.setReleaseMode(ReleaseMode.loop);
        await player.setVolume(volume);
        await player.play(AssetSource(_ringAsset));
      } catch (e) {
        logger.warning('Ringer could not play: $e', tag: 'Calls');
      }
    }();
  }

  @override
  void stop() {
    _haptics?.cancel();
    _haptics = null;
    final player = _ring;
    _ring = null;
    if (player != null) {
      unawaited(player.stop().then((_) => player.dispose()));
    }
  }

  @override
  void playEndTone() {
    () async {
      // A player of its own, released when the tone is through — it must
      // outlive the call screen it belongs to.
      final player = AudioPlayer();
      try {
        await player.setReleaseMode(ReleaseMode.release);
        player.onPlayerComplete.first.then((_) => player.dispose());
        await player.play(AssetSource(_endAsset));
      } catch (e) {
        logger.warning('End tone could not play: $e', tag: 'Calls');
        unawaited(player.dispose());
      }
    }();
  }

  void dispose() => stop();
}
