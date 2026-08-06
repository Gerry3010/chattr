// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Post-quantum hybrid (X25519 + ML-KEM-768) message encryption tests.
// Requires the native lib — run `./native/build.sh` first; skips otherwise.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:chattr/core/crypto/ml_kem_ffi.dart' show mlKemLibraryPathOverride;

void main() {
  const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
  final libExists = File(libPath).existsSync();
  final skip = libExists ? false : 'native lib not built ($libPath)';

  late FlutterSecureStorage secureStorage;
  late ChatKeyPairManager keyManager;
  late MessageEncryptionService encryptionService;

  setUpAll(() {
    if (libExists) mlKemLibraryPathOverride = libPath;
    // The mock secure storage has no accountName namespaces (single map), so it
    // behaves like a desktop backend — pin the platform so ChatKeyPairManager
    // doesn't run its iOS/Android-only legacy sweep against it.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    secureStorage = const FlutterSecureStorage();
    keyManager = ChatKeyPairManager(secureStorage);
    encryptionService = MessageEncryptionService(keyManager);
  });

  group('ChatKeyPairManager (hybrid)', () {
    test('generates and stores a hybrid key pair', () async {
      const chatId = 'chat-1';
      await keyManager.generateKeyPairForChat(chatId);

      expect(await keyManager.hasKeyPair(chatId), isTrue);

      final pub = jsonDecode((await keyManager.getPublicKey(chatId))!)
          as Map<String, dynamic>;
      final priv = jsonDecode((await keyManager.getPrivateKey(chatId))!)
          as Map<String, dynamic>;

      // X25519 (32-byte) + ML-KEM-768 (pub 1184, priv 2400) sizes.
      expect(base64.decode(pub['x'] as String).length, 32);
      expect(base64.decode(pub['m'] as String).length, 1184);
      expect(base64.decode(priv['x'] as String).length, 32);
      expect(base64.decode(priv['m'] as String).length, 2400);
    }, skip: skip);

    test('deletes a key pair', () async {
      const chatId = 'chat-2';
      await keyManager.generateKeyPairForChat(chatId);
      expect(await keyManager.hasKeyPair(chatId), isTrue);
      await keyManager.deleteKeyPair(chatId);
      expect(await keyManager.hasKeyPair(chatId), isFalse);
    }, skip: skip);
  });

  group('MessageEncryptionService (hybrid)', () {
    Future<String> pubFor(String chatId) async {
      await keyManager.generateKeyPairForChat(chatId);
      return (await keyManager.getPublicKey(chatId))!;
    }

    test('encrypts and decrypts for a single recipient', () async {
      const chatId = 'chat-single';
      final pub = await pubFor(chatId);
      const plaintext = 'Hello, post-quantum world!';

      final enc = await encryptionService.encryptForRecipient(plaintext, pub);
      expect(enc, isNot(equals(plaintext)));
      expect(jsonDecode(enc)['v'], 3);

      final dec = await encryptionService.decryptMessageForChat(enc, chatId);
      expect(dec, equals(plaintext));
    }, skip: skip);

    test('encrypts for multiple recipients; each decrypts its own', () async {
      const plaintext = 'group message';
      final memberKeys = <String, String>{};
      for (var i = 1; i <= 3; i++) {
        memberKeys['user-$i'] = await pubFor('chat-for-user-$i');
      }

      final encrypted =
          await encryptionService.encryptForAllMembers(plaintext, memberKeys);
      expect(encrypted.length, 3);
      // Per-recipient wrapped key differs; shared message ciphertext is reused.
      expect(jsonDecode(encrypted['user-1']!)['ek'],
          isNot(equals(jsonDecode(encrypted['user-2']!)['ek'])));
      expect(jsonDecode(encrypted['user-1']!)['msg'],
          equals(jsonDecode(encrypted['user-2']!)['msg']));

      for (var i = 1; i <= 3; i++) {
        final dec = await encryptionService.decryptMessageForChat(
            encrypted['user-$i']!, 'chat-for-user-$i');
        expect(dec, equals(plaintext));
      }
    }, skip: skip);

    test('fails to decrypt with the wrong key pair', () async {
      final pub = await pubFor('chat-a');
      await keyManager.generateKeyPairForChat('chat-b');
      final enc = await encryptionService.encryptForRecipient('secret', pub);

      expect(
        () => encryptionService.decryptMessageForChat(enc, 'chat-b'),
        throwsA(isA<Object>()),
      );
    }, skip: skip);

    test('handles long messages, emojis and empty strings', () async {
      const chatId = 'chat-edge';
      final pub = await pubFor(chatId);
      for (final plaintext in ['A' * 5000, '🔐🎉 emojis ünîçödé', '']) {
        final enc = await encryptionService.encryptForRecipient(plaintext, pub);
        final dec = await encryptionService.decryptMessageForChat(enc, chatId);
        expect(dec, equals(plaintext));
      }
    }, skip: skip);
  });
}
