// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Since 2026-08-24 the trust store hangs on the IDENTITY KEY, no longer on the
// user id: the person is the key, the id merely an address. Both are checked —
// that the old store (`identity_pins_v1`) is migrated without loss, and that a
// second address of the same person counts as verified at once. The latter is
// the visible gain: whoever was verified in the group is verified in a freshly
// opened 1:1 too.

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/identity/identity_verification_repository.dart';

const _keyA = 'AAAAidentitykeyAAAA';
const _keyB = 'BBBBidentitykeyBBBB';

IdentityVerificationRepository _repo() =>
    IdentityVerificationRepository(const FlutterSecureStorage());

Future<Map<String, dynamic>> _doc() async {
  final raw = await const FlutterSecureStorage()
      .read(key: IdentityVerificationRepository.storageKey);
  return Map<String, dynamic>.from(jsonDecode(raw!) as Map);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('migrating the old store', () {
    test('pins travel along with their verified flag', () async {
      FlutterSecureStorage.setMockInitialValues({
        IdentityVerificationRepository.legacyStorageKey: jsonEncode({
          'alice': {'k': _keyA, 'v': true},
          'bob': {'k': _keyB, 'v': false},
        }),
      });

      final repo = _repo();
      expect(await repo.pinnedKey('alice'), _keyA);
      expect(await repo.isVerified('alice'), isTrue);
      expect(await repo.pinnedKey('bob'), _keyB);
      expect(await repo.isVerified('bob'), isFalse);
    });

    test('two addresses with the same key become ONE person', () async {
      // Exactly the case at issue: the same person was pinned under two ids,
      // once verified, once not. After the migration there is one entry — and
      // the user's decision wins.
      FlutterSecureStorage.setMockInitialValues({
        IdentityVerificationRepository.legacyStorageKey: jsonEncode({
          'alice-in-group': {'k': _keyA, 'v': false},
          'alice-direct': {'k': _keyA, 'v': true},
        }),
      });

      final repo = _repo();
      expect(await repo.isVerified('alice-in-group'), isTrue);
      expect(await repo.isVerified('alice-direct'), isTrue);

      final doc = await _doc();
      expect((doc['keys'] as Map).length, 1);
      expect((doc['aliases'] as Map).length, 2);
    });

    test('an unreadable old store starts empty rather than trusting', () async {
      FlutterSecureStorage.setMockInitialValues({
        IdentityVerificationRepository.legacyStorageKey: 'kein json',
      });

      final repo = _repo();
      expect(await repo.pinnedKey('alice'), isNull);
      expect(
        await repo.recordSeen('alice', _keyA),
        IdentityVerificationState.unverified,
        reason: 'freshly pinned, but NOT as verified',
      );
    });

    test('the old store stays for a way back', () async {
      FlutterSecureStorage.setMockInitialValues({
        IdentityVerificationRepository.legacyStorageKey: jsonEncode({
          'alice': {'k': _keyA, 'v': true},
        }),
      });

      await _repo().pinnedKey('alice');
      final legacy = await const FlutterSecureStorage()
          .read(key: IdentityVerificationRepository.legacyStorageKey);
      expect(legacy, isNotNull);
    });
  });

  group('trust hangs on the key', () {
    test('erstmals gesehen: gepinnt, unverifiziert', () async {
      final repo = _repo();
      expect(
        await repo.recordSeen('alice', _keyA),
        IdentityVerificationState.unverified,
      );
      expect(await repo.pinnedKey('alice'), _keyA);
    });

    test('no key published: unknown, no pin', () async {
      final repo = _repo();
      expect(
        await repo.recordSeen('alice', null),
        IdentityVerificationState.unknown,
      );
      expect(await repo.pinnedKey('alice'), isNull);
    });

    test('a different key under the same address: changed', () async {
      final repo = _repo();
      await repo.recordSeen('alice', _keyA);
      expect(
        await repo.recordSeen('alice', _keyB),
        IdentityVerificationState.changed,
      );
      expect(await repo.pinnedKey('alice'), _keyA,
          reason: 'a differing key never overwrites the pin silently');
    });

    test('verified once applies to EVERY address of the same person',
        () async {
      // The gain of this change, and the reason for the round: verified in the
      // group, then a 1:1 with the same person — before, "unverified" stood
      // there again, because the id was a different one.
      final repo = _repo();
      await repo.recordSeen('alice-in-group', _keyA);
      await repo.pin('alice-in-group', _keyA, verified: true);

      expect(
        await repo.recordSeen('alice-direct', _keyA),
        IdentityVerificationState.verified,
      );
      expect(await repo.isVerified('alice-direct'), isTrue);
    });

    test('pin() does not take a verification back', () async {
      final repo = _repo();
      await repo.pin('alice', _keyA, verified: true);
      await repo.pin('alice-elsewhere', _keyA, verified: false);
      expect(await repo.isVerified('alice'), isTrue);
    });

    test('confirming a key change leaves nothing old behind', () async {
      // Otherwise the old key would come back later as "verified" — on the
      // strength of a decision the user has since replaced.
      final repo = _repo();
      await repo.pin('alice', _keyA, verified: true);
      await repo.pin('alice', _keyB, verified: true);

      final doc = await _doc();
      expect((doc['keys'] as Map).containsKey(_keyA), isFalse);
      expect((doc['keys'] as Map).containsKey(_keyB), isTrue);
    });

    test('forgetting removes the address and the orphaned key', () async {
      final repo = _repo();
      await repo.pin('alice', _keyA, verified: true);
      await repo.forget('alice');

      expect(await repo.pinnedKey('alice'), isNull);
      final doc = await _doc();
      expect((doc['keys'] as Map), isEmpty);
    });

    test('forgetting leaves the key while somebody still uses it',
        () async {
      final repo = _repo();
      await repo.pin('alice-in-group', _keyA, verified: true);
      await repo.pin('alice-direct', _keyA, verified: true);
      await repo.forget('alice-in-group');

      expect(await repo.isVerified('alice-direct'), isTrue);
    });
  });
}
