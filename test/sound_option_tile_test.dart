// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The sound row aligns in ONE column (1.26.2).
//
// Gerry on the iPhone: "as in the settings" stood, cog included, further left
// than the rows below it. The cause was the width of the `leading`: an
// `IconButton` occupies a tap target of 48, a bare `Icon` only 24 — and
// `ListTile` puts the title behind whatever is there. So the offset was not a
// spacing bug but a consequence of two kinds of row being built differently.
//
// This test measures instead of describing: it compares the actual screen
// positions. Whoever makes the `leading` unequal again stands out here, not on
// a screenshot later.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/notifications/sound_option_tile.dart';

Widget _harness() => MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            SoundOptionTile(
              title: 'default',
              subtitle: 'Bubble',
              selected: true,
              icon: Icons.settings_outlined,
              onTap: () {},
            ),
            SoundOptionTile(
              title: 'mit-klang',
              selected: false,
              onPreview: () {},
              onTap: () {},
            ),
            SoundOptionTile(
              title: 'stumm',
              selected: false,
              icon: Icons.notifications_off,
              onTap: () {},
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('all the titles begin at the same edge', (tester) async {
    await tester.pumpWidget(_harness());

    final left = [
      for (final titel in ['default', 'mit-klang', 'stumm'])
        tester.getTopLeft(find.text(titel)).dx,
    ];

    expect(left[1], left[0],
        reason: 'the row without a play button must not slide to the left');
    expect(left[2], left[0], reason: 'dasselbe gilt fuer „Stumm"');
  });

  testWidgets('all the icons share one centre line', (tester) async {
    await tester.pumpWidget(_harness());

    double centreOf(IconData symbol) =>
        tester.getCenter(find.byIcon(symbol)).dx;

    final button = centreOf(Icons.play_circle_outline);
    expect(centreOf(Icons.settings_outlined), button,
        reason: 'the cog stood to the left of the button column');
    expect(centreOf(Icons.notifications_off), button);
  });

  testWidgets('the footprint is the tap target, not the icon',
      (tester) async {
    // Pins down the reasoning: the 48 come from the IconButton. Whoever
    // squeezes them to 24 makes the play button too small to hit.
    await tester.pumpWidget(_harness());

    final box = tester.getSize(
      find
          .ancestor(
            of: find.byIcon(Icons.play_circle_outline),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(box.width, kMinInteractiveDimension);
    expect(box.height, kMinInteractiveDimension);
  });
}
