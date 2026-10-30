// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The setting "how are media sent" (1.27).
//
// The most important case is the least conspicuous: **the default is full
// quality.** A messenger that downscales unasked takes a decision away that
// nobody asked it to take — and one notices only months later, when the photo
// can no longer be enlarged. No refactoring may reverse this direction by
// accident.
//
// The second case is the race at cold start: `state` holds the default at once,
// the stored value only arrives afterwards. Whoever reads the synchronous
// `state` in the send path sends at full size the first time after startup,
// although "smaller" is configured. [resolvedValue] exists for that.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/settings/media_quality_controller.dart';

MediaQualityController _controller() =>
    MediaQualityController(const FlutterSecureStorage());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('without a setting, full quality applies', () async {
    final c = _controller();
    expect(c.state, MediaQuality.original, reason: 'sofort, ohne Warten');
    expect(await c.resolvedValue(), MediaQuality.original);
  });

  test('the choice survives a restart', () async {
    await _controller().setQuality(MediaQuality.smaller);

    final neu = _controller();
    expect(await neu.resolvedValue(), MediaQuality.smaller);
  });

  test('resolvedValue awaits the load — state alone would lie',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'media_quality_v1': 'smaller',
    });
    final c = _controller();

    // Exactly the moment the send path would grab wrongly: the stored value is
    // not there yet, `state` shows the default.
    expect(c.state, MediaQuality.original);
    expect(await c.resolvedValue(), MediaQuality.smaller,
        reason: 'the send path has to get the REAL value');
  });

  test('an unknown stored value falls back on full quality',
      () async {
    // Broken storage must not suddenly downscale — the silent direction here is
    // the lossless one.
    FlutterSecureStorage.setMockInitialValues({
      'media_quality_v1': 'winzig',
    });
    expect(await _controller().resolvedValue(), MediaQuality.original);
  });

  test('setSmaller switches in both directions', () async {
    final c = _controller();
    await c.setSmaller(true);
    expect(c.state, MediaQuality.smaller);
    await c.setSmaller(false);
    expect(c.state, MediaQuality.original);
    expect(await _controller().resolvedValue(), MediaQuality.original,
        reason: 'switching back has to be stored too');
  });
}
