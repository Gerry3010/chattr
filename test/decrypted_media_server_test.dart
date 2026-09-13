// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Playing WHILE loading (1.27).
//
// The player no longer opens a finished file but a local address; the blocks
// arrive as soon as they are loaded AND verified. What can break here is not
// "it does not play" but "it plays, but the bytes are wrong" — a video with a
// jump at a block boundary looks like a broken clip, not like an error. So this
// test checks byte-exactly against the original content, across boundaries too
// and for range requests (the player makes those when seeking).

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/media/decrypted_media_server.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/media_repository.dart';

const _chatId = 'aaaaaaaa-1111-2222-3333-444444444444';
const _messageId = 'bbbbbbbb-1111-2222-3333-444444444444';
const _chunkSize = 1024; // klein gehalten, damit Grenzen oft vorkommen

class _FakeRepo extends MediaRepository {
  _FakeRepo(this.blobs)
      : super(SupabaseClient('http://127.0.0.1:1', 'anon-key-for-tests'));

  final Map<String, Uint8List> blobs;
  final geholt = <String>[];

  @override
  Future<Uint8List> downloadEncrypted(String path) async {
    geholt.add(path);
    final b = blobs[path];
    if (b == null) throw StateError('kein Blob fuer $path');
    return b;
  }

  @override
  Future<void> markDownloaded(String chatId, String messageId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    FlutterSecureStorage.setMockInitialValues({});
    // The test environment OTHERWISE intercepts every HTTP call and answers
    // with 400 — but here we are talking to our own loopback server, and we
    // really do want to ask it.
    HttpOverrides.global = null;
  });

  final svc =
      MessageEncryptionService(ChatKeyPairManager(const FlutterSecureStorage()));

  /// A chunked medium with recognisable content (every byte depends on its
  /// position — a shift therefore stands out immediately).
  Future<(MediaAttachment, _FakeRepo, Uint8List)> chunked({
    int total = _chunkSize * 3 + 517,
  }) async {
    final key = svc.newMediaKey();
    final plain = Uint8List.fromList(
        List<int>.generate(total, (i) => (i * 31 + i ~/ 7) % 251));
    final count = (total / _chunkSize).ceil();
    final att = MediaAttachment(
      mediaType: MediaType.video,
      name: 'clip.mp4',
      mime: 'video/mp4',
      size: total,
      path: '$_chatId/$_messageId/media-0',
      keyB64: base64Encode(key),
      chunkCount: count,
      chunkSize: _chunkSize,
    );
    final blobs = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final from = i * _chunkSize;
      final to = min(from + _chunkSize, total);
      blobs[att.chunkPath(i)] = await svc.encryptChunk(
        Uint8List.sublistView(plain, from, to),
        key,
        aad: MessageEncryptionService.mediaChunkAad(_messageId, 0, i, count),
      );
    }
    return (att, _FakeRepo(blobs), plain);
  }

  Future<(int status, List<int> body, Map<String, String> headers)> get(
    String uri, {
    String? range,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(uri));
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close();
      final body = <int>[];
      await for (final part in res) {
        body.addAll(part);
      }
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      return (res.statusCode, body, headers);
    } finally {
      client.close(force: true);
    }
  }

  test('delivers the whole content — byte-exact across every block boundary',
      () async {
    final (att, repo, plain) = await chunked();
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    final (status, body, headers) = await get(server.uri);
    expect(status, 200);
    expect(body, equals(plain),
        reason: 'a shifted byte would be a broken video, not an error');
    expect(headers[HttpHeaders.contentLengthHeader], '${plain.length}');
    expect(headers[HttpHeaders.acceptRangesHeader], 'bytes',
        reason: 'without it the player does not even try to seek');
    expect(headers[HttpHeaders.contentTypeHeader], contains('video/mp4'));
  });

  test('a range request straddling two blocks is correct', () async {
    // Exactly the case the player makes when seeking — and the case in which an
    // arithmetic error in the block number hides.
    final (att, repo, plain) = await chunked();
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    const start = _chunkSize - 100;
    const end = _chunkSize + 200;
    final (status, body, headers) = await get(server.uri, range: 'bytes=$start-$end');

    expect(status, 206);
    expect(headers[HttpHeaders.contentRangeHeader],
        'bytes $start-$end/${plain.length}');
    expect(body, equals(plain.sublist(start, end + 1)));
  });

  test('an open range runs to the end', () async {
    final (att, repo, plain) = await chunked();
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    const start = _chunkSize * 2 + 33;
    final (status, body, _) = await get(server.uri, range: 'bytes=$start-');
    expect(status, 206);
    expect(body, equals(plain.sublist(start)));
  });

  test('the last bytes (bytes=-N) are correct', () async {
    final (att, repo, plain) = await chunked();
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    final (status, body, _) = await get(server.uri, range: 'bytes=-64');
    expect(status, 206);
    expect(body, equals(plain.sublist(plain.length - 64)));
  });

  test('a range past the end is refused, not invented', () async {
    final (att, repo, plain) = await chunked();
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    final (status, _, headers) =
        await get(server.uri, range: 'bytes=${plain.length + 10}-');
    expect(status, 416);
    expect(headers[HttpHeaders.contentRangeHeader], 'bytes */${plain.length}');
  });

  test('a wrong path gets nothing', () async {
    // On Android EVERY app can reach a loopback port. The unguessable path is
    // therefore not trimming but the access control.
    final (att, repo, _) = await chunked();
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    final base = Uri.parse(server.uri);
    final (status, body, _) =
        await get('http://127.0.0.1:${base.port}/etwas-anderes');
    expect(status, 404);
    expect(body, isEmpty);
  });

  test('it prefetches — it does not wait block by block', () async {
    final (att, repo, _) = await chunked(total: _chunkSize * 8);
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    // Request only the first block: if prefetching happens, the next ones are
    // on their way regardless.
    await get(server.uri, range: 'bytes=0-${_chunkSize - 1}');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(repo.geholt.length, greaterThan(1),
        reason: 'without the prefetch the player waits afresh at every block boundary');
  });

  test('a single object is verified COMPLETELY first, then delivered',
      () async {
    // No streaming: a single object is ONE ciphertext with ONE checksum at the
    // end. Handing anything out earlier would mean displaying unverified data.
    final plain =
        Uint8List.fromList(List<int>.generate(5000, (i) => (i * 7) % 251));
    final enc = await svc.encryptBytes(plain);
    final att = MediaAttachment(
      mediaType: MediaType.video,
      name: 'klein.mp4',
      mime: 'video/mp4',
      size: plain.length,
      path: '$_chatId/$_messageId/media-0.enc',
      keyB64: base64Encode(enc.key),
    );
    final repo = _FakeRepo({att.path: enc.blob});
    final server = await DecryptedMediaServer.start(
        attachment: att, repo: repo, svc: svc);
    addTearDown(server.dispose);

    final (status, body, _) = await get(server.uri);
    expect(status, 200);
    expect(body, equals(plain));
  });
}
