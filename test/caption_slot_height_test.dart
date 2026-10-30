// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The bar below the preview must not change height when toggling to "shot"
// (1.27).
//
// Gerry on the device: "that has to be exactly the same height, otherwise the
// picture wobbles about." And so it was — the hint was built differently from
// the input field and thereby 40 instead of 48 tall (Material gives a non-dense
// TextField the height of a tap target; the padding alone comes to only 40).
//
// After that the hint was allowed to wrap so it would not be cut off mid-word —
// and that is where the next danger lies: `minHeight` is a LOWER bound. If the
// type grows, the bar grows with it again, and the jump is back. So the third
// test measures with a deliberately far too long text.
//
// **What this test CANNOT do:** check whether a particular sentence wraps on a
// real phone. Widget tests render with a fallback font in which every character
// is as wide as it is tall — text widths here are therefore made up (the first
// attempt came to grief on exactly that). Whether the hint looks good is
// decided by the eye on the device; whether the bar wobbles is decided by this
// test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/widgets/caption_slot.dart';

Widget _harness({
  required bool shot,
  required TextEditingController c,
  String hint = 'x',
  String shotHint = 'x',
}) {
  return MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 360,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: CaptionSlot(
                  shot: shot,
                  controller: c,
                  focusNode: FocusNode(),
                  hintText: hint,
                  shotHintText: shotHint,
                ),
              ),
              const SizedBox(width: 8),
              FloatingActionButton(
                onPressed: () {},
                mini: true,
                child: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<double> _height(
  WidgetTester tester, {
  required bool shot,
  String text = '',
  String hint = 'x',
  String shotHint = 'x',
}) async {
  final c = TextEditingController(text: text);
  addTearDown(c.dispose);
  await tester
      .pumpWidget(_harness(shot: shot, c: c, hint: hint, shotHint: shotHint));
  await tester.pumpAndSettle();
  return tester.getSize(find.byType(CaptionSlot)).height;
}

void main() {
  testWidgets('the input field and the shot hint are exactly the same height',
      (tester) async {
    final field = await _height(tester, shot: false);
    final hint = await _height(tester, shot: true);

    expect(field, CaptionSlot.minHeight);
    expect(hint, field,
        reason: 'jeder Unterschied laesst die Vorschau darueber springen');
  });

  testWidgets('that holds when something is already typed in the field too', (tester) async {
    // Typed on a single line the height must not grow yet — otherwise the
    // comparison above would only be right by chance (empty field against
    // hint).
    final leer = await _height(tester, shot: false);
    final getippt = await _height(tester, shot: false, text: 'Hallo');

    expect(getippt, leer);
  });

  testWidgets('a hint that wraps does NOT make the bar grow',
      (tester) async {
    // The actual guard. Whoever raises the hint's font size makes the bar grow
    // again — and notices only on the device, because in the code both branches
    // look plausible.
    final kurz = await _height(tester, shot: true);
    final lang = await _height(
      tester,
      shot: true,
      shotHint: 'Ein absichtlich viel zu langer Hinweistext, der in keiner '
          'Sprache der Welt in eine Zeile passen wuerde und deshalb umbrechen '
          'muss, ohne die Leiste in die Hoehe zu ziehen',
    );

    expect(kurz, CaptionSlot.minHeight);
    expect(lang, kurz, reason: 'umbrechen ja, wachsen nein');
    expect(tester.takeException(), isNull);
  });
}
