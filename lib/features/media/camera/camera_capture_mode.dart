// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// What the shutter means — **no camera, no widgets, no plugin**.
///
/// **Why this is a file of its own.** The camera itself cannot be opened in a
/// test: `availableCameras()` needs a device, and a widget test would get a
/// stand-in there at best. But the actual question — "what happens on a tap,
/// what on a hold, what on the second tap" — has nothing to do with the camera.
/// So it lives here, as a pure state machine, and is testable that way.
library;

import 'package:flutter/services.dart' show DeviceOrientation;

/// The shutter's two modes.
enum CaptureMode {
  /// Kurz tippen = Foto, halten = Video, Loslassen beendet.
  photo,

  /// Tippen startet, das **zweite** Tippen beendet.
  video,
}

/// What the shutter has to trigger right now.
enum ShutterAction {
  /// Nothing — the gesture had no meaning in this state.
  none,

  /// Ein Foto aufnehmen.
  takePhoto,

  /// Videoaufnahme beginnen.
  startVideo,

  /// Videoaufnahme beenden.
  stopVideo,
}

/// The shutter as a state machine.
///
/// The UI only reports **what the finger did** (`tap`, `holdStart`, `holdEnd`)
/// and gets back what to do. It decides nothing itself — otherwise the two
/// modes drift apart the moment somebody adds a third gesture.
class CameraShutter {
  CameraShutter({this.mode = CaptureMode.photo});

  CaptureMode mode;

  /// Is a video recording running right now?
  bool get isRecording => _recording;
  bool _recording = false;

  /// The recording is running because the finger rests on the shutter — then
  /// letting go ends it. In video mode this is `false`: there the recording
  /// holds by itself and waits for the second tap.
  bool get isHoldRecording => _holdRecording;
  bool _holdRecording = false;

  /// Switch the mode. **Not during a running recording** — a switch mid-video
  /// would mean nobody knows what the next tap means any more.
  bool setMode(CaptureMode next) {
    if (_recording) return false;
    mode = next;
    return true;
  }

  /// Kurzes Tippen.
  ShutterAction tap() {
    switch (mode) {
      case CaptureMode.photo:
        // During a recording nothing normally arrives here (a long press fires
        // no `onTap`). The case is caught anyway: a photo in the middle of a
        // running video recording would simply be an error on most devices.
        if (_recording) return ShutterAction.none;
        return ShutterAction.takePhoto;
      case CaptureMode.video:
        if (_recording) {
          _recording = false;
          _holdRecording = false;
          return ShutterAction.stopVideo;
        }
        _recording = true;
        _holdRecording = false;
        return ShutterAction.startVideo;
    }
  }

  /// Der Finger bleibt liegen.
  ShutterAction holdStart() {
    // **Do not start twice.** In video mode a recording may already be running,
    // waiting for its second tap.
    if (_recording) return ShutterAction.none;
    _recording = true;
    // Only in photo mode does the recording hang on the finger. In video mode a
    // hold should start it as well (otherwise a perfectly natural gesture would
    // do nothing at all) — but there it is still ended by a tap.
    _holdRecording = mode == CaptureMode.photo;
    return ShutterAction.startVideo;
  }

  /// Der Finger geht hoch.
  ShutterAction holdEnd() {
    if (!_recording || !_holdRecording) return ShutterAction.none;
    _recording = false;
    _holdRecording = false;
    return ShutterAction.stopVideo;
  }

  /// After an error: back to rest without losing the mode. (By then the
  /// recording has already failed on the device — the machine must not believe
  /// one is still running.)
  void reset() {
    _recording = false;
    _holdRecording = false;
  }
}

/// How far the preview has to be rotated for it to stand upright.
///
/// **Measured in the emulator, not derived** (Android 36, virtual camera,
/// 2026-09-04). The rig [main_camera_probe] shows the preview and the captured
/// file one after the other; the file is demonstrably the right way up, so the
/// difference between the two is exactly the missing rotation. It was not worked
/// out by eye — that was wrong twice — but from the correlation of the two image
/// centres across all four rotations:
///
/// | display rotation | missing |
/// |---|---|
/// | 0 (portrait)  | +0 |
/// | 1 (landscape) | +1 |
/// | 3 (landscape) | +3 |
///
/// The two landscape orientations differ by two quarter turns — that is how one
/// knows the measurement holds and the eye did not.
///
/// Out comes the same table the package itself uses
/// (`getPreAppliedQuarterTurnsRotationFromDeviceOrientation`), and that is no
/// coincidence: `buildPreview()` subtracts this rotation because it expects
/// `CameraPreview` to put it right back. We put it back here — with
/// `deviceOrientation` and explicitly **not** with `recordingOrientation`, which
/// the package draws it from during a recording: that value does not match the
/// orientation on the Galaxy and tipped the picture over on a long press.
int previewQuarterTurns(DeviceOrientation orientation) => switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeRight => 1,
      DeviceOrientation.portraitDown => 2,
      DeviceOrientation.landscapeLeft => 3,
    };

/// Is the device in landscape? Decides which axis the preview's aspect ratio is
/// computed around.
bool previewIsLandscape(DeviceOrientation orientation) =>
    orientation == DeviceOrientation.landscapeLeft ||
    orientation == DeviceOrientation.landscapeRight;
