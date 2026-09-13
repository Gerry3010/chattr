// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Envelope v6 — the version a shot demands (1.27).
//
// v6 changes NOTHING on the wire: the same hybrid wrapping, the same AAD
// binding, the same signature. The number is a condition on the READER
// ("whoever opens this must understand that it only goes once"), and that is
// exactly why it must not travel as an unknown field: an unknown field is
// ignored — and a client that ignores the once-only rule breaks it.
//
// Needs the native library — otherwise skipped (like envelope_v4_test).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/crypto/envelope_version.dart';
import 'package:chattr/core/crypto/message_context.dart';
import 'package:chattr/core/crypto/ml_kem_ffi.dart' show mlKemLibraryPathOverride;
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/kem_key_binding.dart';
import 'package:chattr/core/security/message_encryption_service.dart';

void main() {
  const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
  final libExists = File(libPath).existsSync();
  final skip = libExists ? false : 'native lib not built ($libPath)';

  late ChatKeyPairManager keyManager;
  late MessageEncryptionService service;

  const context = MessageContext(
    chatId: 'chat-shot',
    senderId: 'user-sender',
    messageId: 'msg-shot-1',
  );

  setUpAll(() {
    if (libExists) mlKemLibraryPathOverride = libPath;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    keyManager = ChatKeyPairManager(const FlutterSecureStorage());
    service = MessageEncryptionService(keyManager);
  });

  /// A recipient the version gate considers v4-capable (their KEM key is
  /// identity-signed).
  Future<(String pub, String chatId)> keys(String chatId) async {
    await keyManager.generateKeyPairForChat(chatId);
    final raw = (await keyManager.getPublicKey(chatId))!;
    return (KemKeyBinding.attachSignature(raw, 'v4-capable-sig'), chatId);
  }

  /// An old recipient without a signature — the gate would otherwise send them
  /// v3.
  Future<(String pub, String chatId)> unsignedKeys(String chatId) async {
    await keyManager.generateKeyPairForChat(chatId);
    return ((await keyManager.getPublicKey(chatId))!, chatId);
  }

  test('a shot travels as v6 and opens normally', () async {
    final (pub, chatId) = await keys('chat-v6');
    final enc = await service.encryptForRecipient(
      'shot-body',
      pub,
      context: context,
      signatureB64: 'sig',
    );
    // Gegenprobe: ohne die Anhebung waere es v4.
    expect(jsonDecode(enc)['v'], 4);

    final shot = await service.encryptForAllMembers(
      'shot-body',
      {'r': pub},
      context: context,
      signatureB64: 'sig',
      minEnvelopeVersion: 6,
    );
    expect(jsonDecode(shot['r']!)['v'], 6);

    final priv = (await keyManager.getPrivateKey(chatId))!;
    final env =
        await service.decryptEnvelope(shot['r']!, priv, context: context);
    expect(env.plaintext, 'shot-body');
    expect(env.version, 6);
    expect(env.signatureB64, 'sig',
        reason: 'the signature travels along as it does with v4/v5');
  }, skip: skip);

  test('an old recipient gets v6 too — never the v3 fallback', () async {
    // THIS is the point. If the sender fell back to v3 for an old client, that
    // client could read the body — and a client that does not know shots
    // displays the envelope as raw text, path and media key included. Better a
    // card saying "newer app version needed".
    final (pub, _) = await unsignedKeys('chat-v6-alt');
    final out = await service.encryptForAllMembers(
      'shot-body',
      {'alt': pub},
      context: context,
      signatureB64: 'sig',
      minEnvelopeVersion: 6,
    );
    expect(jsonDecode(out['alt']!)['v'], 6);
  }, skip: skip);

  test('without a raise everything stays as it was', () async {
    final (v4Pub, _) = await keys('chat-unchanged-a');
    final (v3Pub, _) = await unsignedKeys('chat-unchanged-b');
    final out = await service.encryptForAllMembers(
      'gewoehnlich',
      {'neu': v4Pub, 'alt': v3Pub},
      context: context,
      signatureB64: 'sig',
    );
    expect(jsonDecode(out['neu']!)['v'], 4);
    expect(jsonDecode(out['alt']!)['v'], 3);
  }, skip: skip);

  test('a v7 envelope throws the "too new" exception, not just any',
      () async {
    // The chain in `decryptEnvelope` and the set in `EnvelopeVersions` have to
    // move together. If one runs ahead of the bound, messages disappear
    // wordlessly again — the fault 1.25.1 was built against.
    final (pub, chatId) = await keys('chat-v7');
    final enc = await service.encryptForAllMembers(
      'aus der Zukunft',
      {'r': pub},
      context: context,
      signatureB64: 'sig',
      minEnvelopeVersion: 7,
    );
    expect(jsonDecode(enc['r']!)['v'], 7);

    final priv = (await keyManager.getPrivateKey(chatId))!;
    expect(
      () => service.decryptEnvelope(enc['r']!, priv, context: context),
      throwsA(isA<EnvelopeTooNewException>()),
    );
  }, skip: skip);
}
