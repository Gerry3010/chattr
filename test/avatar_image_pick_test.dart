// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Avatars must be readable on every platform we ship to (1.22). Three HEIC
// files had reached production storage labelled `image/jpeg`, because the
// upload derived the content type from the FILE NAME and fell back to JPEG for
// anything it did not recognise. The format is now read from the bytes.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:chattr/features/media/avatar_image_pick.dart';
import 'package:chattr/features/media/image_metadata.dart';

/// A minimal ISO-BMFF header with the given brand — what an iPhone photo
/// starts with.
Uint8List _heifHeader(String brand) {
  final b = BytesBuilder();
  b.add([0, 0, 0, 24]); // box size
  b.add('ftyp'.codeUnits);
  b.add(brand.codeUnits);
  b.add(List<int>.filled(12, 0));
  return b.toBytes();
}

Uint8List _jpeg({int size = 32}) => Uint8List.fromList(
      img.encodeJpg(img.Image(width: size, height: size), quality: 90),
    );

Uint8List _png({int size = 32}) => Uint8List.fromList(
      img.encodePng(img.Image(width: size, height: size)),
    );

void main() {
  group('ImageMetadata.sniffMime', () {
    test('recognises the formats we store', () {
      expect(ImageMetadata.sniffMime(_jpeg()), 'image/jpeg');
      expect(ImageMetadata.sniffMime(_png()), 'image/png');
      expect(
        ImageMetadata.sniffMime(
          Uint8List.fromList('GIF89a'.codeUnits + List.filled(10, 0)),
        ),
        'image/gif',
      );
    });

    test('recognises HEIC/AVIF so we can explain the refusal', () {
      for (final brand in ['heic', 'heix', 'mif1', 'avif']) {
        expect(
          ImageMetadata.sniffMime(_heifHeader(brand)),
          'image/heic',
          reason: 'brand $brand',
        );
      }
    });

    test('an ISO-BMFF video is not mistaken for a picture', () {
      expect(ImageMetadata.sniffMime(_heifHeader('mp42')), isNull);
    });

    test('returns null for something that is not an image', () {
      expect(
        ImageMetadata.sniffMime(Uint8List.fromList('not an image'.codeUnits)),
        isNull,
      );
    });
  });

  group('prepareAvatarBytes', () {
    test('keeps a small JPEG untouched and labels it correctly', () async {
      final bytes = _jpeg();
      final picked = await prepareAvatarBytes(bytes);

      expect(picked.mime, 'image/jpeg');
      expect(picked.extension, 'jpg');
      expect(picked.bytes, same(bytes));
    });

    test('rejects HEIC with a reason the UI can act on', () async {
      await expectLater(
        prepareAvatarBytes(_heifHeader('heic')),
        throwsA(isA<UnsupportedAvatarFormat>()
            .having((e) => e.isHeif, 'isHeif', isTrue)),
      );
    });

    test('rejects anything unrecognisable', () async {
      await expectLater(
        prepareAvatarBytes(Uint8List.fromList(List.filled(64, 7))),
        throwsA(isA<UnsupportedAvatarFormat>()
            .having((e) => e.isHeif, 'isHeif', isFalse)),
      );
    });

    test('shrinks an oversized picture below the cap', () async {
      // Noise, so the encoder cannot compress it away and we really cross the
      // 512 KiB threshold.
      final big = img.Image(width: 2400, height: 1600);
      for (var y = 0; y < big.height; y++) {
        for (var x = 0; x < big.width; x++) {
          big.setPixelRgb(x, y, (x * 7) % 256, (y * 13) % 256, (x ^ y) % 256);
        }
      }
      final bytes = Uint8List.fromList(img.encodeJpg(big, quality: 95));
      expect(bytes.length, greaterThan(kAvatarMaxBytes));

      final picked = await prepareAvatarBytes(bytes);

      expect(picked.bytes.length, lessThan(bytes.length));
      final out = img.decodeImage(picked.bytes)!;
      expect(out.width, kAvatarMaxEdge);
      expect(out.height, lessThan(kAvatarMaxEdge));
    });

    test('a large PNG stays a PNG — transparency must survive', () async {
      // PNG is lossless, so a smooth gradient compresses to almost nothing;
      // the picture has to be genuinely noisy to exceed the cap.
      final big = img.Image(width: 1800, height: 1800, numChannels: 4);
      var seed = 12345;
      int next() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return (seed >> 16) & 0xff;
      }

      for (var y = 0; y < big.height; y++) {
        for (var x = 0; x < big.width; x++) {
          big.setPixelRgba(x, y, next(), next(), next(), 128);
        }
      }
      final bytes = Uint8List.fromList(img.encodePng(big));
      expect(bytes.length, greaterThan(kAvatarMaxBytes));

      final picked = await prepareAvatarBytes(bytes);

      expect(picked.mime, 'image/png');
      expect(picked.extension, 'png');
      expect(img.decodeImage(picked.bytes)!.numChannels, 4);
    });
  });
}
