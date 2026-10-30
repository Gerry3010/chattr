// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Emoji in running text: size in the bubble, the gap correction for fonts
// that leave room after the drawn emoji, and that the composer stays in one
// piece where there is nothing to correct.

import 'package:chattr/features/messages/inline_emoji.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android: im Text 1,125-fach, keine Abstandskorrektur', () {
    final s = bubbleEmojiStyle(14, platform: TargetPlatform.android);
    expect(s.fontSize, closeTo(15.75, 1e-9));
    expect(s.letterSpacing, isNull);
    expect(plainEmojiStyle(16, platform: TargetPlatform.android), isNull);
  });

  test('eine Lücke nach dem Emoji wird mit negativem Abstand geschlossen', () {
    const t = InlineEmojiTuning(
      bubbleFactor: 1.2,
      bubbleTrailingGap: 0.1,
      plainTrailingGap: 0.2,
    );
    final bubble = t.bubbleStyle(14);
    expect(bubble.fontSize, closeTo(16.8, 1e-9));
    expect(bubble.letterSpacing, closeTo(-1.68, 1e-9));
    expect(t.plainStyle(16)!.letterSpacing, closeTo(-3.2, 1e-9));
    expect(t.plainStyle(16)!.fontSize, isNull,
        reason: 'im Eingabefeld bleibt die Größe die des Texts');
  });

  test('iPhone: so groß wie am Galaxy, Lücke nach dem Emoji geschlossen', () {
    // Gemessen 2026-10-24: Apple zeichnet 🙂 bei 1,25-fach 16,3 px hoch, Noto
    // bei 1,125-fach 16,4 px. Überschuss danach 3,0 px in der Blase (17,5 px),
    // 3,0 bis 3,3 px im Eingabefeld und in der Bildunterschrift.
    final bubble = bubbleEmojiStyle(14, platform: TargetPlatform.iOS);
    expect(bubble.fontSize, closeTo(17.5, 1e-9));
    expect(bubble.letterSpacing, closeTo(-2.8, 1e-9));
    expect(plainEmojiStyle(16, platform: TargetPlatform.iOS)!.letterSpacing,
        closeTo(-3.2, 1e-9));
    expect(plainEmojiStyle(15, platform: TargetPlatform.iOS)!.letterSpacing,
        closeTo(-3.0, 1e-9));
  });

  testWidgets('Eingabefeld ohne Korrektur: der Text bleibt ein Stück',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final controller = EmojiTextEditingController(text: 'mit „🙂“ reagiert');
    addTearDown(controller.dispose);
    late TextSpan span;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        span = controller.buildTextSpan(
          context: context,
          style: const TextStyle(fontSize: 16),
          withComposing: false,
        );
        return const SizedBox();
      }),
    ));
    debugDefaultTargetPlatformOverride = null;
    expect(span.text, 'mit „🙂“ reagiert');
    expect(span.children, isNull);
  });
}
