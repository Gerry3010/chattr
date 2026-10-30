// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Unit tests for the app lock: passcode hashing/verification and the
// lock/unlock state machine (enable, cold-start lock, background lock,
// passcode unlock, no-method safety hatch).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/encryption_key_manager.dart';
import 'package:chattr/core/security/passcode_manager.dart';
import 'package:chattr/features/app_lock/app_lock_controller.dart';

class _NoBiometrics extends BiometricAuthService {
  @override
  Future<bool> isAvailable() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    BiometricAuthService.resetSession();
  });

  group('PasscodeManager', () {
    test('set → verify roundtrip; wrong code rejected', () async {
      final manager = PasscodeManager(const FlutterSecureStorage());
      expect(await manager.hasPasscode(), isFalse);

      await manager.setPasscode('1234');
      expect(await manager.hasPasscode(), isTrue);
      expect(await manager.verifyPasscode('1234'), isTrue);
      expect(await manager.verifyPasscode('4321'), isFalse);
      expect(await manager.verifyPasscode(''), isFalse);

      await manager.removePasscode();
      expect(await manager.hasPasscode(), isFalse);
      expect(await manager.verifyPasscode('1234'), isFalse);
    });

    test('same passcode hashes differently per salt', () async {
      const storage = FlutterSecureStorage();
      final manager = PasscodeManager(storage);
      await manager.setPasscode('0000');
      final hash1 = await storage.read(key: 'app_lock_passcode_hash_v1');
      await manager.setPasscode('0000');
      final hash2 = await storage.read(key: 'app_lock_passcode_hash_v1');
      expect(hash1, isNot(hash2));
    });
  });

  group('AppLockController', () {
    AppLockController build() {
      const storage = FlutterSecureStorage();
      final biometrics = _NoBiometrics();
      return AppLockController(
        storage,
        PasscodeManager(storage),
        biometrics,
        EncryptionKeyManager(storage, biometrics),
      );
    }

    test('setPasscode rejects codes shorter than 4 digits', () async {
      final controller = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(controller.setPasscode('123'), throwsArgumentError);
      expect(controller.state.hasPasscode, isFalse);
      await controller.setPasscode('1234');
      expect(controller.state.hasPasscode, isTrue);
    });

    test('Datentor: sperrt auch ohne App-Sperre, meldet das Entsperren einmal',
        () async {
      final controller = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state.enabled, isFalse);

      var unlocked = 0;
      controller.waitForUnlock(() => unlocked++);
      expect(controller.state.locked, isTrue);

      await controller.setPasscode('1234');
      expect(await controller.unlockWithPasscode('1234'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.locked, isFalse);
      expect(unlocked, 1);

      controller.requireUnlock();
      controller.releaseGateLock();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.locked, isFalse);
      expect(unlocked, 1, reason: 'der Rückruf gilt nur für ein Entsperren');
    });

    test('Datentor: eine Sperre vor dem Laden der Einstellung bleibt stehen',
        () async {
      final controller = build();
      controller.requireUnlock();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state.locked, isTrue,
          reason: '_init darf die Sperre nicht mit „App-Sperre aus“ überschreiben');
    });

    test('disabled by default; lock() is a no-op', () async {
      final controller = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.state.enabled, isFalse);
      expect(controller.state.locked, isFalse);

      controller.lock();
      expect(controller.state.locked, isFalse);
    });

    test('enabled: background lock + passcode unlock', () async {
      final controller = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await controller.setPasscode('1234');
      await controller.setEnabled(true);
      expect(controller.state.locked, isFalse);

      controller.lock();
      expect(controller.state.locked, isTrue);

      expect(await controller.unlockWithPasscode('9999'), isFalse);
      expect(controller.state.locked, isTrue);

      expect(await controller.unlockWithPasscode('1234'), isTrue);
      expect(controller.state.locked, isFalse);
    });

    test('cold start with lock enabled starts locked', () async {
      final first = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await first.setPasscode('1234');
      await first.setEnabled(true);

      final second = build(); // fresh start, same storage
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(second.state.enabled, isTrue);
      expect(second.state.locked, isTrue);
    });

    test('removing the passcode without biometrics disables the lock',
        () async {
      final controller = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await controller.setPasscode('1234');
      await controller.setEnabled(true);

      await controller.removePasscode();
      expect(controller.state.hasPasscode, isFalse);
      expect(controller.state.enabled, isFalse,
          reason: 'no unlock method would remain');
    });

    test('safety hatch releases a lock with no unlock method', () async {
      final controller = build();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await controller.setPasscode('1234');
      await controller.setEnabled(true);
      controller.lock();

      // Simulate: passcode vanished (e.g. storage restored partially).
      await PasscodeManager(const FlutterSecureStorage()).removePasscode();
      controller.state = controller.state.copyWith(hasPasscode: false);

      controller.forceUnlockWithoutMethod();
      expect(controller.state.locked, isFalse);
    });
  });
}
