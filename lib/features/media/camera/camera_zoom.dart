// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The arithmetic behind the pinch gesture — **no camera, no widgets**.
///
/// Same cut as with the shutter ([CameraShutter]): the UI only reports how far
/// the two fingers moved apart; what comes of that lives here and is therefore
/// testable.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:intl/intl.dart';

/// The ceiling we impose on ourselves — regardless of what the device offers.
///
/// Some phones report ranges far beyond it (Samsung advertises its "Space Zoom"
/// at 100×). The cap is not a technical limit but a decision: up to here there
/// is still something to make out on screen, above it the picture turns to
/// mush, and the drag gesture would squander its travel on a range nobody uses.
/// Because the mapping is **doubling**, a high ceiling does not only cost the
/// topmost stretch: it stretches the whole scale, and the lower steps — the
/// frequent ones — become harder to hit.
const double zoomCeiling = 100;

/// What the camera actually offers in the way of zoom.
///
/// **Asked, not assumed.** Some devices start below 1.0 (the ultra-wide),
/// others stop at 1.0 — a fixed range would zoom too little on one device and
/// into nothing on the other.
@immutable
class CameraZoomRange {
  const CameraZoomRange({required this.min, required this.max});

  /// The range as the **device** reports it — capped at [zoomCeiling] and
  /// guarded against nonsense.
  ///
  /// A device can report anything here: infinity, too little, or an upper bound
  /// below the lower one. Taken at face value that yields a range in which the
  /// pinch gesture goes nowhere — and only on the device, where nobody looks
  /// into why any more.
  factory CameraZoomRange.fromDevice({
    required double min,
    required double max,
  }) {
    // Infinity is **not** nonsense but "open at the top" — the cap answers that
    // anyway. Only NaN is unusable (math.min would give no reliable answer on
    // it), and a lower bound of zero or below is not a range but a fault of the
    // device.
    if (!min.isFinite || max.isNaN || min <= 0) return none;
    final top = math.min(max, zoomCeiling);
    if (top <= min) return CameraZoomRange(min: min, max: min);
    return CameraZoomRange(min: min, max: top);
  }

  /// What the device has not revealed yet (or cannot do): no range.
  static const CameraZoomRange none = CameraZoomRange(min: 1, max: 1);

  final double min;
  final double max;

  /// Is there anything to zoom here at all? A range from 1.0 to 1.0 is none —
  /// the front camera of many devices reports exactly that.
  bool get available => max - min > 0.01;

  /// Holds a value inside the range. The starting value passes through here
  /// too: `1.0` is not allowed everywhere.
  double clamp(double value) {
    if (!value.isFinite) return min;
    return value.clamp(min, max).toDouble();
  }
}

/// From the gesture to the level.
///
/// [base] is the zoom that applied when the fingers **touched down** — the
/// scale of a pinch gesture is relative to its start, not absolute. Multiplying
/// the running value instead accelerates itself: every report multiplies again,
/// and the zoom shoots to the end on the first tug.
double zoomFromPinch({
  required CameraZoomRange range,
  required double base,
  required double scale,
}) {
  if (!range.available) return range.clamp(base);
  return range.clamp(base * scale);
}

/// From the **drag distance** to the level — the second way to zoom.
///
/// **Why distance and not direction.** What is measured is solely the distance
/// from the starting point (`Offset.distance`, i.e. the hypotenuse). An angle —
/// what trigonometric functions would additionally supply — would be harmful
/// here: it would make the gesture direction-dependent, and in landscape the
/// fingers would then pull the wrong way. The radius alone is independent of
/// orientation, and that is exactly the guarantee this gesture is meant to
/// give.
///
/// **Why the mapping is geometric and not linear.** Going from 1x to 2x looks
/// like just as much change as going from 5x to 10x — both times the picture
/// doubles. Equal finger travel must therefore **multiply**, not add. Mapped
/// linearly, almost everything visible happened in the first few millimetres
/// and hardly anything after that.
///
/// [distance] and [span] in logical pixels. Below [threshold] nothing happens —
/// otherwise the mere tremor of the finger on the shutter would already zoom.
double zoomFromDrag({
  required CameraZoomRange range,
  required double distance,
  required double threshold,
  required double span,
  double? start,
}) {
  final base = range.clamp(start ?? range.min);
  if (!range.available || base <= 0 || span <= 0) return base;
  if (!distance.isFinite) return base;
  final fraction = ((distance - threshold) / span).clamp(0.0, 1.0);
  if (fraction == 0) return base;
  if (range.max <= base) return base;
  // base * (max/base)^fraction — at 0 the starting level, at 1 the end.
  return range.clamp(base * math.pow(range.max / base, fraction));
}

/// Label for the readout — one decimal place, because nobody reads two and none
/// at all swallows the difference between 1.2x and 1.8x.
///
/// Via `NumberFormat` and not via `toStringAsFixed`, so that a comma appears in
/// German-speaking locales. A "1.8x" in an otherwise German interface reads
/// like a leftover somebody missed.
String zoomLabel(double level, [String? locale]) =>
    '${NumberFormat('0.0', locale).format(level)}\u00d7';

/// An welchem Rand die Bedienung sitzt.
enum ControlEdge { bottom, left, right }

/// The edge the USB-C port sits on.
///
/// **Why at all.** The interface rotates with the device (no orientation lock,
/// auto-rotate on). In landscape the controls therefore slid to the long edge —
/// to where the edge of the screen was in portrait, not to where the hand is.
/// At the bottom edge of the device they are the same edge in every
/// orientation.
///
/// **Established on the device** (Galaxy A26, 2026-09-04, both landscape
/// orientations): this mapping is correct. It was briefly swapped once because
/// I had applied a report about the *preview* to the controls — not because it
/// was wrong.
///
/// It cannot be derived: whether Flutter's `landscapeLeft` means the device
/// turned clockwise or the one turned against it yields **opposite** answers
/// from Flutter's documentation and Android's `Surface.ROTATION_*`. Whoever
/// touches these two lines verifies them on the device, not in the docs.
ControlEdge controlEdgeFor(DeviceOrientation orientation) =>
    switch (orientation) {
      DeviceOrientation.portraitUp => ControlEdge.bottom,
      // Upside down it stays at the bottom: the edge would be up top, but the
      // hand is not — and that orientation practically never occurs on phones.
      DeviceOrientation.portraitDown => ControlEdge.bottom,
      DeviceOrientation.landscapeLeft => ControlEdge.right,
      DeviceOrientation.landscapeRight => ControlEdge.left,
    };
