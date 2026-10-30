// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-8: a backup made on an iPhone held no chat key at all. It read secure
// storage with `readAll()` and the plugin defaults, and on iOS the defaults
// name another keychain service (`flutter_secure_storage_service`) than the one
// the chat keys live in (`chattr_chat_keys`), plus another class. The in-memory
// mock of the plugin ignores options, so the old tests could not see it; the
// storage below keeps a separate namespace per service and class, like the
// real keychain.
//
// Also pinned down here: the restore signs in with the file's refresh token
// only when it has to (that token is single-use), and it never overwrites a
// chat key this device already holds.

import 'dart:convert';

import 'package:chattr/core/backup/backup_service.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/identity_key_manager.dart';
import 'package:chattr/features/identity/identity_verification_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/keychain_storage.dart';

class _DbKey extends Fake implements EncryptionKeyManager {
  String? key;

  @override
  Future<String?> getKey({bool requireBiometric = true}) async => key;

  @override
  Future<void> importKey(String k) async => key = k;
}

class _Auth implements BackupAuth {
  _Auth(this.currentUserId, {this.lands, this.fails = false});

  @override
  String? currentUserId;

  @override
  String? get currentRefreshToken => 'token-of-$currentUserId';

  final String? lands;
  final bool fails;
  int signIns = 0;

  @override
  Future<String?> signInWithRefreshToken(String refreshToken) async {
    signIns++;
    if (fails) throw Exception('Invalid Refresh Token: Already Used');
    currentUserId = lands;
    return lands;
  }
}

String _blob(String tag) =>
    jsonEncode({'xPriv': tag, 'xPub': tag, 'mPriv': tag, 'mPub': tag});

/// What the decrypt path returns for a stored [_blob].
String _priv(String tag) => jsonEncode({'x': tag, 'm': tag});

class _Device {
  _Device(String userId, {String? lands, bool fails = false})
      : auth = _Auth(userId, lands: lands, fails: fails) {
    keys = ChatKeyPairManager(storage);
    identity = IdentityKeyManager(storage);
    pins = IdentityVerificationRepository(storage);
    service = BackupService(db, keys, identity, pins, auth);
  }

