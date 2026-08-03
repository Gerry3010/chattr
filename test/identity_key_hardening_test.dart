// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Guards the identity key against a SILENT re-mint (audit #149, Galaxy
// 2026-07-18). The identity key is the TOFU trust anchor: if a persisted key
// that merely became unreadable (keystore error, Android resetOnError wiping the
// namespace) is mistaken for "no key", ensureKeyPair mints a fresh one, it gets
// republished to profiles.identity_public_key, and every peer's safety number
// flips. These tests pin the properties that make that impossible:
//   • generateAndStore writes the sentinel BEFORE the seed (fail-closed),
//   • a seed read that ERRORS throws IdentityKeyLockedException, never re-mints,
//   • a null seed read with the sentinel (or local chat data) present throws too,
//   • only a genuinely fresh install (no seed, no sentinel, no data) mints.

import 'package:chattr/core/security/identity_key_manager.dart';
import 'package:chattr/core/security/key_locked_exception.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory keychain stand-in. Records reads/writes and can make a key's read
/// throw a PlatformException — the way a locked/errored keystore item behaves,
/// which is exactly the case the hardening must not flatten to "absent".
class _SpyStorage implements FlutterSecureStorage {
  final Map<String, String> items = {};
  final List<String> reads = [];
  final List<String> writes = [];

  /// Keys whose read throws a PlatformException instead of returning a value.
  final Set<String> erroring = {};

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
    reads.add(key);
    if (erroring.contains(key)) {
      throw PlatformException(code: 'Storage', message: 'keystore error');
    }
    return items[key];
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
    writes.add(key);
    if (value == null) {
      items.remove(key);
    } else {
      items[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes.add('delete:$key');
    items.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

const _seedItem = 'identity_key_v1';
const _sentinelItem = 'identity_key_v1_exists';

/// A fresh manager over the SAME storage — simulates a cold app start that must
/// read the persisted key back (no session cache).
IdentityKeyManager _reopen(_SpyStorage s,
        {Future<bool> Function()? hasLocalData}) =>
    IdentityKeyManager(s, hasLocalData: hasLocalData);

void main() {
  late _SpyStorage storage;
  late IdentityKeyManager manager;

  setUp(() {
    storage = _SpyStorage();
    manager = IdentityKeyManager(storage);
  });

  test('fresh ensureKeyPair mints and writes the sentinel BEFORE the seed',
      () async {
    final pub = await manager.ensureKeyPair();

    expect(pub, isNotEmpty);
    expect(storage.writes, [_sentinelItem, _seedItem],
        reason: 'a crash between the two must leave "sentinel, no seed" (next '
            'read defers) not "seed, no sentinel" (next null read re-mints)');
    expect(storage.items[_seedItem], isNotNull);
    expect(storage.items[_sentinelItem], '1');
  });

  test('ensureKeyPair is idempotent — same identity, no second mint', () async {
    final a = await manager.ensureKeyPair();
    storage.writes.clear();
    final b = await manager.ensureKeyPair();

    expect(b, a);
    expect(storage.writes, isEmpty, reason: 'cached — no re-write, no re-mint');
  });

  test('a persisted identity survives a cold restart (reads back, no re-mint)',
      () async {
    final pub = await manager.ensureKeyPair();
    final seed = storage.items[_seedItem];

    final reopened = _reopen(storage);
    final pub2 = await reopened.ensureKeyPair();

    expect(pub2, pub);
    expect(storage.items[_seedItem], seed, reason: 'same seed, not overwritten');
  });

  test('LOCKED seed read throws IdentityKeyLockedException and does NOT re-mint',
      () async {
    // The Galaxy case: the seed exists but the read errors. Flattening that to
    // "absent" is what re-mints the identity and flips every peer safety number.
    await manager.ensureKeyPair();
    final seedBefore = storage.items[_seedItem];
    storage.erroring.add(_seedItem);

    final reopened = _reopen(storage);
    await expectLater(
      reopened.ensureKeyPair(),
      throwsA(isA<IdentityKeyLockedException>()),
    );
    expect(storage.items[_seedItem], seedBefore,
        reason: 'the seed must be untouched — never overwritten by a re-mint');
  });

  test('null seed but sentinel present → throws, never re-mints', () async {
    // resetOnError-style: the seed vanished but the sentinel proves one existed.
    storage.items[_sentinelItem] = '1';

    final reopened = _reopen(storage);
    await expectLater(
      reopened.ensureKeyPair(),
      throwsA(isA<IdentityKeyLockedException>()),
    );
    expect(storage.items[_seedItem], isNull, reason: 'no silent mint happened');
  });

  test('null seed, no sentinel, but local chat data present → throws', () async {
    // Pre-sentinel install whose seed was already lost: chat data proves this
    // is NOT a fresh install, so refuse the silent re-mint.
    final reopened = _reopen(storage, hasLocalData: () async => true);
    await expectLater(
      reopened.ensureKeyPair(),
      throwsA(isA<IdentityKeyLockedException>()),
    );
    expect(storage.items[_seedItem], isNull);
  });

  test('genuinely fresh install (no seed/sentinel/data) DOES mint', () async {
    final withData = _reopen(storage, hasLocalData: () async => false);
    final pub = await withData.ensureKeyPair();

    expect(pub, isNotEmpty);
    expect(storage.items[_seedItem], isNotNull);
    expect(storage.items[_sentinelItem], '1');
  });

  test('hasKeyPair reads the sentinel and adopts it on a pre-sentinel install',
      () async {
    // Existing install upgrading into the fix: seed present, sentinel absent.
    storage.items[_seedItem] = 'preexisting-seed-base64==';

    expect(await manager.hasKeyPair(), isTrue);
    expect(storage.items[_sentinelItem], '1',
        reason: 'adopt the marker so a later null read is recognised as lost');
  });

  test('ensureKeyPair adopts the sentinel for a pre-sentinel identity', () async {
    // Seed written by the old (sentinel-less) code. First successful load must
    // backfill the sentinel so a LATER null read defers instead of re-minting.
    final seeded = IdentityKeyManager(storage);
    final pub = await seeded.ensureKeyPair(); // mints (fresh) → writes sentinel
    // Simulate the pre-sentinel state: drop the sentinel, keep the seed.
    storage.items.remove(_sentinelItem);

    final reopened = _reopen(storage);
    final pub2 = await reopened.ensureKeyPair();

    expect(pub2, pub);
    expect(storage.items[_sentinelItem], '1', reason: 'backfilled on load');
  });

  test('hasKeyPair is false on a genuinely empty install', () async {
    expect(await manager.hasKeyPair(), isFalse);
  });

  test('deleteKeyPair removes the seed AND the sentinel', () async {
    await manager.ensureKeyPair();
    await manager.deleteKeyPair();

    expect(storage.items[_seedItem], isNull);
    expect(storage.items[_sentinelItem], isNull,
        reason: 'a stale sentinel would claim a key that no longer exists');
    expect(await manager.hasKeyPair(), isFalse);
  });

  test('regenerate is the ONLY path that re-mints over an existing identity',
      () async {
    final first = await manager.ensureKeyPair();
    final second = await manager.regenerate();

    expect(second, isNot(first), reason: 'explicit, intentional re-mint');
    expect(storage.items[_sentinelItem], '1');
  });
}
