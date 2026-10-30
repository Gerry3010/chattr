// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The call waveform: loudness in decibels, who a bar belongs to, and the
// fade towards both ends.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/calls/call_media.dart';
import 'package:chattr/features/calls/call_waveform_rules.dart';

void main() {
  test('Lautstärke in Dezibel: Stille 0, Sprechen dazwischen, laut 1', () {
    expect(loudness(0), 0);
    expect(loudness(0.002), 0); // ~-54 dB, a quiet room
    final speech = loudness(0.05); // ~-26 dB
    expect(speech, greaterThan(0.4));
    expect(speech, lessThan(0.7));
    expect(loudness(1), 1);
  });

  test('wer lauter ist, bekommt den Balken', () {
    expect(
        sampleFrom(const CallAudioLevels(remote: 0.2, local: 0.01)).voice,
        WaveVoice.peer);
    expect(
        sampleFrom(const CallAudioLevels(remote: 0.01, local: 0.2)).voice,
        WaveVoice.me);
  });

  test('Stille ruht als Punkt', () {
    final s = sampleFrom(const CallAudioLevels(remote: 0.001, local: 0.001));
    expect(s.voice, WaveVoice.silent);
    expect(s.height, 0);
  });

  test('das Zittern dämpft, löscht aber nie', () {
    const l = CallAudioLevels(remote: 0.3);
    final full = sampleFrom(l, jitter: 1).height;
    final low = sampleFrom(l, jitter: 0).height;
    expect(low, closeTo(full * 0.6, 1e-9));
    expect(low, greaterThan(0));
  });

  test('die Balken laufen zu beiden Rändern hin aus', () {
    expect(edgeTaper(0, 40), lessThan(0.2));
    expect(edgeTaper(39, 40), lessThan(0.2));
    expect(edgeTaper(20, 40), greaterThan(0.95));
    expect(edgeTaper(0, 1), 1);
  });

  test('fließende Verjüngung: stetig, an den Rändern null', () {
    expect(edgeTaperAt(0), 0);
    expect(edgeTaperAt(1), 0);
    expect(edgeTaperAt(0.5), closeTo(1, 1e-9));
    // No step between neighbouring positions — that was the jump.
    expect((edgeTaperAt(0.30) - edgeTaperAt(0.31)).abs(), lessThan(0.02));
    expect(edgeTaper(20, 40), closeTo(edgeTaperAt(20.5 / 40), 1e-12));
  });
}
