// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The capture tile in the attachment sheet (1.29).
//
// Its history in two steps: first a SECOND sheet asked "photo or video?". Then
// (1.28) the decision sat on the tile as tap/hold — not because that would be the
// right place, but because capture belonged to the phone's camera app and the tile
// was the only spot we could reach. Since there is a camera of our own, the
// gesture lives on the shutter, where one looks for it (see
// camera_capture_mode_test.dart).
//
// What these tests pin down is therefore the opposite of before:
//
//   1. The tile is called "Shot" and does exactly ONE thing.
//   2. NO tile has a second gesture any more. An `onLongPress` quietly built back
//      in would be a relapse into the state 1.29 dissolved.
//   3. On the desktop it does not exist at all.
//
// EasyLocalization is not loaded in the test: `.tr()` returns the key.

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/widgets/attach_menu.dart';

Future<void> _openSheet(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (c) => TextButton(
          onPressed: () => showAttachSheet(
            context: c,
            onSend: ({
              required items,
              caption,
              onProgress,
              isCancelled,
              quality,
              asShot = false,
            }) async {},
          ),
          child: const Text('anhaengen'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('anhaengen'));
  await tester.pumpAndSettle();
}

/// The `InkWell` of the tile carrying [label].
InkWell _tile(WidgetTester tester, String label) => tester.widget<InkWell>(
      find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first,
    );

// The platform override MUST be reset inside the test body itself: the harness
// checks at the end of the body whether a debug variable has been left hanging
// — a `tearDown` comes too late for that.
void main() {
  testWidgets('the capture tile is called "Shot" and has exactly one gesture',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _openSheet(tester);

    final shot = _tile(tester, 'shots.badge');
    expect(shot.onTap, isNotNull);
    expect(shot.onLongPress, isNull,
        reason: 'tap/hold is now decided by the shutter in the camera');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the old camera tile and its hold hint are gone',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _openSheet(tester);

    expect(find.text('media.camera'), findsNothing);
    expect(find.text('media.camera_hold_hint'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('NO tile has a long press', (tester) async {
    // A gesture without effect is worse than none: the user learns that a long
    // press means nothing — and overlooks it where it counts.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _openSheet(tester);

    for (final label in const [
      'shots.badge',
      'media.gallery',
      'media.video',
      'media.audio',
      'media.document',
      'media.paste',
    ]) {
      expect(_tile(tester, label).onLongPress, isNull, reason: label);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('on the desktop the tile does not exist at all', (tester) async {
    // There is no camera there — neither our own nor the system's.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await _openSheet(tester);

    expect(find.text('shots.badge'), findsNothing);
    expect(find.text('media.gallery'), findsOneWidget,
        reason: 'the rest stays');
    debugDefaultTargetPlatformOverride = null;
  });
}
