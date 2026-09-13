// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The text blocks on a photo shot (1.27.1, several of them and free in height
// since 1.29).
//
// They are rendered INTO THE PIXELS and do not travel as a field — that is the
// whole point: a shot deliberately has no caption, because a caption would
// outlive the picture and stay in the history. The sentence burns with the
// picture because it IS the picture.
//
// What these tests pin down: that something is actually painted (the pixels
// there get darker), that the dimensions stay the same, that SEVERAL blocks
// land at their respective heights — and that every doubtful case passes the
// original through UNCHANGED: a few lines of text are not worth costing a send.

import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/shot_caption_burn.dart';
import 'package:chattr/features/media/shot_text_blocks.dart';

/// An evenly light picture — a dark bar stands out on it.
Uint8List _photo({int w = 400, int h = 300}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(230, 230, 230));
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

OutgoingMedia _item({String mime = 'image/jpeg', String name = 'IMG_1.jpg'}) =>
    OutgoingMedia.bytes(_photo(), fileName: name, mime: mime);

/// Ein einzelner Abschnitt, standardmaessig mittig — so sass die Leiste bis
/// 1.28 fest, die alten Zusicherungen gelten also unveraendert weiter.
Future<OutgoingMedia> _brenne(OutgoingMedia item, String text,
        {double y = 0.5}) =>
    burnShotTextBlocks(item, [ShotTextBlock(text: text, y: y)]);

/// The darkest row between [von] and [bis].
double _darkest(img.Image image, int von, int bis) =>
    [for (var y = von; y < bis; y++) _luminance(image, y)].reduce(min);

