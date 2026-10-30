// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// 2026-10-15: photos and videos became unviewable after a while, the bubble
// spinning forever. The device never kept a copy (every bubble downloaded into
// memory and dropped the bytes again), reported "downloaded" anyway, and the
// server deleted the blob 24 h later. These tests pin the repair: a kept,
// still encrypted copy, "downloaded" only once it is kept, "gone" as a final
// state, and a cleanup that cannot eat media it should keep.

import 'dart:io';
import 'dart:typed_data';

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/media_blob_store.dart';
import 'package:chattr/features/media/media_blob_store_io.dart';
import 'package:chattr/features/media/media_repository.dart';
import 'package:chattr/features/media/widgets/media_message_view.dart'
    show mediaRetry;
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _chat = '11111111-1111-4111-8111-111111111111';
const _msg = '22222222-2222-4222-8222-222222222222';
const _msg2 = '33333333-3333-4333-8333-333333333333';
const _path = '$_chat/$_msg/media-0.enc';

Uint8List _bytes(int n) => Uint8List.fromList(List.filled(4, n));

/// Waits until [done] holds, at most [limit]. signalMediaDownloaded runs
/// unawaited; 20 ms covered its file writes here but not on the CI runner
/// (pipeline #916, 2026-10-23).
Future<void> _until(
  bool Function() done, {
  Duration limit = const Duration(seconds: 2),
}) async {
  final end = DateTime.now().add(limit);
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _Repo extends MediaRepository {
  _Repo(MediaBlobStore store)
      : super(SupabaseClient('http://localhost', 'anon'), store);

  final remote = <String, Uint8List>{};
  final fetched = <String>[];
  final marked = <String>[];

  @override
  Future<Uint8List> fetchRemote(String path) async {
    fetched.add(path);
    final b = remote[path];
    if (b == null) {
      throw const StorageException('Object not found', statusCode: '400');
    }
    return b;
  }

  final uploaded = <String>[];

  @override
  Future<void> putRemote(String path, Uint8List blob,
      {required FileOptions fileOptions}) async {
    uploaded.add(path);
    remote[path] = blob;
  }

  @override
  Future<void> markDownloaded(String chatId, String messageId) async =>
      marked.add('$chatId/$messageId');
}

MediaAttachment _att({String? thumb, int? chunks}) => MediaAttachment(
      mediaType: chunks != null ? MediaType.video : MediaType.image,
      name: 'x',
      mime: 'image/jpeg',
      size: 4,
      path: chunks != null ? '$_chat/$_msg/media-0' : _path,
      keyB64: 'AAAA',
      chunkCount: chunks,
      thumbPath: thumb,
    );

void main() {
  late Directory tmp;
  late FileMediaBlobStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('media_store_test');
    store = FileMediaBlobStore(baseDir: () async => tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('Ablage', () {
    test('schreibt, liest, kennt und löscht je Nachricht', () async {
      await store.write(_path, _bytes(7));
      expect(await store.read(_path), _bytes(7));
      expect(await store.contains(_path), isTrue);
      expect((await store.storedMessages()).keys, ['$_chat/$_msg']);
      expect(tmp.listSync(recursive: true).where((e) => e.path.endsWith('.part')),
          isEmpty, reason: 'nichts Halbgeschriebenes bleibt liegen');
      await store.deleteMessage(_chat, _msg);
      expect(await store.read(_path), isNull);
    });

    test('nur die Pfadform der App landet auf der Platte', () async {
      for (final evil in [
        '../../../etc/passwd',
        '$_chat/$_msg/../../escape.enc',
        '/abs/$_chat/$_msg/media-0.enc',
        '$_chat/$_msg/photo.jpg',
        'not-a-uuid/$_msg/media-0.enc',
        '$_chat/$_msg/media-0.enc/x',
      ]) {
        expect(isStorableMediaPath(evil), isFalse, reason: evil);
        await store.write(evil, _bytes(1));
      }
      expect(tmp.listSync(recursive: true), isEmpty,
          reason: 'kein vom Absender gewählter Pfad wird geschrieben');
      for (final ok in [
        _path,
        '$_chat/$_msg/media-3.enc',
        '$_chat/$_msg/media-0-thumb.enc',
        '$_chat/$_msg/media-0-chunk-12.enc',
      ]) {
        expect(isStorableMediaPath(ok), isTrue, reason: ok);
      }
    });

    test('Abmelden leert alles', () async {
      await store.write(_path, _bytes(1));
      await store.clear();
      expect(await store.storedMessages(), isEmpty);
    });
  });

  group('Repository', () {
    test('lädt einmal vom Server und danach nur noch vom Gerät', () async {
      final repo = _Repo(store)..remote[_path] = _bytes(5);
      expect(await repo.downloadEncrypted(_path), _bytes(5));
      repo.remote.clear(); // the server reaps it
      expect(await repo.downloadEncrypted(_path), _bytes(5));
      expect(repo.fetched, [_path], reason: 'der zweite Blick braucht keinen Server');
    });

    test('vom Server gelöscht und nicht auf dem Gerät: endgültig „weg“', () async {
      final repo = _Repo(store);
      await expectLater(
          repo.downloadEncrypted(_path), throwsA(isA<MediaGoneException>()));
    });

    test('der Absender behält beim Hochladen seine Kopie', () async {
      final repo = _Repo(store);
      final path = await repo.uploadEncrypted(
        chatId: _chat,
        messageId: _msg,
        fileName: 'x.jpg',
        blob: _bytes(9),
        kind: MediaType.image,
      );
      expect(repo.uploaded, [path]);
      repo.remote.clear(); // reaped after the recipients got theirs
      expect(await repo.downloadEncrypted(path), _bytes(9));
      expect(repo.fetched, isEmpty, reason: 'die eigene Blase braucht den Server nicht');
    });

    test('„heruntergeladen“ geht erst raus, wenn die Kopie liegt', () async {
      final repo = _Repo(const NoMediaBlobStore())..remote[_path] = _bytes(1);
      await repo.downloadEncrypted(_path);
      signalMediaDownloaded(repo, _att());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(repo.marked, isEmpty,
          reason: 'ohne gesicherte Kopie darf der Server nicht löschen');

      final kept = _Repo(store)..remote[_path] = _bytes(1);
      await kept.downloadEncrypted(_path);
      signalMediaDownloaded(kept, _att());
      await _until(() => kept.marked.isNotEmpty);
      expect(kept.marked, ['$_chat/$_msg']);
    });

    test('das Vorschaubild eines Videos wird vor der Meldung gesichert', () async {
      const thumb = '$_chat/$_msg/media-0-thumb.enc';
      final repo = _Repo(store)
        ..remote[_path] = _bytes(1)
        ..remote[thumb] = _bytes(2);
      await repo.downloadEncrypted(_path);
      signalMediaDownloaded(repo, _att(thumb: thumb));
      await _until(() => repo.marked.isNotEmpty);
      expect(await store.read(thumb), _bytes(2));
      expect(repo.marked, hasLength(1));
    });

    test('ein Video in Blöcken gilt erst als gesichert, wenn alle da sind', () async {
      final att = _att(chunks: 3);
      final repo = _Repo(store);
      for (var i = 0; i < 3; i++) {
        repo.remote[att.chunkPath(i)] = _bytes(i);
      }
      await repo.downloadEncrypted(att.chunkPath(0));
      await repo.downloadEncrypted(att.chunkPath(1));
      expect(await repo.hasLocalCopy(att), isFalse);
      await repo.downloadEncrypted(att.chunkPath(2));
      expect(await repo.hasLocalCopy(att), isTrue);
    });
  });

  group('kein endloses Drehen', () {
    test('„weg“ wird nie wiederholt, anderes nur ein paar Mal', () {
      expect(mediaRetry(0, const MediaGoneException('p')), isNull);
      expect(mediaRetry(0, Exception('offline')), isNotNull);
      expect(mediaRetry(4, Exception('offline')), isNull);
    });
  });

  group('Aufräumen', () {
    final now = DateTime.now();

    test('entfernt Kopien gelöschter Nachrichten, behält die vorhandenen', () async {
      await store.write(_path, _bytes(1));
      await store.write('$_chat/$_msg2/media-0.enc', _bytes(2));
      final removed = await sweepOrphanMedia(
        store,
        existingIds: (ids) async => {_msg},
        messageCount: () async => 5,
        now: now.add(const Duration(days: 2)),
      );
      expect(removed, 1);
      expect(await store.read(_path), isNotNull);
      expect(await store.read('$_chat/$_msg2/media-0.enc'), isNull);
    });

    test('lässt Frisches liegen: der Absender speichert vor seiner Nachricht', () async {
      await store.write(_path, _bytes(1));
      final removed = await sweepOrphanMedia(
        store,
        existingIds: (ids) async => {},
        messageCount: () async => 5,
        now: now,
      );
      expect(removed, 0);
    });

    test('leere oder kaputte Datenbank: nichts wird gelöscht', () async {
      await store.write(_path, _bytes(1));
      expect(
          await sweepOrphanMedia(store,
              existingIds: (ids) async => {},
              messageCount: () async => 0,
              now: now.add(const Duration(days: 2))),
          0);
      await expectLater(
          sweepOrphanMedia(store,
              existingIds: (ids) async => throw StateError('db'),
              messageCount: () async => 5,
              now: now.add(const Duration(days: 2))),
          throwsStateError);
      expect(await store.read(_path), isNotNull);
    });
  });
}
