// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'call_media.dart';

/// Who a waveform bar belongs to — it takes that side's colour.
enum WaveVoice { silent, peer, me }

/// One bar of the call waveform: how tall (0..1) and whose voice.
class WaveSample {
  const WaveSample(this.height, this.voice);

  static const silent = WaveSample(0, WaveVoice.silent);

  final double height;
  final WaveVoice voice;
}

/// WebRTC reports linear amplitude; speech spans roughly -50 dB (a quiet
/// room) to -6 dB (talking close to the microphone). Linear, a normal voice
/// would barely lift the bars and a laugh would hit the ceiling — the ear
/// hears in decibels, so the wave does too.
double loudness(double amplitude) {
  if (amplitude <= 0) return 0;
  final db = 20 * math.log(amplitude) / math.ln10;
  return ((db + 50) / 44).clamp(0.0, 1.0);
}

/// Below this, nobody is talking; the bar rests as a dot.
const double _quiet = 0.08;

/// Turns one reading into a bar. The louder side wins the bar; [jitter]
/// (0..1, random per bar) keeps a steady tone from drawing a flat block —
/// real speech never looks like one, and the reference wave doesn't either.
WaveSample sampleFrom(CallAudioLevels levels, {double jitter = 1}) {
  final peer = loudness(levels.remote);
  final me = loudness(levels.local);
  final top = math.max(peer, me);
  if (top < _quiet) return WaveSample.silent;
  final factor = 0.6 + 0.4 * jitter.clamp(0.0, 1.0);
  return WaveSample(
    top * factor,
    peer >= me ? WaveVoice.peer : WaveVoice.me,
  );
}

/// Bars shrink towards both ends, so the wave fades out instead of being cut
/// off at the edge of its box.
double edgeTaper(int index, int count) {
  if (count <= 1) return 1;
  return edgeTaperAt((index + 0.5) / count);
}

/// The same fade at a continuous position [t] (0 = left edge, 1 = right).
/// The wave scrolls smoothly, so a bar sits between slots most of the time —
/// tapering by its index would make it jump a step at every slot.
double edgeTaperAt(double t) {
  if (t <= 0 || t >= 1) return 0;
  return math.pow(math.sin(math.pi * t), 0.7).toDouble();
}