  final storage = KeychainStorage();
  final db = _DbKey();
  final _Auth auth;
  late final ChatKeyPairManager keys;
  late final IdentityKeyManager identity;
  late final IdentityVerificationRepository pins;
  late final BackupService service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const me = '4f6dbce8-453f-47bf-b625-4868be77388f';

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS: die Sicherung findet die Chat-Schlüssel (alter Weg fand keinen)',
      () async {
    final device = _Device(me);
    await device.keys.importRestoredKey('chat_pqc_key_c1', _blob('c1'));
    await device.keys.importRestoredKey('chat_pqc_key_prev_c1', _blob('p1'));

    final viaDefaults = await device.storage.readAll();
    expect(viaDefaults.keys.where((k) => k.startsWith('chat_pqc_key_')),
        isEmpty,
        reason: 'so las das Backup bisher: unter dem Standard-Dienst');

    expect(await device.keys.exportAllKeys(), {
      'chat_pqc_key_c1': _blob('c1'),
      'chat_pqc_key_prev_c1': _blob('p1'),
    });
  });

  test('Sicherung und Wiederherstellung tragen Schlüssel, Identität und Pins',
      () async {
    final a = _Device(me);
    a.db.key = 'db-key';
    await a.keys.importRestoredKey('chat_pqc_key_c1', _blob('c1'));
    final identity = await a.identity.ensureKeyPair();
    await a.pins.pin('peer', 'peer-key', verified: true);

    final file = await a.service.createBackup('correct horse battery');

    // A new phone, already signed in as the same account (recovery phrase).
    final b = _Device(me);
    final restored = await b.service.restoreBackup(file, 'correct horse battery');

    expect(b.auth.signIns, 0,
        reason: 'gleiches Konto: das Einmal-Token aus der Datei bleibt unberührt');
    expect(restored.chatKeys.keys, ['chat_pqc_key_c1']);
    expect(b.db.key, 'db-key');
    expect(await b.keys.getPrivateKey('c1'), _priv('c1'));
    expect(await b.identity.publicKeyBase64(), identity);
    expect(await b.pins.isVerified('peer'), isTrue);
  });

  test('anderes Konto, Token verbraucht: nichts wird geschrieben', () async {
    final a = _Device(me);
    a.db.key = 'db-key';
    await a.keys.importRestoredKey('chat_pqc_key_c1', _blob('c1'));
    final file = await a.service.createBackup('correct horse battery');

    final b = _Device('someone-else', fails: true);
    await expectLater(
      b.service.restoreBackup(file, 'correct horse battery'),
      throwsA(isA<BackupException>()
          .having((e) => e.error, 'error', BackupError.sessionExpired)),
    );
    expect(b.db.key, isNull);
    expect(await b.keys.exportAllKeys(), isEmpty);
  });

  test('Anmeldung landet im falschen Konto: Abbruch', () async {
    final a = _Device(me);
    a.db.key = 'db-key';
    final file = await a.service.createBackup('correct horse battery');

    final b = _Device('someone-else', lands: 'a-third-account');
    await expectLater(
      b.service.restoreBackup(file, 'correct horse battery'),
      throwsA(isA<BackupException>()
          .having((e) => e.error, 'error', BackupError.accountMismatch)),
    );
    expect(b.db.key, isNull);
  });

  group('restoreKeys überschreibt keinen Schlüssel des Geräts', () {
    test('leeres Gerät: aktueller und vorheriger kommen an ihren Platz',
        () async {
      final d = _Device(me);
      await d.keys.restoreKeys({
        'chat_pqc_key_c1': _blob('old'),
        'chat_pqc_key_prev_c1': _blob('older'),
      });
      expect(await d.keys.getAllPrivateKeys('c1'),
          [_priv('old'), _priv('older')]);
    });

    test('nach der Phrase: eigener Schlüssel bleibt, der alte wird Vorgänger',
        () async {
      final d = _Device(me);
      await d.keys.importRestoredKey('chat_pqc_key_c1', _blob('fresh'));
      await d.keys.restoreKeys({
        'chat_pqc_key_c1': _blob('old'),
        'chat_pqc_key_prev_c1': _blob('older'),
      });
      expect(await d.keys.getAllPrivateKeys('c1'),
          [_priv('fresh'), _priv('old')],
          reason: 'Nachrichten an beide Schlüssel bleiben lesbar');
    });

    test('Gerät hat beide: die Sicherung ändert nichts', () async {
      final d = _Device(me);
      await d.keys.importRestoredKey('chat_pqc_key_c1', _blob('cur'));
      await d.keys.importRestoredKey('chat_pqc_key_prev_c1', _blob('prev'));
      final written = await d.keys.restoreKeys({
        'chat_pqc_key_c1': _blob('old'),
        'chat_pqc_key_prev_c1': _blob('older'),
      });
      expect(written, 0);
      expect(await d.keys.getAllPrivateKeys('c1'),
          [_priv('cur'), _priv('prev')]);
    });
  });

  test('Pins zusammenführen: verifiziert bleibt verifiziert, Gerät gewinnt',
      () {
    final merged = IdentityVerificationRepository.mergePinDocuments(
      {
        'keys': {
          'k-new': {'v': false},
        },
        'aliases': {'bob': 'k-new'},
      },
      {
        'keys': {
          'k-old': {'v': true},
          'k-new': {'v': true},
        },
        'aliases': {'bob': 'k-old', 'carol': 'k-old'},
      },
    );
    expect((merged['aliases'] as Map)['bob'], 'k-new');
    expect((merged['aliases'] as Map)['carol'], 'k-old');
    expect((merged['keys'] as Map)['k-new'], {'v': true});
    expect((merged['keys'] as Map)['k-old'], {'v': true});
  });

  test('alte Sicherung ohne Identität lässt sich weiter lesen', () {
    final p = BackupPayload.fromJson({
      'userId': me,
      'refreshToken': 't',
      'encryptionKey': 'k',
      'chatKeys': <String, String>{},
    });
    expect(p.identitySeed, isNull);
    expect(p.identityPins, isNull);
  });
}
