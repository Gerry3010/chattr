// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The ⓘ icons of the privacy rows have to form a column.
//
// Reported by Gerry on 2026-08-13 with a screenshot: "send read receipts" fits
// in ONE line, its three neighbours wrap. With `Flexible` the short label took
// only its own width and dragged the ⓘ along behind it, while the wrapping ones
// pushed it to the edge — three icons in a line, one off to the side.
//
// A pure visual fault: no crash, no wrong output, catchable by no other test.
// Hence this one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/screens/settings/settings_screen.dart';

void main() {
  Widget host(List<({String key, String title})> rows) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: ListView(
              children: [
                for (final row in rows)
                  PrivacySwitchTile(
                    key: ValueKey('tile_${row.key}'),
                    tileKey: row.key,
                    icon: Icons.done_all,
                    title: row.title,
                    info: 'egal',
                    value: true,
                    onChanged: (_) {},
                  ),
              ],
            ),
          ),
        ),
      );

  testWidgets('a short and a wrapping label share the ⓘ column',
      (tester) async {
    await tester.pumpWidget(host([
      (key: 'kurz', title: 'Kurz'),
      (
        key: 'lang',
        title: 'Eine deutlich längere Beschriftung, die sicher umbricht'
      ),
    ]));

    final kurz = tester.getTopLeft(find.byKey(const ValueKey('kurz_info')));
    final lang = tester.getTopLeft(find.byKey(const ValueKey('lang_info')));

    expect(
      kurz.dx,
      lang.dx,
      reason: 'the ⓘ must not stick to the length of the text',
    );
  });

  testWidgets('that holds for the real four rows too', (tester) async {
    // The same mixture as in the screenshot: a single-line one at the top,
    // three wrapping ones after it.
    await tester.pumpWidget(host([
      (key: 'a', title: 'Lesebestätigungen senden'),
      (key: 'b', title: 'Medientyp in Benachrichtigungen'),
      (key: 'c', title: 'Reaktions-Emoji im Push zeigen'),
      (key: 'd', title: 'Kontaktvorschläge im Teilen-Menü'),
    ]));

    final xs = [
      for (final k in ['a', 'b', 'c', 'd'])
        tester.getTopLeft(find.byKey(ValueKey('${k}_info'))).dx,
    ];

    expect(xs.toSet(), hasLength(1), reason: 'alle vier in einer Flucht');
  });

  testWidgets('the label does not push the ⓘ out of the row',
      (tester) async {
    // Expanded must not lead to a very long text pushing the icon out — it has
    // to stay visible within the row.
    await tester.pumpWidget(host([
      (key: 'x', title: 'Wort ' * 40),
    ]));

    final icon = find.byKey(const ValueKey('x_info'));
    expect(icon, findsOneWidget);
    expect(tester.getTopLeft(icon).dx, lessThan(400));
    expect(tester.takeException(), isNull);
  });
}
