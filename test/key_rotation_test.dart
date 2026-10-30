// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Verifies the security-critical part of key rotation (F9): after rotating a
// chat's key pair, a message that was encrypted for the OLD public key (an
// in-flight message a sender produced before learning the new key) must still
// decrypt via the retained previous key, and messages for the NEW key decrypt
// via the current key.
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/ml_kem_ffi.dart'
    show mlKemLibraryPathOverride;
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
  final libExists = File(libPath).existsSync();

  setUpAll(() {
    if (libExists) mlKemLibraryPathOverride = libPath;
    // Mock secure storage is a single namespace (no accountName isolation), so
    // pin a desktop platform — otherwise ChatKeyPairManager's iOS/Android-only
    // legacy sweep would delete the retained previous key this test relies on.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('rotation retains the previous key so in-flight messages still decrypt',
      () async {
    if (!libExists) {
      markTestSkipped('native crypto lib not built ($libPath)');
      return;
    }
    const storage = FlutterSecureStorage();
    final keyManager = ChatKeyPairManager(storage);
    final enc = MessageEncryptionService(keyManager);
    const chatId = 'chat-rotate-test';

    await keyManager.generateKeyPairForChat(chatId);
    final oldPub = (await keyManager.getPublicKey(chatId))!;

    // A sender encrypts for the CURRENT (soon-to-be-old) public key.
    final cipherForOld = await enc.encryptForRecipient('before rotation', oldPub);

    // Rotate: old key becomes the retained previous, a fresh current is made.
    final newPub = (await keyManager.rotateKeyPairForChat(chatId))!;
    expect(newPub, isNot(oldPub), reason: 'rotation must change the key');

    // A sender who learned the new key encrypts for it.
    final cipherForNew = await enc.encryptForRecipient('after rotation', newPub);

    final keys = await keyManager.getAllPrivateKeys(chatId);
    expect(keys.length, 2, reason: 'current + previous after one rotation');

    // Both messages decrypt: the old via the previous key, the new via current.
    expect(
      await enc.decryptMessageTryKeys(cipherForOld, keys),
      'before rotation',
      reason: 'in-flight message for the old key must survive rotation',
    );
    expect(
      await enc.decryptMessageTryKeys(cipherForNew, keys),
      'after rotation',
    );
  });

  test('a second rotation drops the oldest key (only one previous kept)',
      () async {
    if (!libExists) {
      markTestSkipped('native crypto lib not built ($libPath)');
      return;
    }
    const storage = FlutterSecureStorage();
    final keyManager = ChatKeyPairManager(storage);
    final enc = MessageEncryptionService(keyManager);
    const chatId = 'chat-rotate-twice';

    await keyManager.generateKeyPairForChat(chatId);
    final gen1Pub = (await keyManager.getPublicKey(chatId))!;
    final cipherGen1 = await enc.encryptForRecipient('generation 1', gen1Pub);

    await keyManager.rotateKeyPairForChat(chatId); // gen1 -> previous
    await keyManager.rotateKeyPairForChat(chatId); // gen1 dropped, gen2 -> previous

    final keys = await keyManager.getAllPrivateKeys(chatId);
    expect(keys.length, 2);
    // gen1 is now two generations back and no longer decryptable.
    expect(
      () => enc.decryptMessageTryKeys(cipherGen1, keys),
      throwsA(isA<Exception>()),
    );
  });
}
