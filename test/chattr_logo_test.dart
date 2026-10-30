// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/theme/chattr_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _mit(Brightness luminance) => MaterialApp(
      theme: ThemeData(brightness: luminance),
      home: const Scaffold(body: Center(child: ChattrLogo(size: 64))),
    );

void main() {
  testWidgets('draws the SVG, not a Material icon', (tester) async {
    await tester.pumpWidget(_mit(Brightness.dark));
    expect(find.byType(SvgPicture), findsWidgets);
    expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
  });

  testWidgets('the ring casts its shadow onto the bubble, on every ground',
      (tester) async {
    // Logo, the ring tinted + blurred as its shadow, the ring again on top —
    // flutter_svg skips the icon's SVG filter, so Flutter draws it.
    for (final b in Brightness.values) {
      await tester.pumpWidget(_mit(b));
      final rings = tester
          .widgetList<SvgPicture>(find.byType(SvgPicture))
          .where((p) =>
              (p.bytesLoader as SvgAssetLoader).assetName ==
              'assets/images/logo_ring.svg');
      expect(rings, hasLength(2), reason: '$b');
    }
  });

  testWidgets('on a light ground the bubble gets a soft edge',
      (tester) async {
    // The bubble is almost white — without an edge only the pair of eyes would
    // stay visible on a light theme. The shadow is a second, blurred copy,
    // which is why there are two SvgPictures there.
    await tester.pumpWidget(_mit(Brightness.light));
    expect(find.byType(SvgPicture), findsNWidgets(4));
    expect(find.byType(ImageFiltered), findsNWidgets(2));
  });

  testWidgets('on a dark ground it stays without an edge', (tester) async {
    await tester.pumpWidget(_mit(Brightness.dark));
    // Only the ring's own shadow is blurred here, no edge around the bubble.
    expect(find.byType(SvgPicture), findsNWidgets(3));
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('the size is passed through', (tester) async {
    await tester.pumpWidget(_mit(Brightness.dark));
    for (final image
        in tester.widgetList<SvgPicture>(find.byType(SvgPicture))) {
      expect(image.width, 64);
      expect(image.height, 64);
    }
  });
}
