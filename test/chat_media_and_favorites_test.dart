// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The two new queries of the section "in this chat", against a real SQLite file
// with the real repository — only the encryption is passed through.
//
// The media index is the more delicate part: it decides, based on the DECRYPTED
// content, which row carries a file, and has to pass cleanly over text, system
// and place messages — without a single unreadable row tipping the whole list
// over.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chattr/core/database/database_service.dart';
import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/encryption_service.dart';
import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';

class _PassthroughEncryption extends EncryptionService {
  _PassthroughEncryption()
      : super(
          EncryptionKeyManager(
            const FlutterSecureStorage(),
            BiometricAuthService(),
          ),
        );

  final _store = <String, Map<String, dynamic>>{};
  var _seq = 0;

  @override
  Future<String?> encryptJson(Map<String, dynamic> json) async {
    final handle = 'blob-${_seq++}';
    _store[handle] = json;
    return handle;
  }

  @override
  Future<Map<String, dynamic>?> decryptJson(String ciphertext) async =>
      _store[ciphertext];
}

void main() {
  const me = 'user-me';
  const peer = 'user-peer';
  final t0 = DateTime.utc(2026, 8, 6, 10);

  late MessagesLocalRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    FlutterSecureStorage.setMockInitialValues({});
  });

  setUp(() async {
    await DatabaseService.instance.close();
    await DatabaseService.instance.deleteDatabase();
    repo = MessagesLocalRepository(
      DatabaseService.instance,
      _PassthroughEncryption(),
      () => me,
    );
  });

  tearDownAll(() async {
    await DatabaseService.instance.close();
    await DatabaseService.instance.deleteDatabase();
  });

  String mediaBody(String name, {int size = 1234, List<String>? more}) {
    final items = [
      MediaAttachment(
        mediaType: MediaType.image,
        name: name,
        mime: 'image/jpeg',
        size: size,
        path: 'c1/m/$name.enc',
        keyB64: 'a2V5',
      ),
      for (final w in more ?? const <String>[])
        MediaAttachment(
          mediaType: MediaType.image,
          name: w,
          mime: 'image/jpeg',
          size: size,
          path: 'c1/m/$w.enc',
          keyB64: 'a2V5',
        ),
    ];
    return MediaAlbum(items: items).encode();
  }

  Message msg({
    required String id,
    required String body,
    String chatId = 'c1',
    Duration offset = Duration.zero,
    bool favorite = false,
  }) =>
      Message(
        id: id,
        chatId: chatId,
        senderId: peer,
        recipientId: me,
        createdAt: t0.add(offset),
        decryptedContent: body,
        isFavorite: favorite,
      );

  group('Favoriten', () {
    test('narrowed to a chat, only that one chat comes back', () async {
      await repo.saveMessage(msg(id: 'a', body: 'hallo', favorite: true));
      await repo.saveMessage(
        msg(id: 'b', body: 'servus', chatId: 'c2', favorite: true),
      );
      await repo.saveMessage(msg(id: 'c', body: 'ungemerkt'));

      final nurC1 = await repo.getFavoriteMessages(chatId: 'c1');
      expect(nurC1.map((m) => m.id), ['a']);

      final alle = await repo.getFavoriteMessages();
      expect(alle.map((m) => m.id).toSet(), {'a', 'b'});
    });

    test('the counter agrees with the list', () async {
      await repo.saveMessage(msg(id: 'a', body: 'x', favorite: true));
      await repo.saveMessage(
        msg(id: 'b', body: 'y', offset: const Duration(minutes: 1), favorite: true),
      );
      await repo.saveMessage(msg(id: 'c', body: 'z'));

      expect(await repo.countFavorites('c1'), 2);
      expect((await repo.getFavoriteMessages(chatId: 'c1')).length, 2);
    });
  });

  group('Medien-Index', () {
    test('finds media and passes over everything else', () async {
      await repo.saveMessage(msg(id: 'text', body: 'nur Text'));
      await repo.saveMessage(
        msg(
          id: 'bild',
          body: mediaBody('urlaub.jpg'),
          offset: const Duration(minutes: 1),
        ),
      );
      await repo.saveMessage(
        msg(
          id: 'kaputt',
          // Carries the marker but is not valid JSON — must not tip the list
          // over but be skipped.
          body: '{"${MediaAttachment.marker}":1, kaputt',
          offset: const Duration(minutes: 2),
        ),
      );

      final index = await repo.getMediaMessages('c1');
      expect(index.matches.map((m) => m.id), ['bild']);
      expect(index.complete, isTrue);
    });

    test('newest first', () async {
      await repo.saveMessage(msg(id: 'alt', body: mediaBody('alt.jpg')));
      await repo.saveMessage(
        msg(
          id: 'neu',
          body: mediaBody('neu.jpg'),
          offset: const Duration(hours: 3),
        ),
      );

      final index = await repo.getMediaMessages('c1');
      expect(index.matches.map((m) => m.id), ['neu', 'alt']);
    });

    test('an album counts as one row with several files', () async {
      await repo.saveMessage(
        msg(id: 'album', body: mediaBody('eins.jpg', more: ['zwei.jpg'])),
      );

      final index = await repo.getMediaMessages('c1');
      expect(index.matches.length, 1);
      final album = MediaAlbum.tryParse(index.matches.first.decryptedContent);
      expect(album!.items.length, 2);
    });

    test('the upper bound is reported, not concealed', () async {
      // A silent truncation would make an incomplete list look like a complete
      // one — that is exactly what `complete` protects against.
      for (var i = 0; i < 5; i++) {
        await repo.saveMessage(
          msg(
            id: 'm$i',
            body: mediaBody('bild$i.jpg'),
            offset: Duration(minutes: i),
          ),
        );
      }

      final knapp = await repo.getMediaMessages('c1', scanLimit: 3);
      expect(knapp.matches.length, 3);
      expect(knapp.complete, isFalse);

      final ganz = await repo.getMediaMessages('c1', scanLimit: 50);
      expect(ganz.matches.length, 5);
      expect(ganz.complete, isTrue);
    });

    test('fremde Chats bleiben draussen', () async {
      await repo.saveMessage(msg(id: 'hier', body: mediaBody('hier.jpg')));
      await repo.saveMessage(
        msg(id: 'dort', body: mediaBody('dort.jpg'), chatId: 'c2'),
      );

      final index = await repo.getMediaMessages('c1');
      expect(index.matches.map((m) => m.id), ['hier']);
    });
  });
}
