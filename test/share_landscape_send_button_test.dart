// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// In landscape the keyboard takes nearly the whole screen, and what is left is
// measured from the BOTTOM — so below the field the send button was simply not
// there any more, on a screen whose only purpose is sending (reported 03.09.
// and 05.09.2026). The button therefore moves to the top when the device is
// turned, and this test holds that position: it is measured in pixels, not
// asserted by the widget's name, because a layout can be "correct" in the tree
// and still be off-screen.
//
// EasyLocalization is not initialised here, so `.tr()` returns the key itself.
// Matching happens on the ValueKey, not on visible text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/share_target/share_text_edit_sheet.dart';

const _feld = ValueKey('share_text_edit_field');
const _knopf = ValueKey('share_send_button');

/// Opens the sheet on a screen of [size], with [tastatur] logical pixels of
/// keyboard eating into it from the bottom.
///
/// The keyboard is the whole point — without it a landscape screen has room to
/// spare and the test would pass on any layout at all.
Future<void> _oeffne(
  WidgetTester tester,
  Size size, {
  double tastatur = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewInsets = FakeViewPadding(bottom: tastatur);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showShareTextEditSheet(
                context,
                initialText: 'https://example.com',
              ),
              child: const Text('auf'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('auf'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('quer: der Senden-Knopf steht ÜBER dem Feld', (tester) async {
    await _oeffne(tester, const Size(900, 400), tastatur: 250);

    final knopf = tester.getTopLeft(find.byKey(_knopf)).dy;
    final feld = tester.getTopLeft(find.byKey(_feld)).dy;
    expect(knopf, lessThan(feld),
        reason: 'unten deckt ihn die Tastatur zu, und dann laesst sich das '
            'Geteilte gar nicht mehr abschicken');

    // Der eigentliche Nachweis: Er steht nicht nur weiter oben, er steht auch
    // oberhalb der Tastaturkante — „im Baum vorhanden" ist nicht dasselbe wie
    // „zu sehen".
    final unterkante = tester.getBottomLeft(find.byKey(_knopf)).dy;
    expect(unterkante, lessThanOrEqualTo(400 - 250));
  });

  testWidgets('quer: es gibt ihn genau einmal', (tester) async {
    // Zwei Knoepfe waeren der naheliegende Pfusch — einer oben, einer unten,
    // "einer wird schon sichtbar sein".
    await _oeffne(tester, const Size(900, 400), tastatur: 250);
    expect(find.byKey(_knopf), findsOneWidget);
  });

  testWidgets('hoch: er bleibt unter dem Feld, wo er hingehoert',
      (tester) async {
    await _oeffne(tester, const Size(400, 900), tastatur: 300);

    final knopf = tester.getTopLeft(find.byKey(_knopf)).dy;
    final feld = tester.getTopLeft(find.byKey(_feld)).dy;
    expect(knopf, greaterThan(feld));
    expect(find.byKey(_knopf), findsOneWidget);
  });

  testWidgets('quer: nichts laeuft ueber', (tester) async {
    // Der Streifen neben der Tastatur ist knapp; ohne scrollbaren Inhalt gaebe
    // es hier die gelb-schwarzen Balken statt einer Oberflaeche.
    await _oeffne(tester, const Size(900, 300), tastatur: 200);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quer: ein leeres Feld laesst den Knopf aus', (tester) async {
    await _oeffne(tester, const Size(900, 400), tastatur: 250);
    await tester.enterText(find.byKey(_feld), '   ');
    await tester.pump();

    final knopf = tester.widget<FilledButton>(find.byKey(_knopf));
    expect(knopf.onPressed, isNull,
        reason: 'oben ist er sichtbarer — ein Leerzeichen zu verschicken darf '
            'er deshalb erst recht nicht');
  });
}
