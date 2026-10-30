// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// A call answered on the iPhone lock screen died right after "accept"
// (2026-10-24): sending the answer reads the identity pins, and they sat under
// the plugin's default keychain class `unlocked` — unreadable while the phone
// is locked (-25308). They now live under `first_unlock` in a new entry.
//
// The stand-in below keeps the two iOS rules the fix hangs on, which the
// plugin's own test mock ignores: the class is part of every read, and an
// `unlocked` item cannot be touched while the phone is locked.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/identity/identity_verification_repository.dart';

const _keyA = 'AAAAidentitykeyAAAA';
const _keyB = 'BBBBidentitykeyBBBB';

typedef _Item = ({String key, KeychainAccessibility cls});

class _Keychain implements FlutterSecureStorage {
  final Map<_Item, String> items = {};
  bool locked = false;

  static KeychainAccessibility _cls(AppleOptions? o) =>
      o?.accessibility ?? KeychainAccessibility.unlocked;

  static bool _needsUnlock(KeychainAccessibility c) =>
      c == KeychainAccessibility.unlocked ||
      c == KeychainAccessibility.unlocked_this_device ||
      c == KeychainAccessibility.passcode;

  void _guard(_Item item) {
    if (locked && _needsUnlock(item.cls)) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'User interaction is not allowed.',
        details: -25308,
      );
    }
  }

  void put(String key, String value, KeychainAccessibility cls) =>
      items[(key: key, cls: cls)] = value;

  String? at(String key, KeychainAccessibility cls) =>
      items[(key: key, cls: cls)];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final item = (key: key, cls: _cls(iOptions));
    if (!items.containsKey(item)) return null;
    _guard(item);
    return items[item];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final item = (key: key, cls: _cls(iOptions));
    _guard(item);
    if (value == null) {
      items.remove(item);
    } else {
      items[item] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

String _doc(Map<String, bool> verifiedByKey, Map<String, String> aliases) =>
    jsonEncode({
      'keys': {
        for (final e in verifiedByKey.entries) e.key: {'v': e.value},
      },
      'aliases': aliases,
    });

void main() {
  late _Keychain keychain;
  late IdentityVerificationRepository repo;

  setUp(() {
    keychain = _Keychain();
    repo = IdentityVerificationRepository(keychain);
  });

  const first = KeychainAccessibility.first_unlock;
  const unlocked = KeychainAccessibility.unlocked;

  group('Umzug aus dem alten Eintrag', () {
    test('Pins und Verifizierung ziehen vollständig um', () async {
      keychain.put(
        IdentityVerificationRepository.unlockedStorageKey,
        _doc({_keyA: true, _keyB: false}, {'alice': _keyA, 'bob': _keyB}),
        unlocked,
      );

      expect(await repo.pinnedKey('alice'), _keyA);
      expect(await repo.isVerified('alice'), isTrue);
      expect(await repo.isVerified('bob'), isFalse);

      final moved = keychain.at(
        IdentityVerificationRepository.storageKey,
        first,
      );
      expect(moved, isNotNull, reason: 'written under first_unlock');
      expect(
        jsonDecode(moved!),
        jsonDecode(
          keychain.at(
            IdentityVerificationRepository.unlockedStorageKey,
            unlocked,
          )!,
        ),
      );
    });

    test('der alte Eintrag bleibt für einen Rückweg liegen', () async {
      final old = _doc({_keyA: true}, {'alice': _keyA});
      keychain.put(
        IdentityVerificationRepository.unlockedStorageKey,
        old,
        unlocked,
      );

      await repo.pinnedKey('alice');
      expect(
        keychain.at(
          IdentityVerificationRepository.unlockedStorageKey,
          unlocked,
        ),
        old,
      );
    });

    test('ohne v2 wird v1 gefaltet, wie bisher', () async {
      keychain.put(
        IdentityVerificationRepository.legacyStorageKey,
        jsonEncode({
          'alice': {'k': _keyA, 'v': true},
        }),
        unlocked,
      );

      expect(await repo.isVerified('alice'), isTrue);
      expect(
        keychain.at(IdentityVerificationRepository.storageKey, first),
        isNotNull,
      );
    });

    test('ein neuer Pin landet im neuen Eintrag, nie im alten', () async {
      final old = _doc({_keyA: false}, {'alice': _keyA});
      keychain.put(
        IdentityVerificationRepository.unlockedStorageKey,
        old,
        unlocked,
      );

      await repo.pin('alice', _keyA, verified: true);

      expect(
        keychain.at(
          IdentityVerificationRepository.unlockedStorageKey,
          unlocked,
        ),
        old,
      );
      expect(await repo.isVerified('alice'), isTrue);
    });
  });

  group('gesperrtes iPhone', () {
    test('nach dem Umzug: der Anruf liest die Pins trotz Sperre', () async {
      keychain.put(
        IdentityVerificationRepository.unlockedStorageKey,
        _doc({_keyA: true}, {'alice': _keyA}),
        unlocked,
      );
      await repo.pinnedKey('alice'); // unlocked: moves over

      keychain.locked = true;
      expect(await repo.pinnedKey('alice'), _keyA);
      expect(await repo.isVerified('alice'), isTrue);
      expect(
        await repo.recordSeen('bob', _keyB),
        IdentityVerificationState.unverified,
        reason: 'a first-seen peer can be pinned while locked too',
      );
    });

    test('vor dem Umzug: wirft, statt leer zu antworten', () async {
      // The first wake after the update may come while the phone is locked.
      // Answering "no pins" there would write an empty document and every
      // verified contact would come back unverified.
      final old = _doc({_keyA: true}, {'alice': _keyA});
      keychain.put(
        IdentityVerificationRepository.unlockedStorageKey,
        old,
        unlocked,
      );
      keychain.locked = true;

      await expectLater(
        repo.pinnedKey('alice'),
        throwsA(isA<PlatformException>()),
      );
      expect(
        keychain.at(IdentityVerificationRepository.storageKey, first),
        isNull,
        reason: 'nothing written over the pins',
      );

      keychain.locked = false;
      expect(
        await repo.isVerified('alice'),
        isTrue,
        reason: 'the next unlocked read moves them over intact',
      );
    });
  });
}