/// Mittlere Helligkeit einer waagrechten Zeile.
double _luminance(img.Image image, int y) {
  var sum = 0.0;
  for (var x = 0; x < image.width; x++) {
    final p = image.getPixel(x, y);
    sum += (p.r + p.g + p.b) / 3;
  }
  return sum / image.width;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the sentence lands in the picture — and only where the bar sits', () async {
    final before = _item();
    final after = await _brenne(before, 'Hallo vom Balkon');

    expect(identical(after, before), isFalse, reason: 'es wurde gemalt');
    final image = img.decodeImage(after.bytes!)!;
    expect(image.width, 400);
    expect(image.height, 300, reason: 'the bar must not stretch the picture');

    final top = _luminance(image, 5);
    final band = _darkest(image, image.height ~/ 3, 2 * image.height ~/ 3);

    // The bar sits centred and is markedly darker than the rest.
    expect(band, lessThan(top - 80),
        reason: 'without the bar the middle would be as light as the edge');
    expect(top, greaterThan(200), reason: 'oben unberuehrt');
    expect(_luminance(image, image.height - 5), greaterThan(200),
        reason: 'unten unberuehrt');

    // And in the middle of the bar there is something LIGHT — that is the white
    // type. Without this check the test only examines the bar and would wave
    // through a bar with no text at all.
    expect(_luminance(image, image.height ~/ 2), greaterThan(band + 40),
        reason: 'weisse Glyphen heben genau die mittlere Zeile an');
  });

  test('the sentence stands CENTRED, not against the left edge', () async {
    // `TextAlign.center` alone is not enough: it aligns only within the width
    // the painter claims after line breaking — with a short line, therefore,
    // within the line. The sentence thereby stuck to the left while the preview
    // showed it centred.
    final after = await _brenne(_item(), 'Hallo');
    final image = img.decodeImage(after.bytes!)!;

    // Centre of mass of the LIGHT pixels in the bar — those are the glyphs.
    final von = image.height ~/ 3, bis = 2 * image.height ~/ 3;
    var sum = 0.0, gewicht = 0.0;
    for (var y = von; y < bis; y++) {
      for (var x = 0; x < image.width; x++) {
        final p = image.getPixel(x, y);
        final hell = (p.r + p.g + p.b) / 3;
        if (hell > 200) {
          sum += x * hell;
          gewicht += hell;
        }
      }
    }
    expect(gewicht, greaterThan(0), reason: 'ueberhaupt Schrift gefunden');
    expect(sum / gewicht, closeTo(image.width / 2, image.width * 0.06),
        reason: 'the text block sits in the middle of the bar');
  });

  test('three blocks land at three different heights', () async {
    final after = await burnShotTextBlocks(_item(), const [
      ShotTextBlock(text: 'oben', y: 0.12),
      ShotTextBlock(text: 'mitte', y: 0.5),
      ShotTextBlock(text: 'unten', y: 0.88),
    ]);
    final image = img.decodeImage(after.bytes!)!;
    expect(image.height, 300, reason: 'the bars do not stretch the picture');

    // Three separate dark bands — light picture has to remain between them,
    // otherwise they would have run together.
    for (final anteil in const [0.12, 0.5, 0.88]) {
      final y = (image.height * anteil).round();
      expect(_luminance(image, y), lessThan(150), reason: 'Leiste bei $anteil');
    }
    for (final anteil in const [0.30, 0.70]) {
      expect(_luminance(image, (image.height * anteil).round()),
          greaterThan(200),
          reason: 'picture remains between the bars');
    }
  });

  test('an empty block is not painted', () async {
    // Nothing written means nothing meant — an empty band would be a black
    // stripe for no reason.
    final after = await burnShotTextBlocks(_item(), const [
      ShotTextBlock(text: '  ', y: 0.2),
      ShotTextBlock(text: 'da', y: 0.8),
    ]);
    final image = img.decodeImage(after.bytes!)!;
    expect(_luminance(image, (image.height * 0.2).round()), greaterThan(200));
    expect(_luminance(image, (image.height * 0.8).round()), lessThan(150));
  });

  test('a block at the edge stays WHOLLY inside the picture', () async {
    // Hanging half out of the picture it would be half gone at the recipient —
    // and the sender saw all of it.
    final after = await burnShotTextBlocks(
        _item(), const [ShotTextBlock(text: 'ganz unten', y: 1.0)]);
    final image = img.decodeImage(after.bytes!)!;
    expect(_luminance(image, image.height - 2), lessThan(150),
        reason: 'die Leiste liegt am unteren Rand an');
    expect(_luminance(image, 5), greaterThan(200), reason: 'oben unberuehrt');
  });

  test('without blocks the photo stays unchanged', () async {
    final before = _item();
    expect(identical(await burnShotTextBlocks(before, const []), before), isTrue);
  });

  test('empty text leaves the photo alone', () async {
    final before = _item();
    expect(identical(await _brenne(before, ''), before), isTrue);
    expect(identical(await _brenne(before, '   '), before), isTrue,
        reason: 'only spaces is not a sentence');
  });

  test('a video is not captioned', () async {
    // Es zu beschriften hiesse, es neu zu kodieren: Minuten Rechenzeit fuer
    // eine Zeile Text.
    final video = OutgoingMedia.bytes(
      Uint8List.fromList([0, 1, 2, 3]),
      fileName: 'clip.mp4',
      mime: 'video/mp4',
    );
    expect(identical(await _brenne(video, 'Hallo'), video), isTrue);
  });

  test('unreadable bytes do not hold up the send', () async {
    final kaputt = OutgoingMedia.bytes(
      Uint8List.fromList(List<int>.filled(64, 9)),
      fileName: 'IMG_2.jpg',
      mime: 'image/jpeg',
    );
    expect(identical(await _brenne(kaputt, 'Hallo'), kaputt), isTrue,
        reason: 'better to send without the line than not at all');
  });

  test('the result is called .jpg and is a JPEG', () async {
    final after = await _brenne(_item(name: 'DSC_9.HEIC'), 'Text');
    expect(after.fileName, 'DSC_9.jpg');
    expect(after.mime, 'image/jpeg');
  });

  test('PNG stays PNG — transparency survives', () async {
    final png = OutgoingMedia.bytes(
      Uint8List.fromList(img.encodePng(img.Image(width: 200, height: 150))),
      fileName: 'shot.png',
      mime: 'image/png',
    );
    final after = await _brenne(png, 'Text');
    expect(after.mime, 'image/png');
    expect(after.fileName, 'shot.png');
    expect(img.decodePng(after.bytes!), isNotNull);
  });

  test('a panorama does not get a wall pasted on it', () async {
    // 1/30 of the WIDTH would be a seventh of the HEIGHT at 4:1 — the bar would
    // cover a quarter of the picture. The second limit (1/14 of the height)
    // catches that.
    final breit = img.Image(width: 1200, height: 300);
    img.fill(breit, color: img.ColorRgb8(230, 230, 230));
    final after = await _brenne(
      OutgoingMedia.bytes(Uint8List.fromList(img.encodeJpg(breit, quality: 95)),
          fileName: 'pano.jpg', mime: 'image/jpeg'),
      'Ein Satz',
    );
    final image = img.decodeImage(after.bytes!)!;

    // How many rows are noticeably darkened? That is the bar height.
    var dark = 0;
    for (var y = 0; y < image.height; y++) {
      if (_luminance(image, y) < 200) dark++;
    }
    expect(dark, greaterThan(0), reason: 'gemalt wurde trotzdem');
    expect(dark, lessThan(image.height ~/ 4),
        reason: 'the bar must not cover a quarter of the panorama');
  });

  test('same width, same type — regardless of the resolution', () {
    // The sentence should always look the same size to the viewer. Because a
    // phone displays photos width-limited, that means: the same fraction of the
    // width.
    expect(ShotCaptionStyle.fontSizeFor(3000, 4000),
        ShotCaptionStyle.fontSizeFor(3000, 2250),
        reason: 'portrait and landscape of the same width carry the same type');
    expect(ShotCaptionStyle.fontSizeFor(600, 800) * 5,
        closeTo(ShotCaptionStyle.fontSizeFor(3000, 4000), 0.001),
        reason: 'fuenffache Aufloesung, fuenffache Schrift — gleicher Anblick');
    expect(ShotCaptionStyle.fontSizeFor(1200, 300),
        lessThan(1200 * ShotCaptionStyle.fontSizeRatio),
        reason: 'only the panorama is reined in by the height');
  });

  test('a very long text does not blow the picture apart', () async {
    final lang = List.filled(80, 'Wortsalat').join(' ');
    final after = await _brenne(_item(), lang);
    final image = img.decodeImage(after.bytes!)!;

    expect(image.height, 300);
    // Four lines is the limit; picture has to remain above and below.
    expect(_luminance(image, 5), greaterThan(200));
    expect(_luminance(image, image.height - 5), greaterThan(200));
  });
}
