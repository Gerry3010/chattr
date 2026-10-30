// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The text blocks on a photo shot (1.29).
//
// Until 1.28 there was exactly ONE bar, fixed in the middle of the picture. Now
// there are several, and each carries its own position — as a **fraction** of
// the image height. Everything hangs on that: the preview measures in logical
// pixels, the burning happens in image pixels, and the same number exists in
// both worlds only as a ratio. A pixel value would be right in the preview and
// wrong in the sent picture — the fault from 1.27.2, only worse, because it
// would then hit every block individually.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/shot_text_blocks.dart';

void main() {
  group('what actually gets burned', () {
    test('leere Abschnitte fallen weg', () {
      final uebrig = visibleTextBlocks(const [
        ShotTextBlock(text: 'da', y: 0.2),
        ShotTextBlock(text: '   ', y: 0.5),
        ShotTextBlock(text: '', y: 0.8),
      ]);
      expect(uebrig.map((b) => b.text), ['da']);
    });

    test('the text is trimmed, the order stays', () {
      final uebrig = visibleTextBlocks(const [
        ShotTextBlock(text: '  erst ', y: 0.1),
        ShotTextBlock(text: 'dann', y: 0.9),
      ]);
      expect(uebrig.map((b) => b.text), ['erst', 'dann']);
      expect(uebrig.map((b) => b.y), [0.1, 0.9]);
    });

    test('the position stays between 0 and 1', () {
      final uebrig = visibleTextBlocks(const [
        ShotTextBlock(text: 'zu hoch', y: -0.4),
        ShotTextBlock(text: 'zu tief', y: 1.7),
      ]);
      expect(uebrig.map((b) => b.y), [0.0, 1.0]);
    });

    test('there is no more than the upper bound', () {
      // Without a limit a photo becomes a wall.
      final viele = [
        for (var i = 0; i < kMaxShotTextBlocks + 3; i++)
          ShotTextBlock(text: 'Nr $i', y: i / 10)
      ];
      expect(visibleTextBlocks(viele), hasLength(kMaxShotTextBlocks));
    });

    test('nothing stays nothing', () {
      expect(visibleTextBlocks(const []), isEmpty);
      expect(visibleTextBlocks(const [ShotTextBlock(text: ' ', y: 0.5)]),
          isEmpty);
    });
  });

  group('where the bar sits', () {
    // 400 hoch, Band 40 hoch → Mitte bei y=0.5 heisst oben = 200 - 20.
    test('the position means the CENTRE of the bar, not its top edge', () {
      expect(shotTextBlockTop(y: 0.5, bandHeight: 40, imageHeight: 400), 180);
    });

    test('at the top edge it does not slide out', () {
      expect(shotTextBlockTop(y: 0.0, bandHeight: 40, imageHeight: 400), 0);
      expect(shotTextBlockTop(y: 0.02, bandHeight: 40, imageHeight: 400), 0,
          reason: 'just above it is still created, not truncated');
    });

    test('am unteren Rand ebenso', () {
      expect(shotTextBlockTop(y: 1.0, bandHeight: 40, imageHeight: 400), 360);
    });

    test('a bar taller than the picture sits at the top', () {
      // No negative value: the text should start at the top, not above the
      // picture.
      expect(shotTextBlockTop(y: 0.5, bandHeight: 500, imageHeight: 400), 0);
    });

    test('the same position, twice the resolution — twice the offset', () {
      // That is the reason for the fraction: preview and burned picture compute
      // the same formula, only each at its own scale.
      final small = shotTextBlockTop(y: 0.25, bandHeight: 20, imageHeight: 200);
      final zoomedIn = shotTextBlockTop(y: 0.25, bandHeight: 40, imageHeight: 400);
      expect(zoomedIn, small * 2);
    });
  });
}
