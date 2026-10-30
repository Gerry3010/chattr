// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Identity pins readable on a locked iPhone — migration safety.
//
// The pins moved from `identity_pins_v2` (plugin default class `unlocked`) to
// `identity_pins_v3` (`first_unlock`), because a call answered on the lock
// screen reads them and died with -25308 (2026-10-24). The move hangs on how
// the real Keychain treats the class: part of every read query (so the old
// entry is invisible under the new options — hence a new name), and ignored by
// delete/deleteAll (so an account reset still clears the new entry).
//
// The unit-test mock ignores `IOSOptions`, so only a real Keychain can answer
// this. A simulator cannot be locked, so the lock itself is covered by
// test/identity_pins_locked_test.dart; this file proves the Keychain facts the
// fix relies on.
//
//   flutter test integration_test/identity_pins_keychain_test.dart -d <simulator-id>
//
// Never run against Gerry's production iPhone — this writes and deletes real
// Keychain items, including a deleteAll. Simulator / emulator only.

import 'dart:convert';

import 'package:chattr/features/identity/identity_verification_repository.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _keyA = 'AAAAidentitykeyAAAA';
const _keyB = 'BBBBidentitykeyBBBB';

/// A v2 document exactly as the app wrote it until now.
String _v2Doc() => jsonEncode({
      'keys': {
        _keyA: {'v': true},
        _keyB: {'v': false},
      },
      'aliases': {'alice': _keyA, 'bob': _keyB},
    });

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Same construction as the app's secureStorageProvider.
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  const v3 = IdentityVerificationRepository.storageKey;
  const v2 = IdentityVerificationRepository.unlockedStorageKey;
  const v1 = IdentityVerificationRepository.legacyStorageKey;
  const newClass = IdentityVerificationRepository.iOptions;

  // delete() ignores the class, so this clears every variant.
  Future<void> wipe() async {
    for (final key in [v1, v2, v3]) {
      await storage.delete(key: key);
    }
  }

  setUp(wipe);
  tearDown(wipe);

  testWidgets('die alte Sperrstufe ist unter der neuen unsichtbar',
      (tester) async {
    // Why the fix needs a new key name: the class rides along in the read.
    await storage.write(key: v2, value: _v2Doc());

    expect(await storage.read(key: v2, iOptions: newClass), isNull,
        reason: 'if this ever finds the item, the class is not part of the '
            'query and a rename would not have been necessary');
    expect(await storage.read(key: v2), isNotNull);
  });

  testWidgets('v2 zieht vollständig in v3 um und bleibt liegen',
      (tester) async {
    await storage.write(key: v2, value: _v2Doc());

    final repo = IdentityVerificationRepository(storage);
    expect(await repo.pinnedKey('alice'), _keyA);
    expect(await repo.isVerified('alice'), isTrue);
    expect(await repo.pinnedKey('bob'), _keyB);
    expect(await repo.isVerified('bob'), isFalse);

    final moved = await storage.read(key: v3, iOptions: newClass);
    expect(moved, isNotNull, reason: 'v3 was not written under first_unlock');
    expect(jsonDecode(moved!), jsonDecode(_v2Doc()));
    expect(await storage.read(key: v3), isNull,
        reason: 'v3 must NOT sit under the default class');
    expect(await storage.read(key: v2), _v2Doc(),
        reason: 'v2 stays for a way back');
  });

  testWidgets('ein neuer Pin ueberlebt eine frische Instanz (App-Neustart)',
      (tester) async {
    await storage.write(key: v2, value: _v2Doc());
    await IdentityVerificationRepository(storage)
        .pin('carol', _keyB, verified: true);

    final fresh = IdentityVerificationRepository(storage);
    expect(await fresh.isVerified('carol'), isTrue);
    expect(await fresh.isVerified('bob'), isTrue,
        reason: 'verification hangs on the key, carol and bob share it');
    expect(await fresh.isVerified('alice'), isTrue,
        reason: 'the migrated pins are still there after the write');
  });

  testWidgets('Konto zuruecksetzen (deleteAll) raeumt v3 mit ab',
      (tester) async {
    await IdentityVerificationRepository(storage)
        .pin('alice', _keyA, verified: true);
    expect(await storage.read(key: v3, iOptions: newClass), isNotNull);

    // AppInit._deleteData() calls exactly this on the shared instance.
    await storage.deleteAll();

    expect(await storage.read(key: v3, iOptions: newClass), isNull,
        reason: 'pins of a reset account survived the wipe');
  });
}
