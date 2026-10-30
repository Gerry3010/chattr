// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The voluntary downscaling before sending (1.27). Two guarantees carry the
// whole thing:
//
//   1. **Downscaling only happens when it gains something.** An image that is
//      already small must not run through a re-encoding pass — otherwise "send
//      smaller" would in truth mean "send worse", and nobody notices, because the
//      result looks plausible.
//   2. **The orientation survives.** `copyResize` does not evaluate the EXIF
//      orientation, and the re-encoded image carries no EXIF any more. Whoever
//      works in the wrong order sends tipped-over photos — exactly the fault that
//      was once in the field.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:chattr/features/media/image_metadata.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/media_downscale.dart';
import 'package:chattr/features/settings/media_quality_controller.dart';

/// A JPEG with recognisable content (not a solid colour — otherwise it
/// compresses to a few bytes and the size comparisons become meaningless).
Uint8List _jpeg({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x * y) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

OutgoingMedia _item(Uint8List bytes, {String mime = 'image/jpeg'}) =>
    OutgoingMedia.bytes(bytes, fileName: 'foto.jpg', mime: mime);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Kein Geraet, kein nativer Kodierer — Video-Verkleinern ist in diesen
    // Tests grundsaetzlich aus. Die Bildseite laeuft in reinem Dart.
    videoDownscaleSupported = () => false;
  });

  test('"Original" leaves everything untouched', () async {
    final zoomedIn = _item(_jpeg(width: 3000, height: 2000));
    final out = await downscaleMedia(zoomedIn, MediaQuality.original);
    expect(identical(out, zoomedIn), isTrue,
        reason: 'without being asked, nothing may be touched');
  });

  test('a large picture is brought to the long edge', () async {
    final zoomedIn = _item(_jpeg(width: 3000, height: 2000));
    final out = await downscaleMedia(zoomedIn, MediaQuality.smaller);

    expect(out.size, lessThan(zoomedIn.size));
    final decoded = img.decodeImage(out.bytes!)!;
    expect(decoded.width, kSmallerImageMaxEdge);
    expect(decoded.height, 1067, reason: 'the aspect ratio stays');
  });

  test('a picture taken in portrait bounds its HEIGHT', () async {
    final hoch = _item(_jpeg(width: 2000, height: 3000));
    final out = await downscaleMedia(hoch, MediaQuality.smaller);

    final decoded = img.decodeImage(out.bytes!)!;
    expect(decoded.height, kSmallerImageMaxEdge);
    expect(decoded.width, lessThan(kSmallerImageMaxEdge));
  });

  test('an already small picture comes back UNCHANGED', () async {
    // The heart of it: no re-encoding "on suspicion". Identity, not merely
    // equal size — the very same object is meant to travel on.
    final small = _item(_jpeg(width: 800, height: 600));
    final out = await downscaleMedia(small, MediaQuality.smaller);
    expect(identical(out, small), isTrue);
  });

  test('exactly on the limit nothing is touched', () async {
    final limit =
        _item(_jpeg(width: kSmallerImageMaxEdge, height: 900));
    final out = await downscaleMedia(limit, MediaQuality.smaller);
    expect(identical(out, limit), isTrue);
  });

  test('an animated GIF stays as it is', () async {
    // A re-encode would return only the first frame — an animation would
    // wordlessly become a still.
    final gif = OutgoingMedia.bytes(
      Uint8List.fromList(img.encodeGif(img.Image(width: 3000, height: 2000))),
      fileName: 'tanz.gif',
      mime: 'image/gif',
    );
    final out = await downscaleMedia(gif, MediaQuality.smaller);
    expect(identical(out, gif), isTrue);
  });

  test('PNG stays PNG — transparency survives', () async {
    final image = img.Image(width: 2400, height: 1800, numChannels: 4);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgba(x, y, (x * 3) % 256, (y * 5) % 256, 90, 0);
      }
    }
    final png = OutgoingMedia.bytes(
      Uint8List.fromList(img.encodePng(image)),
      fileName: 'freigestellt.png',
      mime: 'image/png',
    );
    final out = await downscaleMedia(png, MediaQuality.smaller);

    expect(out.mime, 'image/png');
    expect(out.fileName, 'freigestellt.png');
    final decoded = img.decodeImage(out.bytes!)!;
    expect(decoded.numChannels, 4, reason: 'the alpha channel must not fall away');
  });

  test('a JPEG is renamed to .jpg when it was not before',
      () async {
    final webpAehnlich = OutgoingMedia.bytes(
      _jpeg(width: 3000, height: 2000),
      fileName: 'IMG_0042.heic',
      mime: 'image/heic',
    );
    final out = await downscaleMedia(webpAehnlich, MediaQuality.smaller);
    expect(out.mime, 'image/jpeg');
    expect(out.fileName, 'IMG_0042.jpg',
        reason: 'name and content must not drift apart');
  });

  test('audio and documents pass through unchanged', () async {
    for (final mime in ['audio/mpeg', 'application/pdf']) {
      final f = OutgoingMedia.bytes(
        Uint8List.fromList(List<int>.filled(4096, 7)),
        fileName: 'datei',
        mime: mime,
      );
      expect(identical(await downscaleMedia(f, MediaQuality.smaller), f), isTrue,
          reason: '$mime hat nichts zu verkleinern');
    }
  });

  test('without a native encoder a video stays untouched', () async {
    final video = OutgoingMedia.file('/tmp/clip.mp4',
        size: 40 * 1024 * 1024, fileName: 'clip.mp4', mime: 'video/mp4');
    final out = await downscaleMedia(video, MediaQuality.smaller);
    expect(identical(out, video), isTrue);
  });

  test('unreadable bytes do not hold up the send', () async {
    // Lieber unveraendert senden als gar nicht senden.
    final kaputt = _item(Uint8List.fromList(List<int>.filled(9000, 0x42)));
    final out = await downscaleMedia(kaputt, MediaQuality.smaller);
    expect(identical(out, kaputt), isTrue);
  });

  test('a rotated photo comes out upright, not on its side',
      () async {
    // THE guarantee of this round. An iPhone stores the pixels in landscape and
    // puts the note "rotate by 90 degrees" beside them. `copyResize` does not
    // know that note, and the re-encoded image no longer carries it either —
    // whoever downscales first has nothing left to bake in, and the photo lies
    // on its side at every recipient. Exactly this fault was once in the field.
    final landscape = img.Image(width: 3000, height: 2000);
    for (var y = 0; y < landscape.height; y++) {
      for (var x = 0; x < landscape.width; x++) {
        landscape.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x * y) % 256);
      }
    }
    landscape.exif.imageIfd.orientation = 6; // „beim Anzeigen aufrichten"
    final photo = _item(Uint8List.fromList(img.encodeJpg(landscape, quality: 95)));
    expect(ImageMetadata.jpegOrientation(photo.bytes!), 6,
        reason: 'test precondition: the rotation note has to be in there');

    final out = await downscaleMedia(photo, MediaQuality.smaller);
    final decoded = img.decodeImage(out.bytes!)!;

    // Uprighted means: 3000x2000 landscape becomes 2000x3000 portrait, and THAT
    // is then bounded to the long edge.
    expect(decoded.height, greaterThan(decoded.width),
        reason: 'the rotation has to sit in the pixels');
    expect(decoded.height, kSmallerImageMaxEdge);
    expect(ImageMetadata.jpegOrientation(out.bytes!), anyOf(isNull, 1),
        reason: 'no second rotation note — otherwise it is rotated twice');
  });

  group('downscaleAll', () {
    test('keeps the order of the album', () async {
      final items = [
        _item(_jpeg(width: 3000, height: 2000)),
        _item(_jpeg(width: 400, height: 300)),
        _item(_jpeg(width: 2600, height: 2600)),
      ];
      final out = await downscaleAll(items, MediaQuality.smaller);

      expect(out.length, 3);
      expect(img.decodeImage(out[0].bytes!)!.width, kSmallerImageMaxEdge);
      expect(identical(out[1], items[1]), isTrue, reason: 'the small one stays');
      expect(img.decodeImage(out[2].bytes!)!.width, kSmallerImageMaxEdge);
    });

    test('"Original" passes the list through unchanged', () async {
      final items = [_item(_jpeg(width: 3000, height: 2000))];
      expect(identical(await downscaleAll(items, MediaQuality.original), items),
          isTrue);
    });
  });
}
