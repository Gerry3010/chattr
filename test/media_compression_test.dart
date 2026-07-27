// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/media_compression.dart';

void main() {
  setUpAll(() => FlutterSecureStorage.setMockInitialValues({}));

  Uint8List compressibleText([int repeats = 2000]) => Uint8List.fromList(
        utf8.encode('void main() { print("hello chattr"); }\n' * repeats),
      );

  test('compressible text round-trips through gzip', () async {
    final data = compressibleText();
    final compressed =
        await MediaCompression.maybeCompress(data, 'text/x-dart');
    expect(compressed, isNotNull);
    expect(compressed!.length, lessThan(data.length ~/ 2));

    final restored = await MediaCompression.decompress(
      compressed,
      maxBytes: 500 * 1024 * 1024,
    );
    expect(restored, equals(data));
  });

  test('full pipeline: compress -> encrypt -> decrypt -> decompress', () async {
    final svc = MessageEncryptionService(
      ChatKeyPairManager(const FlutterSecureStorage()),
    );
    final data = compressibleText();
    final compressed =
        await MediaCompression.maybeCompress(data, 'application/octet-stream');
    expect(compressed, isNotNull);

    final enc = await svc.encryptBytes(compressed!);
    final dec = await svc.decryptBytes(enc.blob, enc.key);
    final restored =
        await MediaCompression.decompress(dec, maxBytes: 500 * 1024 * 1024);
    expect(restored, equals(data));
  });

  test('incompressible random bytes are sent raw', () async {
    final rng = Random(42);
    final data =
        Uint8List.fromList(List.generate(50000, (_) => rng.nextInt(256)));
    expect(
      await MediaCompression.maybeCompress(data, 'application/octet-stream'),
      isNull,
    );
  });

  test('empty and tiny files are sent raw', () async {
    expect(
      await MediaCompression.maybeCompress(Uint8List(0), 'text/plain'),
      isNull,
    );
    // gzip header/trailer overhead outweighs savings on a few bytes.
    final tiny = Uint8List.fromList(utf8.encode('hi'));
    expect(await MediaCompression.maybeCompress(tiny, 'text/plain'), isNull);
  });

  test('skipsMime matrix', () {
    expect(MediaCompression.skipsMime('image/jpeg'), isTrue);
    expect(MediaCompression.skipsMime('video/mp4'), isTrue);
    expect(MediaCompression.skipsMime('audio/mpeg'), isTrue);
    expect(MediaCompression.skipsMime('application/zip'), isTrue);
    expect(MediaCompression.skipsMime('application/pdf'), isTrue);
    expect(
      MediaCompression.skipsMime(
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      ),
      isTrue,
    );
    expect(MediaCompression.skipsMime('text/plain'), isFalse);
    expect(MediaCompression.skipsMime('application/octet-stream'), isFalse);
    expect(MediaCompression.skipsMime('application/json'), isFalse);
  });

  test('bomb guard: forged ISIZE and undersized maxBytes both throw', () async {
    final data = compressibleText();
    final compressed =
        (await MediaCompression.maybeCompress(data, 'text/plain'))!;

    // Patch the ISIZE trailer (last 4 bytes, little-endian) to claim ~4 GiB.
    final forged = Uint8List.fromList(compressed);
    ByteData.sublistView(forged, forged.length - 4)
        .setUint32(0, 0xFFFFFFFF, Endian.little);
    expect(
      () => MediaCompression.decompress(forged, maxBytes: 500 * 1024 * 1024),
      throwsFormatException,
    );

    // Honest gzip, but the cap is below the real output size.
    expect(
      () => MediaCompression.decompress(compressed, maxBytes: 100),
      throwsFormatException,
    );

    // Garbage that is too short to be gzip at all.
    expect(
      () => MediaCompression.decompress(Uint8List(5), maxBytes: 1000),
      throwsFormatException,
    );
  });

  test('descriptor: compression key omitted when null (backward compat)', () {
    const raw = MediaAttachment(
      mediaType: MediaType.file,
      name: 'main.dart',
      mime: 'text/x-dart',
      size: 1234,
      path: 'chat/msg/main.dart.enc',
      keyB64: 'a2V5',
    );
    // Exact key set must match the pre-compression wire format (single-item
    // album envelope = legacy single-media shape, no `items`/`caption`).
    expect(
      MediaAlbum(items: [raw]).toJson().keys.toSet(),
      {'_chattr_media', 'media_type', 'name', 'mime', 'size', 'path', 'key'},
    );

    const gz = MediaAttachment(
      mediaType: MediaType.file,
      name: 'main.dart',
      mime: 'text/x-dart',
      size: 1234,
      path: 'chat/msg/main.dart.enc',
      keyB64: 'a2V5',
      compression: MediaCompression.gzip,
    );
    final parsed = MediaAttachment.tryParse(gz.encode());
    expect(parsed!.compression, MediaCompression.gzip);
    // copyWith (localPath caching) must not drop the flag.
    expect(parsed.copyWith(localPath: '/tmp/x').compression,
        MediaCompression.gzip);

    // Legacy JSON without the key parses to null.
    final legacy = MediaAttachment.tryParse(raw.encode());
    expect(legacy!.compression, isNull);
  });
}
