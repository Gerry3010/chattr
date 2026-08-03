// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/media/media_attachment.dart';

void main() {
  setUpAll(() => FlutterSecureStorage.setMockInitialValues({}));

  final svc =
      MessageEncryptionService(ChatKeyPairManager(const FlutterSecureStorage()));

  test('media bytes AES-GCM encrypt -> decrypt round-trips', () async {
    final data =
        Uint8List.fromList(List.generate(5000, (i) => (i * 7) % 256));
    final enc = await svc.encryptBytes(data);

    // Ciphertext blob differs from plaintext and is longer (nonce + tag).
    expect(enc.blob.length, greaterThan(data.length));
    expect(enc.key.length, 32);

    final dec = await svc.decryptBytes(enc.blob, enc.key);
    expect(dec, equals(data));
  });

  test('wrong key fails to decrypt media', () async {
    final data = Uint8List.fromList([1, 2, 3, 4, 5]);
    final enc = await svc.encryptBytes(data);
    final wrongKey = Uint8List(32);
    expect(() => svc.decryptBytes(enc.blob, wrongKey), throwsA(anything));
  });

  test('MediaAttachment encodes, parses, and distinguishes text', () {
    const att = MediaAttachment(
      mediaType: MediaType.image,
      name: 'photo.png',
      mime: 'image/png',
      size: 1234,
      path: 'chat/msg/photo.png.enc',
      keyB64: 'a2V5',
    );
    final encoded = att.encode();
    final parsed = MediaAttachment.tryParse(encoded);

    expect(parsed, isNotNull);
    expect(parsed!.path, att.path);
    expect(parsed.mediaType, MediaType.image);
    expect(parsed.keyB64, att.keyB64);

    // A plain text message must not be mistaken for media.
    expect(MediaAttachment.tryParse('hello world'), isNull);
    expect(MediaAttachment.tryParse(null), isNull);
  });

  MediaAttachment item(int i, {MediaType type = MediaType.image}) =>
      MediaAttachment(
        mediaType: type,
        name: 'file-$i.bin',
        mime: 'application/octet-stream',
        size: 100 + i,
        path: 'chat/msg/media-$i.enc',
        keyB64: 'a2V5$i',
      );

  test('MediaAlbum caption round-trips (#110)', () {
    final album = MediaAlbum(items: [item(0)], caption: 'a **sunset**');
    final parsed = MediaAlbum.tryParse(album.encode());
    expect(parsed, isNotNull);
    expect(parsed!.caption, 'a **sunset**');
    expect(parsed.items, hasLength(1));
  });

  test('caption additive: absent/empty stays byte-identical to old clients', () {
    final noCaption = MediaAlbum(items: [item(0)]);
    final emptyCaption = MediaAlbum(items: [item(0)], caption: '');
    // The `caption` key is omitted when null OR empty; single-item albums also
    // omit `items`, so both encode exactly like a pre-#109/#110 envelope.
    expect(noCaption.encode().contains('caption'), isFalse);
    expect(noCaption.encode().contains('items'), isFalse);
    expect(emptyCaption.encode(), noCaption.encode());
    expect(MediaAlbum.tryParse(noCaption.encode())!.caption, isNull);
  });

  test('MediaAlbum multi-item round-trips (#109)', () {
    final album = MediaAlbum(
      items: [item(0), item(1, type: MediaType.video), item(2)],
      caption: 'album',
    );
    final parsed = MediaAlbum.tryParse(album.encode());
    expect(parsed, isNotNull);
    expect(parsed!.items, hasLength(3));
    expect(parsed.caption, 'album');
    expect(parsed.items.map((e) => e.path),
        ['chat/msg/media-0.enc', 'chat/msg/media-1.enc', 'chat/msg/media-2.enc']);
    expect(parsed.items[1].mediaType, MediaType.video);
    expect(parsed.isAlbum, isTrue);
  });

  test('backward-compat: old client reads item[0] of a multi-item album', () {
    final album = MediaAlbum(items: [item(0), item(1)], caption: 'x');
    // A pre-#109 client parses only the top-level scalars — no `items` awareness.
    final legacy = MediaAttachment.fromJson(
      jsonDecode(album.encode()) as Map<String, dynamic>,
    );
    expect(legacy.path, 'chat/msg/media-0.enc'); // renders the first item
    expect(legacy.keyB64, 'a2V50');
    // And our own shim yields the same first item.
    expect(MediaAttachment.tryParse(album.encode())!.path, legacy.path);
  });

  test('MediaAlbum.previewLabel prefers caption, else name +N', () {
    expect(MediaAlbum(items: [item(0)], caption: 'hi').previewLabel,
        '\u{1F4CE} hi');
    expect(MediaAlbum(items: [item(0)]).previewLabel, '\u{1F4CE} file-0.bin');
    expect(MediaAlbum(items: [item(0), item(1), item(2)]).previewLabel,
        '\u{1F4CE} file-0.bin +2');
  });

  test('MediaType inferred from mime', () {
    expect(MediaType.fromMime('image/jpeg'), MediaType.image);
    expect(MediaType.fromMime('video/mp4'), MediaType.video);
    expect(MediaType.fromMime('audio/mpeg'), MediaType.audio);
    expect(MediaType.fromMime('application/pdf'), MediaType.file);
  });

  test('chunked descriptor round-trips (chunk_count/chunk_size) (#chunking)', () {
    const chunked = MediaAttachment(
      mediaType: MediaType.video,
      name: 'big.mp4',
      mime: 'video/mp4',
      size: 100 * 1024 * 1024,
      path: 'chat/msg/media-0', // PREFIX for a chunked item
      keyB64: 'a2V5',
      chunkCount: 17,
      chunkSize: 6 * 1024 * 1024,
    );
    final parsed = MediaAlbum.tryParse(MediaAlbum(items: [chunked]).encode())!.first;
    expect(parsed.isChunked, isTrue);
    expect(parsed.chunkCount, 17);
    expect(parsed.chunkSize, 6 * 1024 * 1024);
    // Chunk object paths derive from the prefix.
    expect(parsed.chunkPath(3), 'chat/msg/media-0-chunk-3.enc');
  });

  test('non-chunked descriptor has null chunk fields', () {
    final parsed = MediaAlbum.tryParse(item(0).encode())!.first;
    expect(parsed.isChunked, isFalse);
    expect(parsed.chunkCount, isNull);
    // Additive: a plain descriptor never emits the chunk keys.
    expect(item(0).encode().contains('chunk_count'), isFalse);
  });

  test('intrinsic dimensions round-trip + aspectRatio (#9)', () {
    const att = MediaAttachment(
      mediaType: MediaType.image,
      name: 'photo.jpg',
      mime: 'image/jpeg',
      size: 4321,
      path: 'chat/msg/photo.jpg.enc',
      keyB64: 'a2V5',
      width: 1600,
      height: 900,
    );
    final parsed = MediaAlbum.tryParse(att.encode())!.first;
    expect(parsed.width, 1600);
    expect(parsed.height, 900);
    expect(parsed.aspectRatio, closeTo(1600 / 900, 1e-9));
  });

  test('dimensions additive: absent stays byte-identical + null aspectRatio', () {
    // No width/height → the w/h keys are omitted, so the envelope is identical
    // to what a pre-#9 client produced, and aspectRatio is null (recipient
    // falls back to the neutral placeholder).
    final enc = item(0).encode();
    expect(enc.contains('"w"'), isFalse);
    expect(enc.contains('"h"'), isFalse);
    final parsed = MediaAlbum.tryParse(enc)!.first;
    expect(parsed.width, isNull);
    expect(parsed.height, isNull);
    expect(parsed.aspectRatio, isNull);
  });

  test('video cover-frame pointer round-trips (tp/tk) (#b)', () {
    const att = MediaAttachment(
      mediaType: MediaType.video,
      name: 'clip.mp4',
      mime: 'video/mp4',
      size: 999999,
      path: 'chat/msg/media-0.enc',
      keyB64: 'a2V5',
      width: 1080,
      height: 1920,
      thumbPath: 'chat/msg/media-0-thumb.enc',
      thumbKey: 'dGh1bWJrZXk=',
    );
    final parsed = MediaAlbum.tryParse(att.encode())!.first;
    expect(parsed.thumbPath, 'chat/msg/media-0-thumb.enc');
    expect(parsed.thumbKey, 'dGh1bWJrZXk=');
    // Portrait clip: dims still ride along so the poster is shaped before load.
    expect(parsed.aspectRatio, closeTo(1080 / 1920, 1e-9));
  });

  test('cover-frame additive: absent omits tp/tk + parses null', () {
    // A video without a generated thumbnail (non-native/older sender) omits the
    // keys entirely → byte-identical to a pre-#b envelope, null on parse.
    const att = MediaAttachment(
      mediaType: MediaType.video,
      name: 'clip.mp4',
      mime: 'video/mp4',
      size: 42,
      path: 'c/m/media-0.enc',
      keyB64: 'k',
    );
    final enc = att.encode();
    expect(enc.contains('"tp"'), isFalse);
    expect(enc.contains('"tk"'), isFalse);
    final parsed = MediaAlbum.tryParse(enc)!.first;
    expect(parsed.thumbPath, isNull);
    expect(parsed.thumbKey, isNull);
  });

  test('aspectRatio guards against zero/negative dimensions', () {
    const zero = MediaAttachment(
      mediaType: MediaType.image,
      name: 'x',
      mime: 'image/png',
      size: 1,
      path: 'c/m/x.enc',
      keyB64: 'k',
      width: 0,
      height: 100,
    );
    expect(zero.aspectRatio, isNull);
  });

  test('media envelope with marker but no path/key degrades to null (no crash)',
      () {
    // What an OLD client hits on a chunked descriptor it can't parse: the
    // TypeError from the non-null path/key cast is swallowed by tryParse's
    // catch → treated as a non-media body, never an exception up the UI.
    final body = jsonEncode({MediaAttachment.marker: 1, 'chunk_count': 3});
    expect(MediaAlbum.tryParse(body), isNull);
  });
}
