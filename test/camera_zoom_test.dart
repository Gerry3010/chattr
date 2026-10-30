// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/camera/camera_zoom.dart';

void main() {
  group('CameraZoomRange.fromDevice', () {
    test('caps an oversized range at the ceiling', () {
      // Samsung's "Space Zoom" reports far more than can still be made out.
      final r = CameraZoomRange.fromDevice(min: 1, max: 1000);
      expect(r.max, zoomCeiling);
      expect(r.min, 1);
    });

    test('leaves a smaller range untouched', () {
      final r = CameraZoomRange.fromDevice(min: 0.5, max: 8);
      expect(r.min, 0.5);
      expect(r.max, 8);
    });

    test('exactly on the limit the limit stays', () {
      expect(CameraZoomRange.fromDevice(min: 1, max: zoomCeiling).max,
          zoomCeiling);
    });

    test('nonsense from the device yields no range rather than a broken one', () {
      expect(CameraZoomRange.fromDevice(min: 1, max: double.infinity).max,
          zoomCeiling);
      expect(CameraZoomRange.fromDevice(min: double.nan, max: 4).available,
          isFalse);
      expect(CameraZoomRange.fromDevice(min: 0, max: 4).available, isFalse);
      // Upper bound below the lower one: no range, but no jump either.
      final verdreht = CameraZoomRange.fromDevice(min: 5, max: 2);
      expect(verdreht.available, isFalse);
      expect(verdreht.clamp(3), 5);
    });

    test('the cap also bounds where the drag gesture leads', () {
      final r = CameraZoomRange.fromDevice(min: 1, max: 1000);
      final ganz = zoomFromDrag(
        range: r,
        distance: 10000,
        threshold: 56,
        span: 200,
      );
      expect(ganz, zoomCeiling);
    });
  });

  group('CameraZoomRange', () {
    test('a range from 1 to 1 is none — front cameras report exactly that',
        () {
      expect(const CameraZoomRange(min: 1, max: 1).available, isFalse);
      expect(CameraZoomRange.none.available, isFalse);
      expect(const CameraZoomRange(min: 1, max: 8).available, isTrue);
    });

    test('clamps at both ends', () {
      const b = CameraZoomRange(min: 0.5, max: 4);
      expect(b.clamp(0.1), 0.5);
      expect(b.clamp(2), 2);
      expect(b.clamp(99), 4);
    });

    test('an unusable value lands at the bottom end rather than nowhere',
        () {
      const b = CameraZoomRange(min: 1, max: 4);
      expect(b.clamp(double.nan), 1);
      expect(b.clamp(double.infinity), 1);
    });
  });

  group('zoomFromPinch', () {
    const b = CameraZoomRange(min: 1, max: 8);

    test('the scale computes against the level at touch-down, not the current one',
        () {
      // The same report twice has to yield the same value — otherwise the
      // gesture accelerates itself.
      expect(zoomFromPinch(range: b, base: 2, scale: 1.5), 3);
      expect(zoomFromPinch(range: b, base: 2, scale: 1.5), 3);
    });

    test('a scale of 1 leaves the level alone', () {
      expect(zoomFromPinch(range: b, base: 2.5, scale: 1), 2.5);
    });

    test('stays inside the range', () {
      expect(zoomFromPinch(range: b, base: 6, scale: 4), 8);
      expect(zoomFromPinch(range: b, base: 1.2, scale: 0.1), 1);
    });

    test('without a range nothing happens — not secretly either', () {
      expect(
          zoomFromPinch(range: CameraZoomRange.none, base: 1, scale: 3), 1);
    });
  });

  group('zoomFromDrag', () {
    const b = CameraZoomRange(min: 1, max: 10);
    const threshold = 56.0;
    const span = 200.0;

    double at(double distance, {double start = 1}) => zoomFromDrag(
          range: b,
          distance: distance,
          threshold: threshold,
          span: span,
          start: start,
        );

    test('below the threshold nothing happens — not even a little', () {
      expect(at(0), 1);
      expect(at(55), 1);
      expect(at(56), 1);
    });

    test('at the end of the travel stands the device maximum', () {
      expect(at(threshold + span), closeTo(10, 0.001));
      // Beyond that it does not zoom further but holds.
      expect(at(threshold + span + 500), closeTo(10, 0.001));
    });

    test('the mapping is geometric: half the travel = the square root of the factor',
        () {
      // 1 → 10 ueber die volle Spanne, also 1 → sqrt(10) auf halber Strecke.
      expect(at(threshold + span / 2), closeTo(3.1623, 0.001));
    });

    test('back to the shutter means back to the starting level', () {
      expect(at(threshold + 120), greaterThan(1));
      expect(at(threshold + 20, start: 1), lessThan(at(threshold + 120)));
      expect(at(10), 1);
    });

    test('the starting level is the floor, not the camera minimum', () {
      // Whoever touches down at 2x does not fall to 1x when pulling back.
      expect(at(0, start: 2), 2);
      expect(at(threshold + span, start: 2), closeTo(10, 0.001));
    });

    test('without a camera range everything stays put', () {
      expect(
        zoomFromDrag(
          range: CameraZoomRange.none,
          distance: 400,
          threshold: threshold,
          span: span,
        ),
        1,
      );
    });

    test('an unusable distance does not zoom into nowhere', () {
      expect(at(double.nan), 1);
      expect(at(double.infinity), 1);
    });
  });

  group('controlEdgeFor', () {
    test('in portrait at the bottom — upside down too, where the hand is still below',
        () {
      expect(controlEdgeFor(DeviceOrientation.portraitUp), ControlEdge.bottom);
      expect(controlEdgeFor(DeviceOrientation.portraitDown), ControlEdge.bottom);
    });

    // Checked on the Galaxy A26 in both landscape orientations (2026-09-04).
    // Before, this only said "the two fall on different sides" — which was
    // honest as long as it was an assumption, and let the swap pass.
    test('in landscape to the side with the port — established on the device', () {
      expect(controlEdgeFor(DeviceOrientation.landscapeLeft), ControlEdge.right);
      expect(
          controlEdgeFor(DeviceOrientation.landscapeRight), ControlEdge.left);
    });
  });

  group('zoomLabel', () {
    test('German with a comma, English with a point', () {
      expect(zoomLabel(1.85, 'de'), '1,9×');
      expect(zoomLabel(1.85, 'en'), '1.9×');
    });

    test('always one decimal place', () {
      expect(zoomLabel(2, 'en'), '2.0×');
    });
  });
}
