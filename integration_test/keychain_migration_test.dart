// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Audit M5 — device-bound chat keys, migration safety.
//
// `ChatKeyPairManager` now stores per-chat private keys under hardened iOS
// options (`first_unlock_this_device` + `accountName: 'chattr_chat_keys'`).
// Keys written BEFORE that change sit under the *default* options. If iOS puts
// `kSecAttrAccessible`/`kSecAttrAccount` into the read query, a hardened read
// misses the legacy item — every existing user would silently lose their chats.
// `_readMigrating` is supposed to catch that.
//
// This can only be proven against a real Keychain: the unit-test mock and the
// Linux libsecret backend ignore `IOSOptions` entirely, so the whole question is
// a no-op there. Hence integration_test.
//
//   flutter test integration_test/keychain_migration_test.dart -d <simulator-id>
//
// Never run against Gerry's production iPhone — this writes and deletes real
// Keychain items. Simulator / emulator only.

import 'dart:convert';

import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _chatId = 'M5TESTCHAT';
const _storageKey = 'chat_pqc_key_$_chatId';
const _prevStorageKey = 'chat_pqc_key_prev_$_chatId';

/// A record shaped exactly like the pre-M5 on-disk format.
String _legacyRecord() => jsonEncode({
      'xPriv': base64.encode(List<int>.filled(32, 1)),
      'xPub': base64.encode(List<int>.filled(32, 2)),
      'mPriv': base64.encode(List<int>.filled(64, 3)),
      'mPub': base64.encode(List<int>.filled(64, 4)),
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();
  final manager = ChatKeyPairManager(storage);

  // Both variants of every key, so a half-finished run can't poison the next.
  Future<void> wipe() async {
    for (final key in [_storageKey, _prevStorageKey]) {
      await storage.delete(key: key);
      await manager.deleteKeyPair(_chatId);
    }
  }

  setUp(wipe);
  tearDown(wipe);

  testWidgets('legacy (pre-M5) key written with default options is still found',
      (tester) async {
    // Simulate an install that predates the hardening.
    await storage.write(key: _storageKey, value: _legacyRecord());

    final priv = await manager.getPrivateKey(_chatId);

    expect(priv, isNotNull,
        reason: 'M5 migration failed — a pre-M5 key is unreadable after the '
            'accessibility/accountName change. Existing users would lose all '
            'chats on upgrade.');
    final decoded = jsonDecode(priv!) as Map<String, dynamic>;
    expect(decoded['x'], base64.encode(List<int>.filled(32, 1)));
    expect(decoded['m'], base64.encode(List<int>.filled(64, 3)));
  });

  testWidgets('reading a legacy key migrates it in place', (tester) async {
    await storage.write(key: _storageKey, value: _legacyRecord());
    await manager.getPrivateKey(_chatId); // triggers _readMigrating

    // The legacy (default-options) copy must be gone...
    expect(await storage.read(key: _storageKey), isNull,
        reason: 'legacy copy was not removed after migration — the '
            'exfiltratable, backed-up item survives');

    // ...and the record must now live on the hardened path.
    expect(await manager.hasKeyPair(_chatId), isTrue);
    expect(await manager.getPrivateKey(_chatId), isNotNull);
  });

  testWidgets('freshly generated key roundtrips through hardened options',
      (tester) async {
    await manager.generateKeyPairForChat(_chatId);

    expect(await manager.hasKeyPair(_chatId), isTrue);
    final pub = await manager.getPublicKey(_chatId);
    final priv = await manager.getPrivateKey(_chatId);
    expect(pub, isNotNull);
    expect(priv, isNotNull);

    // Real key material, not an echo of the fake legacy record.
    final (xPub, mPub) = ChatKeyPairManager.decodePublic(pub!);
    final (xPriv, mPriv) = ChatKeyPairManager.decodePrivate(priv!);
    expect(xPub.length, 32);
    expect(xPriv.length, 32);
    expect(mPub, isNotEmpty);
    expect(mPriv, isNotEmpty);
  });

  testWidgets('deleteKeyPair removes hardened AND legacy copies',
      (tester) async {
    // A legacy record and a hardened one can coexist (upgrade mid-rotation).
    await manager.generateKeyPairForChat(_chatId);
    await storage.write(key: _prevStorageKey, value: _legacyRecord());

    await manager.deleteKeyPair(_chatId);

    expect(await manager.hasKeyPair(_chatId), isFalse);
    expect(await storage.read(key: _storageKey), isNull);
    expect(await storage.read(key: _prevStorageKey), isNull,
        reason: 'legacy previous-generation key survived deleteKeyPair');
    expect(await manager.getAllPrivateKeys(_chatId), isEmpty);
  });

  testWidgets('rotation keeps a legacy current key readable as previous',
      (tester) async {
    // Pre-M5 install rotates for the first time after the upgrade: the legacy
    // record must survive as the retained previous generation, or in-flight
    // messages encrypted for it stop decrypting.
    await storage.write(key: _storageKey, value: _legacyRecord());

    await manager.rotateKeyPairForChat(_chatId);

    final all = await manager.getAllPrivateKeys(_chatId);
    expect(all.length, 2, reason: 'previous generation was lost on rotation');
    final prev = jsonDecode(all[1]) as Map<String, dynamic>;
    expect(prev['x'], base64.encode(List<int>.filled(32, 1)),
        reason: 'retained previous key is not the pre-M5 one');
  });
}
