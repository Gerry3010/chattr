// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Which platform draws and decodes video in hardware.
//
// This one line is the way it is for a DIFFERENT reason on every platform, and
// every reason was dearly bought:
//
//   * **Linux** needs software, otherwise the surface stays blank — the decoded
//     frames never reach the composition.
//   * **iOS** needs hardware, otherwise the app crashes (a libmpv assertion at
//     certain clip dimensions).
//   * **Android** needs hardware, otherwise it stutters: there the switch also
//     controls `hwdec`, and without it the phone decodes 4K on the CPU.
//
// Whoever unifies the matrix by accident gets, depending on the direction, a black
// picture, a crash or a stutter — three faults with nothing to do with each other.
// Hence it stands here as a guarantee.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/video_render_config.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS and Android draw in hardware', () {
    for (final p in [TargetPlatform.iOS, TargetPlatform.android]) {
      debugDefaultTargetPlatformOverride = p;
      expect(useSoftwareVideoRendering, isFalse, reason: '$p');
    }
  });

  test('Linux, macOS and Windows stay on software', () {
    for (final p in [
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      debugDefaultTargetPlatformOverride = p;
      expect(useSoftwareVideoRendering, isTrue, reason: '$p');
    }
  });
}
