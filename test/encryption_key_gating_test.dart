// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Pins the getKey contract and the gating-marker behaviour that make the
// content-key ACL (audit M6/M7) safe to turn on:
//   * a LOCKED read surfaces as KeyLockedException — never null (null reads as
//     "no key" and wipes/drops), never cached,
//   * generate/import HONOUR the current gating marker so they never silently
//     downgrade a gated key back to ungated,
//   * deleteKey clears the marker too.
//
// The iOS ACL enforcement itself is device-verified (integration_test +
// memory m6m7-keychain-acl-enforcement), not here — setKeyGated is a no-op off
// iOS, so these host tests exercise the platform-independent logic only.

import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/key_locked_exception.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory keychain stand-in that can (a) throw a PlatformException on a
/// specific key's read to simulate a locked ACL item, and (b) record the
/// iOptions each write used, so a test can assert the key went in gated/ungated.
class _SpyStorage implements FlutterSecureStorage {
  final Map<String, String> items = {};
  final Set<String> lockedThrowsPlatform = {};
  final List<({String key, AppleOptions? iOptions})> keyWrites = [];

  /// When false (default) a UI-suppressed probe read (`authenticationUIBehavior
  /// == 'u_AuthUIF'`) THROWS -25308 — i.e. the ACL is enforcing. When true it
  /// returns the value, simulating the silent-downgrade case where the platform
  /// produced an unprotected item.
  bool simulateSilentDowngrade = false;

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
    if (lockedThrowsPlatform.contains(key)) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'interactionNotAllowed',
        details: -25308,
      );
    }
    // The silent-downgrade verification probe: a gated read with the auth UI
    // suppressed. A real enforcing ACL errors here; a downgraded item returns.
    final ui = (iOptions as IOSOptions?)?.authenticationUIBehavior;
    if (ui == 'u_AuthUIF' && !simulateSilentDowngrade) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message: 'interactionNotAllowed',
        details: -25308,
      );
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
    if (key == 'encryption_key_v1') {
      keyWrites.add((key: key, iOptions: iOptions));
    }
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
const _gatedMarker = 'encryption_key_gated_v1';

List<AccessControlFlag>? _flagsOf(AppleOptions? o) =>
    (o as IOSOptions?)?.accessControlFlags;

