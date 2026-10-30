// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-37:
//  S1 — a phone with a PIN but no enrolled fingerprint or face opened the
//       chats and the app lock without any prompt.
//  B3 — on iOS the identity and the chat keys sit in keychain services of
//       their own; the logout's deleteAll() never reached them, and a new
//       account on the same phone published the old identity key.

import 'package:chattr/core/security/biometric_auth_service.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/identity_key_manager.dart';
import 'package:chattr/core/security/passcode_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

import 'support/keychain_storage.dart';

class _LocalAuth extends Fake implements LocalAuthentication {
  _LocalAuth({required this.secured, required this.answer});

  final bool secured;
  final bool answer;
  int prompts = 0;

  @override
  Future<bool> get canCheckBiometrics async => false;

  @override
  Future<bool> isDeviceSupported() async => secured;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => const [];

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<Object> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    prompts++;
    return answer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S1: ohne Fingerabdruck fragt das Gerät nach der PIN', () {
    setUp(BiometricAuthService.resetSession);

    test('PIN gesetzt, abgebrochen: bleibt zu', () async {
      final auth = _LocalAuth(secured: true, answer: false);
      final service = BiometricAuthService(auth: auth);
      expect(await service.authenticate(), isFalse);
      expect(auth.prompts, 1, reason: 'früher öffnete es ohne Abfrage');
    });

    test('PIN gesetzt, richtig: offen', () async {
      final auth = _LocalAuth(secured: true, answer: true);
      expect(await BiometricAuthService(auth: auth).authenticate(), isTrue);
    });

    test('gar keine Bildschirmsperre: nichts zu fragen, offen', () async {
      final auth = _LocalAuth(secured: false, answer: false);
      expect(await BiometricAuthService(auth: auth).authenticate(), isTrue);
      expect(auth.prompts, 0);
    });
  });

  group('B3: Abmelden löscht Identität und Chat-Schlüssel', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('auch in den eigenen Schlüsselbund-Diensten', () async {
      final storage = KeychainStorage();
      final identity = IdentityKeyManager(storage);
      final keys = ChatKeyPairManager(storage);
      final before = await identity.ensureKeyPair();
      await keys.importRestoredKey('chat_pqc_key_c1', '{"xPriv":"a"}');
      await storage.write(key: 'something_else', value: 'stays');

      // What the logout used to do: deleteAll() with default options.
      await storage.deleteAll();
      expect(await identity.publicKeyBase64(), before,
          reason: 'so blieb die Identität bisher liegen');

      await identity.deleteKeyPair();
      await keys.deleteAllKeys();
      expect(await keys.exportAllKeys(), isEmpty);
      expect(await identity.hasKeyPair(), isFalse);
      final after = await identity.ensureKeyPair();
      expect(after, isNot(before), reason: 'ein neues Konto, ein neuer Schlüssel');
    });
  });

  group('Passcode: nach fünf Fehlversuchen wird gewartet', () {
    test('Wartezeiten wachsen und sind gedeckelt', () {
      expect(PasscodeManager.lockoutAfter(4), Duration.zero);
      expect(PasscodeManager.lockoutAfter(5), const Duration(seconds: 30));
      expect(PasscodeManager.lockoutAfter(6), const Duration(seconds: 60));
      expect(PasscodeManager.lockoutAfter(40), const Duration(hours: 1));
    });

    test('gesperrt hilft auch der richtige Code nicht, danach schon',
        () async {
      FlutterSecureStorage.setMockInitialValues({});
      final pm = PasscodeManager(const FlutterSecureStorage());
      await pm.setPasscode('2468');
      final t0 = DateTime.utc(2026, 10, 28, 22);
      for (var i = 0; i < 5; i++) {
        expect(await pm.verifyPasscode('0000', now: t0), isFalse);
      }
      expect(await pm.lockoutRemaining(t0), const Duration(seconds: 30));
      expect(await pm.verifyPasscode('2468', now: t0), isFalse,
          reason: 'während der Sperre wird gar nicht geprüft');
      final later = t0.add(const Duration(seconds: 31));
      expect(await pm.verifyPasscode('2468', now: later), isTrue);
      expect(await pm.lockoutRemaining(later), Duration.zero);
      // Reset: the next miss starts the count again.
      expect(await pm.verifyPasscode('0000', now: later), isFalse);
      expect(await pm.lockoutRemaining(later), Duration.zero);
    });
  });
}
