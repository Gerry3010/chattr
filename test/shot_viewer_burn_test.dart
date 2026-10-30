// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// When is a shot spent? (1.27, revised 2026-08-28)
//
// At first: on closing the viewer, via its return value. Gerry on the Galaxy:
// "on android you can still get around it with the back button — nav pop — then
// it is still shown as unopened." The back button ends the page without a
// return value — the shot counted as never opened and could be viewed any
// number of times.
//
// One can seal that one route (the redirect in the `PopScope` does exactly
// that), but it is not the only one: the swipe gesture, the route's edge swipe,
// and — not to be caught by any redirect — killing the app while the shot is
// open. So the burn now hangs on the **opening**. These tests pin down exactly
// that: that it falls before anybody closes, and that a failure does NOT cost
// it.
//
// EasyLocalization is not loaded in the test: `.tr()` returns the key.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/widgets/media_message_view.dart'
    show decryptedMediaProvider;
import 'package:chattr/features/media/widgets/shot_viewer.dart';

/// A real 1x1 PNG — `Image.memory` wants to see something decodable.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9'
  'awAAAABJRU5ErkJggg==',
);

MediaAttachment _att() => MediaAttachment(
      mediaType: MediaType.image,
      name: 'IMG_0042.jpg',
      mime: 'image/png',
      size: _png.length,
      path: 'chat-1/msg-1/media-0.enc',
      keyB64: base64Encode(List<int>.filled(32, 7)),
    );

/// Builds the viewer on a route of its own — only that way can the system back
/// be triggered at all.
Future<int Function()> _open(
  WidgetTester tester, {
  Object? errors,
}) async {
  var burned = 0;
  final att = _att();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        decryptedMediaProvider.overrideWith((ref, a) async {
          if (errors != null) throw errors;
          return _png;
        }),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute<bool>(
                  builder: (_) => ShotScreen(
                    attachment: att,
                    kind: MediaType.image,
                    onViewed: () => burned++,
                  ),
                ),
              ),
              child: const Text('los'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('los'));
  await tester.pumpAndSettle();
  return () => burned;
}

void main() {
  testWidgets('spent as soon as the shot is visible — not only on closing'
      'Schliessen', (tester) async {
    final burned = await _open(tester);

    expect(find.byType(ShotScreen), findsOneWidget);
    expect(burned(), 1,
        reason: 'the viewer is still open and the shot is already gone — as intended'
            'genau das ueberlebt jeden Weg hinaus');
  });

  testWidgets('the back button does not bring it back', (tester) async {
    final burned = await _open(tester);

    // That is the route it broke on at the Galaxy.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(ShotScreen), findsNothing, reason: 'closed is closed');
    expect(burned(), 1, reason: 'once — not zero times, not twice');
  });

  testWidgets('a failure does NOT cost the shot', (tester) async {
    // No network, no blob, wrong key — which error it was exactly is irrelevant
    // here and deliberately not pinned down: there was nothing to see, so
    // nothing is spent either. Otherwise a patch of no reception eats the shot.
    final burned = await _open(tester, errors: Exception('kein Netz'));

    expect(find.text('shots.load_failed'), findsOneWidget);
    expect(burned(), 0);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(burned(), 0, reason: 'closing must not cost it either');
  });

  testWidgets('the close button does not burn a second time', (tester) async {
    final burned = await _open(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.byType(ShotScreen), findsNothing);
    expect(burned(), 1);
  });
}