void main() {
  late _SpyStorage storage;
  late EncryptionKeyManager manager;

  setUp(() {
    storage = _SpyStorage();
    manager = EncryptionKeyManager(storage, _StubBiometrics());
  });

  group('getKey contract', () {
    test('a locked read throws KeyLockedException — never returns null',
        () async {
      await manager.generateKey();
      // Force the next key read to behave like a locked ACL item.
      storage.lockedThrowsPlatform.add(_keyItem);
      // Drop the session cache by making a fresh manager over the same storage.
      final fresh = EncryptionKeyManager(storage, _StubBiometrics());

      await expectLater(
        fresh.getKey(requireBiometric: false),
        throwsA(isA<KeyLockedException>()),
      );
    });

    test('a locked read is NOT cached — a later successful read still works',
        () async {
      await manager.generateKey();
      final key = storage.items[_keyItem];
      final fresh = EncryptionKeyManager(storage, _StubBiometrics());

      storage.lockedThrowsPlatform.add(_keyItem);
      await expectLater(fresh.getKey(requireBiometric: false),
          throwsA(isA<KeyLockedException>()));

      // Unlock: the read succeeds now, and the earlier throw must not have
      // poisoned the cache with a null.
      storage.lockedThrowsPlatform.remove(_keyItem);
      expect(await fresh.getKey(requireBiometric: false), key);
    });

    test('a genuinely absent key returns null (not an exception)', () async {
      expect(await manager.getKey(requireBiometric: false), isNull);
    });

    test('a successful read caches for the session', () async {
      await manager.generateKey();
      final key = storage.items[_keyItem];
      final fresh = EncryptionKeyManager(storage, _StubBiometrics());

      expect(await fresh.getKey(requireBiometric: false), key);
      // Now even a "locked" storage must not be consulted — it's cached.
      storage.lockedThrowsPlatform.add(_keyItem);
      expect(await fresh.getKey(requireBiometric: false), key);
    });
  });

  group('gating marker — no silent downgrade', () {
    test('generateKey writes ungated when no marker is set', () async {
      await manager.generateKey();
      expect(_flagsOf(storage.keyWrites.last.iOptions), isEmpty);
    });

    test('generateKey honours a pre-set gated marker (no downgrade)', () async {
      storage.items[_gatedMarker] = '1';
      await manager.generateKey();
      expect(_flagsOf(storage.keyWrites.last.iOptions),
          contains(AccessControlFlag.userPresence),
          reason: 'a regenerate over a gated install must stay gated');
    });

    test('importKey honours a pre-set gated marker (restore stays gated)',
        () async {
      storage.items[_gatedMarker] = '1';
      await manager.importKey('restored-key');
      expect(_flagsOf(storage.keyWrites.last.iOptions),
          contains(AccessControlFlag.userPresence));
    });

    test('isKeyGated reflects the marker', () async {
      expect(await manager.isKeyGated(), isFalse);
      storage.items[_gatedMarker] = '1';
      expect(await manager.isKeyGated(), isTrue);
    });

    test('deleteKey removes the gating marker too', () async {
      storage.items[_gatedMarker] = '1';
      await manager.generateKey();
      await manager.deleteKey();
      expect(storage.items.containsKey(_gatedMarker), isFalse);
      expect(await manager.isKeyGated(), isFalse);
    });
  });

  // The lockout-critical path: setKeyGated must commit ONLY when both the ACL
  // attached (-25308 probe) AND the unlock round-trip can read the key back;
  // otherwise it rolls the key back to ungated and never sets the marker.
  // setKeyGated is iOS-gated, so pretend to be iOS for these.
  group('setKeyGated atomicity (iOS)', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    List<AccessControlFlag>? lastKeyWriteFlags() =>
        _flagsOf(storage.keyWrites.last.iOptions);

    test('commits gated when ACL enforces AND round-trip reads back', () async {
      await manager.generateKey();
      final key = storage.items[_keyItem];

      await manager.setKeyGated(true, verifyReadBack: (k) async => k == key);

      expect(await manager.isKeyGated(), isTrue);
      expect(lastKeyWriteFlags(), contains(AccessControlFlag.userPresence),
          reason: 'the committed key must carry the ACL');
    });

    test('rolls back (ungated, no marker, throws) on silent downgrade',
        () async {
      await manager.generateKey();
      storage.simulateSilentDowngrade = true; // probe returns value = no ACL

      await expectLater(
        manager.setKeyGated(true, verifyReadBack: (_) async => true),
        throwsA(isA<KeyGatingUnavailableException>()),
      );
      expect(await manager.isKeyGated(), isFalse,
          reason: 'marker must not be set when the ACL did not attach');
      expect(lastKeyWriteFlags(), isEmpty,
          reason: 'the key must be rewritten ungated on rollback');
    });

    test('rolls back when the unlock round-trip cannot read the key back',
        () async {
      await manager.generateKey();

      await expectLater(
        manager.setKeyGated(true, verifyReadBack: (_) async => false),
        throwsA(isA<KeyGatingUnavailableException>()),
      );
      expect(await manager.isKeyGated(), isFalse);
      expect(lastKeyWriteFlags(), isEmpty,
          reason: 'a failed round-trip must leave the key ungated, not '
              'gated-but-unreadable (lockout)');
    });

    test('rolls back when the round-trip THROWS (e.g. user cancels)', () async {
      await manager.generateKey();

      await expectLater(
        manager.setKeyGated(true,
            verifyReadBack: (_) async => throw const KeyLockedException()),
        throwsA(isA<KeyGatingUnavailableException>()),
      );
      expect(await manager.isKeyGated(), isFalse);
      expect(lastKeyWriteFlags(), isEmpty);
    });
  });
}
