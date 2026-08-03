// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Guards the startup-wipe path (audit M6/M7 groundwork).
//
// `app_init.dart:130` does `if (!await hasKey()) await generateKey();` — so a
// hasKey() that answers false when a key DOES exist silently overwrites it and
// every stored message becomes undecryptable. That has already happened once
// (see the scar in hasKey's own doc comment, from the accountName change), and
// app lock would have re-armed it: a Face-ID-gated key read cannot answer a
// boolean during startup, before any UI exists.
//
// Hence the sentinel: an unprotected marker that says "a key exists" without
// touching the key. These tests pin the two properties that make it safe —
// hasKey never reads the key when the marker is there, and the write order
// fails closed rather than open.

import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory keychain stand-in that records every read, so a test can assert
/// which item was consulted — that is the whole point here.
class _SpyStorage implements FlutterSecureStorage {
  final Map<String, String> items = {};
  final List<String> reads = [];
  final List<String> writes = [];

  /// Keys whose read should behave like a locked keychain item: iOS throws a
  /// PlatformException rather than returning null.
  final Set<String> locked = {};

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
    if (locked.contains(key)) {
      throw Exception('locked: authentication required for $key');
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
    items.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

class _StubBiometrics implements BiometricAuthService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not needed here');
}

const _keyItem = 'encryption_key_v1';
const _sentinelItem = 'encryption_key_v1_exists';

void main() {
  late _SpyStorage storage;
  late EncryptionKeyManager manager;

  setUp(() {
    storage = _SpyStorage();
    manager = EncryptionKeyManager(storage, _StubBiometrics());
  });

  test('generateKey writes the sentinel BEFORE the key', () async {
    // Order IS the safety property, so assert the order — not just that both
    // items ended up present. A crash between the two writes must leave
    // "sentinel, no key" (hasKey true → nobody overwrites anything), never
    // "key, no sentinel" (hasKey false → generateKey overwrites it).
    await manager.generateKey();

    expect(storage.writes, [_sentinelItem, _keyItem],
        reason: 'reversing this makes the crash window destroy a restored '
            'backup key — see importKey / backup_service.dart:217');
  });

  test('importKey writes the sentinel BEFORE the restored key', () async {
    // Same window, but here the key is NOT disposable: it came out of a backup
    // and the user is mid-rescue.
    await manager.importKey('restored-key');

    expect(storage.writes, [_sentinelItem, _keyItem]);
  });

  test('hasKey reads the sentinel, never the key', () async {
    await manager.generateKey();
    storage.reads.clear();

    expect(await manager.hasKey(), isTrue);
    expect(storage.reads, [_sentinelItem],
        reason: 'reading the key here is what app lock would make unanswerable');
  });

  test('hasKey stays true when the key itself is locked', () async {
    // The scenario app lock creates: the key is present but needs Face ID.
    // hasKey must not care — otherwise startup calls generateKey over it.
    await manager.generateKey();
    storage.locked.add(_keyItem);

    expect(await manager.hasKey(), isTrue);
  });

  test('hasKey is false on a genuinely empty install', () async {
    expect(await manager.hasKey(), isFalse);
  });

  test('hasKey adopts a pre-sentinel install instead of reporting empty',
      () async {
    // Upgrading from a build without the sentinel: the key is there, the marker
    // is not. Reporting false would overwrite the key on the very next line.
    storage.items[_keyItem] = 'pre-existing-key';

    expect(await manager.hasKey(), isTrue);
    expect(storage.items[_sentinelItem], '1',
        reason: 'the marker should be backfilled so later reads are cheap');
  });

  test('importKey writes the sentinel too', () async {
    // Restore path (backup_service.dart:217). Without a sentinel, the next
    // launch would regenerate over the freshly restored key and destroy the
    // history the user was rescuing.
    await manager.importKey('restored-key');

    expect(storage.items[_keyItem], 'restored-key');
    expect(storage.items[_sentinelItem], '1');
    expect(await manager.hasKey(), isTrue);
  });

  test('deleteKey removes the sentinel as well', () async {
    await manager.generateKey();
    await manager.deleteKey();

    expect(storage.items[_sentinelItem], isNull,
        reason: 'a stale marker would claim a key that no longer exists, and '
            'startup would skip generateKey and come up with none at all');
    expect(await manager.hasKey(), isFalse);
  });
}
