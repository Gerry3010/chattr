// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The block prefetch when loading large media (1.27).
//
// Before, fetching was strictly sequential: request, wait, decrypt, next. At 6
// MiB per block that is around 67 full network round trips in a row for a 400
// MB video — and during every wait the device does nothing.
//
// When speeding this up, the ORDER is what can break: the blocks are written
// sequentially into a file, and a swapped pair does not show up as an error but
// as a broken video. So this test checks both — that loading happens
// concurrently AND that things nevertheless come out in order.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/features/media/decrypted_media_stream.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/media_repository.dart';

const _chatId = 'aaaaaaaa-1111-2222-3333-444444444444';
const _messageId = 'bbbbbbbb-1111-2222-3333-444444444444';

/// A store that answers requests only on cue — so one can measure how many are
/// open at the same time.
class _GatedRepo extends MediaRepository {
  _GatedRepo(this.blobs)
      : super(SupabaseClient('http://127.0.0.1:1', 'anon-key-for-tests'));

  final Map<String, Uint8List> blobs;

  /// The order in which requests were made.
  final requested = <String>[];

  /// Open requests still waiting to be released.
  final _gates = <String, Completer<Uint8List>>{};

  int get openRequests => _gates.length;

  /// Die noch offenen Anforderungen, in Anforderungsreihenfolge.
  List<String> get openPaths => _gates.keys.toList();

  @override
  Future<Uint8List> downloadEncrypted(String path) {
    requested.add(path);
    final c = Completer<Uint8List>();
    _gates[path] = c;
    return c.future;
  }

  void release(String path) {
    final c = _gates.remove(path);
    if (c == null) throw StateError('$path wurde nie angefordert');
    final blob = blobs[path];
    if (blob == null) {
      c.completeError(StateError('kein Blob fuer $path'));
    } else {
      c.complete(blob);
    }
  }

  void fail(String path, Object error) {
    _gates.remove(path)!.completeError(error);
  }

  @override
  Future<void> markDownloaded(String chatId, String messageId) async {
    // There is no server in the test; the signal is best effort anyway.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => FlutterSecureStorage.setMockInitialValues({}));

  final svc =
      MessageEncryptionService(ChatKeyPairManager(const FlutterSecureStorage()));

  /// Baut [count] verschluesselte Bloecke samt passendem Anhang.
  Future<(MediaAttachment, _GatedRepo, List<Uint8List>)> fixture(
      int count) async {
    final key = svc.newMediaKey();
    const prefix = '$_chatId/$_messageId/media-0';
    final att = MediaAttachment(
      mediaType: MediaType.video,
      name: 'clip.mp4',
      mime: 'video/mp4',
      size: count * 64,
      path: prefix,
      keyB64: base64Encode(key),
      chunkCount: count,
      chunkSize: 64,
    );
    final plain = <Uint8List>[];
    final blobs = <String, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final data = Uint8List.fromList(List<int>.filled(64, i));
      plain.add(data);
      blobs[att.chunkPath(i)] = await svc.encryptChunk(
        data,
        key,
        aad: MessageEncryptionService.mediaChunkAad(_messageId, 0, i, count),
      );
    }
    return (att, _GatedRepo(blobs), plain);
  }

  test('several blocks are in flight at once', () async {
    final (att, repo, _) = await fixture(8);
    final sub =
        decryptedMediaChunks(att, repo, svc).listen(null, onError: (_) {});

    await Future<void>.delayed(Duration.zero);
    expect(repo.openRequests, mediaChunkLookahead,
        reason: 'the window has to fill at once, not block by block');
    expect(repo.requested,
        [for (var i = 0; i < mediaChunkLookahead; i++) att.chunkPath(i)]);

    // Deliberately NO `cancel` and no release: the generator is waiting for a
    // block that never comes. `cancel` would wait for exactly that and hang,
    // and a subsequent failure would have no taker after the abort. A completer
    // left hanging, by contrast, costs nothing — it expires with the test.
    expect(sub, isNotNull);
  });

  test('despite the prefetch the blocks come out in order', () async {
    const count = 6;
    final (att, repo, plain) = await fixture(count);
    final received = <Uint8List>[];
    final done = Completer<void>();
    final sub = decryptedMediaChunks(att, repo, svc).listen(
      received.add,
      onDone: done.complete,
    );
    addTearDown(sub.cancel);

    // The release deliberately runs BACKWARDS within the window: whoever ties
    // the order to the response time fails here.
    for (var runde = 0; runde < count * 4 && !done.isCompleted; runde++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      for (final p in repo.openPaths.reversed.toList()) {
        repo.release(p);
      }
    }
    await done.future;

    expect(received.length, count);
    for (var i = 0; i < count; i++) {
      expect(received[i], equals(plain[i]),
          reason: 'Block $i steht an der falschen Stelle');
    }
  });

  test('fewer blocks than the window: nothing is requested twice',
      () async {
    final (att, repo, plain) = await fixture(2);
    final received = <Uint8List>[];
    final done = Completer<void>();
    final sub = decryptedMediaChunks(att, repo, svc)
        .listen(received.add, onDone: done.complete);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(repo.requested, [att.chunkPath(0), att.chunkPath(1)]);
    repo.release(att.chunkPath(0));
    await Future<void>.delayed(Duration.zero);
    repo.release(att.chunkPath(1));
    await done.future;

    expect(received, equals(plain));
    expect(repo.requested.toSet().length, repo.requested.length,
        reason: 'jeder Block genau einmal');
  });

  test('an error in the first block does not leave the prefetches unhandled'
      'unbehandelte Fehler zurueck', () async {
    // Without `Future.ignore` on the remaining requests, Dart reports them as
    // unhandled errors — noise in the log that looks like a real problem but is
    // none.
    final (att, repo, _) = await fixture(8);
    final errors = <Object>[];
    final done = Completer<void>();
    final sub = decryptedMediaChunks(att, repo, svc).listen(
      (_) {},
      onError: (Object e) {
        errors.add(e);
        done.complete();
      },
    );
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    final pending = List<String>.from(repo.requested);
    repo.fail(pending.first, StateError('Netz weg'));
    // Die nachgezogenen Anforderungen scheitern gleich mit — genau die, die
    // niemand mehr abholt.
    for (final p in pending.skip(1)) {
      repo.fail(p, StateError('Netz weg'));
    }
    await done.future;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(errors, hasLength(1), reason: 'exactly one error reaches the caller');
  });
}
