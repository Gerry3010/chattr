// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Item 3 (1.9): the floating PiP window snaps to the nearest screen corner when
// a drag ends. nearestCorner is pure (no widgets) so it's unit-tested here.

import 'package:chattr/features/media/pip_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const screen = Size(400, 800); // mid = (200, 400)

  test('each quadrant snaps to its corner', () {
    expect(nearestCorner(const Offset(50, 100), screen), PipCorner.topLeft);
    expect(nearestCorner(const Offset(350, 100), screen), PipCorner.topRight);
    expect(nearestCorner(const Offset(50, 700), screen), PipCorner.bottomLeft);
    expect(nearestCorner(const Offset(350, 700), screen), PipCorner.bottomRight);
  });

  test('exact-midpoint bias: center goes to the bottom-right quadrant', () {
    // dx<mid and dy<mid are strict, so exactly the midpoint is NOT left/top.
    expect(nearestCorner(const Offset(200, 400), screen), PipCorner.bottomRight);
  });

  test('just across each axis flips the expected side', () {
    expect(nearestCorner(const Offset(199, 399), screen), PipCorner.topLeft);
    expect(nearestCorner(const Offset(201, 399), screen), PipCorner.topRight);
    expect(nearestCorner(const Offset(199, 401), screen), PipCorner.bottomLeft);
  });
}
