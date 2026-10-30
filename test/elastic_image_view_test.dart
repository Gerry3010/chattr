// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-55/56: the profile picture could be dragged out of sight and never came
// back; the photo viewer stopped hard at the edge and could not go below
// "fits". One viewer now: a little slack while the fingers are down, then it
// springs back.

import 'dart:typed_data';

import 'package:chattr/features/media/widgets/elastic_image_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Offset _t(Matrix4 m) => Offset(m.getTranslation().x, m.getTranslation().y);

Matrix4 _m(double scale, Offset t) => Matrix4.identity()
  ..translateByDouble(t.dx, t.dy, 0, 1)
  ..scaleByDouble(scale, scale, 1, 1);

void main() {
  // A wide photo on a tall phone: fits as 400×200, centred vertically.
  final bounds = ElasticBounds(
    viewport: const Size(400, 800),
    imageSize: const Size(2000, 1000),
  );

  group('ElasticBounds', () {
    test('Maße: passt, füllt, Obergrenze', () {
      expect(bounds.fitted, const Size(400, 200));
      expect(bounds.origin, const Offset(0, 300));
      expect(bounds.coverScale, 4);
      expect(bounds.maxScale, 12);
    });

    test('beim Ziehen etwas Spielraum, aber nicht ins Nichts', () {
      final m = bounds.duringGesture(_m(1, const Offset(500, -900)));
      expect(_t(m), const Offset(60, -60), reason: '15 % der kurzen Seite');
    });

    test('losgelassen: zurück in die Mitte', () {
      final m = bounds.atRest(_m(1, const Offset(60, -60)));
      expect(m.getMaxScaleOnAxis(), 1);
      expect(_t(m), Offset.zero);
    });

    test('unter „passt“ verkleinert: federt auf 1 zurück', () {
      final m = bounds.atRest(_m(0.75, const Offset(50, 100)));
      expect(m.getMaxScaleOnAxis(), 1);
      expect(_t(m), Offset.zero);
    });

    test('gezoomt: Kante bleibt am Rand, die zu kurze Achse mittig', () {
      final m = bounds.atRest(_m(2, const Offset(100, 0)));
      expect(m.getMaxScaleOnAxis(), 2);
      // 800 px breit auf 400: links darf kein Rand bleiben.
      expect(_t(m).dx, 0);
      // 400 px hoch auf 800: mittig.
      expect(_t(m).dy, -400);
      expect(_t(bounds.atRest(_m(2, const Offset(-900, 0)))).dx, -400);
    });

    test('Doppeltippen zoomt um den Finger und wieder zurück', () {
      final zoomed = bounds.toggle(Matrix4.identity(), const Offset(200, 400));
      expect(zoomed.getMaxScaleOnAxis(), 4);
      expect(_t(zoomed), const Offset(-600, -1200));
      expect(bounds.toggle(zoomed, const Offset(10, 10)), Matrix4.identity());
    });
  });

  testWidgets('Doppeltippen meldet Zoom, zweites Doppeltippen zurück',
      (tester) async {
    final bytes = Uint8List.fromList(
        img.encodePng(img.Image(width: 200, height: 100)));
    final image = MemoryImage(bytes);
    final states = <bool>[];

    await tester.pumpWidget(MaterialApp(
      home: ElasticImageView(image: image, onZoomChanged: states.add),
    ));
    await tester.runAsync(() async {
      await precacheImage(image, tester.element(find.byType(ElasticImageView)));
    });
    await tester.pumpAndSettle();

    Future<void> doubleTap() async {
      final at = tester.getCenter(find.byType(ElasticImageView));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      await tester.pumpAndSettle();
    }

    await doubleTap();
    expect(states, [true]);
    await doubleTap();
    expect(states, [true, false]);
  });
}
