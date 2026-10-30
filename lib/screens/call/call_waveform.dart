// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/calls/call_controller.dart';
import '../../features/calls/call_media.dart';
import '../../features/calls/call_waveform_rules.dart';

/// How often the wave takes a reading — each one becomes a bar. Fast enough
/// to follow syllables, slow enough that getStats() stays negligible.
const Duration _interval = Duration(milliseconds: 80);

/// The running call's loudness, polled from the media. Lives only while a
/// waveform watches it.
final callAudioLevelsProvider =
    StreamProvider.autoDispose<CallAudioLevels>((ref) async* {
  final controller = ref.read(callControllerProvider.notifier);
  while (true) {
    await Future<void>.delayed(_interval);
    yield await controller.audioLevels();
  }
});

/// Bars that run from right to left with the conversation: the peer's voice
/// in the theme's primary colour, our own in its tertiary one, silence as a
/// row of dots.
///
/// **Why a ticker and a queue.** Readings arrive every ~80 ms, and not even
/// evenly — getStats() is an async round trip. Shifting a whole bar per
/// reading moved the wave in 12 jerky steps a second, and every late reading
/// showed as a stutter (Gerry: "wirkt laggy"). Now the wave scrolls at a
/// constant speed, frame by frame, and readings wait in a short queue until
/// their slot comes up. The queue is capped, so a burst of late readings
/// cannot make the wave lag behind the voice.
class CallWaveform extends ConsumerStatefulWidget {
  const CallWaveform({super.key, this.height = 72});

  final double height;

  @override
  ConsumerState<CallWaveform> createState() => _CallWaveformState();
}

class _CallWaveformState extends ConsumerState<CallWaveform>
    with SingleTickerProviderStateMixin {
  static const int _maxBars = 48;

  /// More than this many readings waiting means we are behind: drop the
  /// oldest rather than show the voice late.
  static const int _maxQueued = 3;

  final _bars = List<WaveSample>.filled(_maxBars + 1, WaveSample.silent,
      growable: true);
  final _queue = Queue<WaveSample>();
  final _random = math.Random();

  /// Fraction of one slot the wave has scrolled since the last bar entered.
  final _phase = ValueNotifier<double>(0);
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _last;
    _last = elapsed;
    var phase =
        _phase.value + dt.inMicroseconds / _interval.inMicroseconds;
    while (phase >= 1) {
      phase -= 1;
      _bars
        ..removeAt(0)
        ..add(_queue.isNotEmpty ? _queue.removeFirst() : _fadeOf(_bars.last));
    }
    _phase.value = phase;
  }

  /// No reading in time: let the last bar ebb instead of dropping to a dot —
  /// a gap of one slot is a late reading, not silence.
  WaveSample _fadeOf(WaveSample s) => s.height < 0.05
      ? WaveSample.silent
      : WaveSample(s.height * 0.6, s.voice);

  @override
  void dispose() {
    _ticker.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(callAudioLevelsProvider, (_, next) {
      final levels = next.value;
      if (levels == null) return;
      _queue.add(sampleFrom(levels, jitter: _random.nextDouble()));
      while (_queue.length > _maxQueued) {
        _queue.removeFirst();
      }
    });
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _WavePainter(
              bars: _bars,
              phase: _phase,
              peer: scheme.primary,
              me: scheme.tertiary,
              rest: scheme.onSurfaceVariant.withValues(alpha: 0.35),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.bars,
    required this.phase,
    required this.peer,
    required this.me,
    required this.rest,
  }) : super(repaint: phase);

  /// Shared with the state and mutated in place; [phase] triggers repaints.
  final List<WaveSample> bars;
  final ValueNotifier<double> phase;
  final Color peer;
  final Color me;
  final Color rest;

  static const double _barWidth = 3;
  static const double _gap = 4;
  static const double _pitch = _barWidth + _gap;

  @override
  void paint(Canvas canvas, Size size) {
    final slots = math.min(
        ((size.width + _gap) / _pitch).floor(), bars.length - 1);
    if (slots <= 0) return;
    final total = slots * _pitch - _gap;
    final left = (size.width - total) / 2;
    final mid = size.height / 2;
    final shift = phase.value * _pitch;
    final paint = Paint()
      ..strokeWidth = _barWidth
      ..strokeCap = StrokeCap.round;

    // One bar more than fits: while the wave scrolls, the newest one slides
    // in from the right as the oldest leaves on the left.
    final shown = bars.sublist(bars.length - slots - 1);
    for (var i = 0; i < shown.length; i++) {
      final x = left + i * _pitch + _barWidth / 2 - shift;
      final t = (x - left) / total;
      final taper = edgeTaperAt(t);
      if (taper <= 0) continue;
      final b = shown[i];
      final half = (size.height / 2 - _barWidth / 2) * b.height * taper;
      paint.color = switch (b.voice) {
        WaveVoice.peer => peer,
        WaveVoice.me => me,
        WaveVoice.silent => rest,
      };
      // A zero-length round-capped line is a dot — the resting state.
      canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.peer != peer || old.me != me || old.rest != rest;
}
