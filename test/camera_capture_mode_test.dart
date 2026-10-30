// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/media/camera/camera_capture_mode.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Foto-Modus', () {
    test('a short tap takes a photo', () {
      final s = CameraShutter();
      expect(s.tap(), ShutterAction.takePhoto);
      expect(s.isRecording, isFalse);
    });

    test('holding records video, releasing ends it', () {
      final s = CameraShutter();
      expect(s.holdStart(), ShutterAction.startVideo);
      expect(s.isRecording, isTrue);
      expect(s.isHoldRecording, isTrue);
      expect(s.holdEnd(), ShutterAction.stopVideo);
      expect(s.isRecording, isFalse);
    });

    test('no photo in the middle of a running recording', () {
      final s = CameraShutter()..holdStart();
      expect(s.tap(), ShutterAction.none);
      expect(s.isRecording, isTrue);
    });

    test('releasing without a recording does nothing', () {
      final s = CameraShutter();
      expect(s.holdEnd(), ShutterAction.none);
    });
  });

  group('Video-Modus', () {
    CameraShutter video() => CameraShutter(mode: CaptureMode.video);

    test('tippen startet, zweites Tippen beendet', () {
      final s = video();
      expect(s.tap(), ShutterAction.startVideo);
      expect(s.isRecording, isTrue);
      expect(s.tap(), ShutterAction.stopVideo);
      expect(s.isRecording, isFalse);
    });

    test('the recording does NOT hang on the finger', () {
      final s = video();
      s.tap();
      // An accidental release must not end the running recording — the second
      // tap is there for that in video mode.
      expect(s.holdEnd(), ShutterAction.none);
      expect(s.isRecording, isTrue);
    });

    test('holding starts it as well, but never twice', () {
      final s = video();
      expect(s.holdStart(), ShutterAction.startVideo);
      expect(s.isHoldRecording, isFalse); // beendet wird per Tipp
      expect(s.holdStart(), ShutterAction.none);
      expect(s.tap(), ShutterAction.stopVideo);
    });
  });

  group('Betriebsart wechseln', () {
    test('works at rest', () {
      final s = CameraShutter();
      expect(s.setMode(CaptureMode.video), isTrue);
      expect(s.mode, CaptureMode.video);
    });

    test('does NOT work during a recording', () {
      final s = CameraShutter()..holdStart();
      expect(s.setMode(CaptureMode.video), isFalse);
      expect(s.mode, CaptureMode.photo);
    });
  });

  group('rotation of the preview', () {
    // Measured in the emulator (2026-09-04), not derived: the rig
    // `lib/main_camera_probe.dart` shows the preview and the captured file one
    // after another, and the correlation of the two image centres says how much
    // is missing. Out comes the same table the package subtracts, because it
    // expects somebody to put it back.
    test('upright needs no rotation', () {
      expect(previewQuarterTurns(DeviceOrientation.portraitUp), 0);
      expect(previewIsLandscape(DeviceOrientation.portraitUp), isFalse);
    });

    test('the two landscape orientations are two quarter turns apart', () {
      final links = previewQuarterTurns(DeviceOrientation.landscapeLeft);
      final right = previewQuarterTurns(DeviceOrientation.landscapeRight);
      expect((links - right) % 4, 2);
      expect(previewIsLandscape(DeviceOrientation.landscapeLeft), isTrue);
      expect(previewIsLandscape(DeviceOrientation.landscapeRight), isTrue);
    });

    test('upside down it is two', () {
      expect(previewQuarterTurns(DeviceOrientation.portraitDown), 2);
      expect(previewIsLandscape(DeviceOrientation.portraitDown), isFalse);
    });

    test('every orientation stays within 0..3', () {
      for (final o in DeviceOrientation.values) {
        expect(previewQuarterTurns(o), inInclusiveRange(0, 3), reason: '$o');
      }
    });
  });
}
