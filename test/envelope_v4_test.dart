// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Envelope v4 tests (audit H1/M3/H2): identity signatures, AAD context
// binding and hybrid-only downgrade protection.
// Requires the native lib — run `./native/build.sh` first; skips otherwise.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:chattr/core/crypto/ed25519.dart';
import 'package:chattr/core/crypto/message_context.dart';
import 'package:chattr/core/crypto/ml_kem_ffi.dart'
    show mlKemLibraryPathOverride;
import 'package:chattr/core/security/chat_key_pair_manager.dart';
import 'package:chattr/core/security/kem_key_binding.dart';
import 'package:chattr/core/security/message_encryption_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const libPath = 'native/chattr_crypto/build/libchattr_crypto.so';
  final libExists = File(libPath).existsSync();
  final skip = libExists ? false : 'native lib not built ($libPath)';

  late ChatKeyPairManager keyManager;
  late MessageEncryptionService service;

  const context = MessageContext(
    chatId: 'chat-aaaa',
    senderId: 'user-sender',
    messageId: 'msg-0001',
  );

  setUpAll(() {
    if (libExists) mlKemLibraryPathOverride = libPath;
    // Mock secure storage = single namespace → pin platform so the manager's
    // iOS/Android-only legacy sweep doesn't delete the mock's only key.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    keyManager = ChatKeyPairManager(const FlutterSecureStorage());
    service = MessageEncryptionService(keyManager);
  });

  // Returns a recipient key marked v4-capable (identity-signed KEM key) so the
  // per-recipient version gate emits v4. The gate only checks that "s" exists.
  Future<(String pub, String chatId)> keys(String chatId) async {
    await keyManager.generateKeyPairForChat(chatId);
    final raw = (await keyManager.getPublicKey(chatId))!;
    return (KemKeyBinding.attachSignature(raw, 'v4-capable-sig'), chatId);
  }

  // A recipient key WITHOUT a signature — a v3 client, per the gate.
  Future<(String pub, String chatId)> unsignedKeys(String chatId) async {
    await keyManager.generateKeyPairForChat(chatId);
    return ((await keyManager.getPublicKey(chatId))!, chatId);
  }

  group('envelope v4 (context-bound, signed)', () {
    test('round-trips with context + signature', () async {
      final (pub, chatId) = await keys('chat-v4');
      final id = await Ed25519Keys.generate();
      const plaintext = 'signed post-quantum hello';
      final sig = await Ed25519Keys.signBase64(
          id, context.signingBytes(plaintext));

      final enc = await service.encryptForRecipient(plaintext, pub,
          context: context, signatureB64: sig);
      final json = jsonDecode(enc) as Map<String, dynamic>;
      expect(json['v'], 4);
      expect(json['sig'], sig);
      // scheme byte 0x02 leads the wrapped key
      expect(base64.decode(json['ek'] as String)[0],
          MessageEncryptionService.kemSchemeHybrid);

      final priv = (await keyManager.getPrivateKey(chatId))!;
      final env = await service.decryptEnvelope(enc, priv, context: context);
      expect(env.plaintext, plaintext);
      expect(env.version, 4);
      expect(env.signatureB64, sig);

      // the signature verifies under the sender's identity key…
      expect(
        await Ed25519Keys.verifyBase64(
          await Ed25519Keys.publicBase64(id),
          context.signingBytes(env.plaintext),
          env.signatureB64!,
        ),
        isTrue,
      );
      // …and NOT over tampered plaintext.
      expect(
        await Ed25519Keys.verifyBase64(
          await Ed25519Keys.publicBase64(id),
          context.signingBytes('${env.plaintext}!'),
          env.signatureB64!,
        ),
        isFalse,
      );
    }, skip: skip);

    test('v4 without signature decrypts (system-style), sig is null',
        () async {
      final (pub, chatId) = await keys('chat-v4-nosig');
      final enc = await service.encryptForRecipient('system text', pub,
          context: context);
      final priv = (await keyManager.getPrivateKey(chatId))!;
      final env = await service.decryptEnvelope(enc, priv, context: context);
      expect(env.plaintext, 'system text');
      expect(env.signatureB64, isNull);
    }, skip: skip);

    test('AAD binds chat, sender and message id (splice/relabel fails)',
        () async {
      final (pub, chatId) = await keys('chat-aad');
      final enc = await service.encryptForRecipient('bound', pub,
          context: context);
      final priv = (await keyManager.getPrivateKey(chatId))!;

      for (final wrong in [
        const MessageContext(
            chatId: 'chat-OTHER', senderId: 'user-sender', messageId: 'msg-0001'),
        const MessageContext(
            chatId: 'chat-aaaa', senderId: 'user-EVIL', messageId: 'msg-0001'),
        const MessageContext(
            chatId: 'chat-aaaa', senderId: 'user-sender', messageId: 'msg-9999'),
      ]) {
        await expectLater(
          service.decryptEnvelope(enc, priv, context: wrong),
          throwsA(anything),
        );
      }
      // correct context still works
      expect(
        (await service.decryptEnvelope(enc, priv, context: context)).plaintext,
        'bound',
      );
    }, skip: skip);

    test('v4 requires a context on decrypt', () async {
      final (pub, chatId) = await keys('chat-needs-ctx');
      final enc = await service.encryptForRecipient('x', pub, context: context);
      final priv = (await keyManager.getPrivateKey(chatId))!;
      await expectLater(
        service.decryptEnvelope(enc, priv),
        throwsA(anything),
      );
    }, skip: skip);

    test('downgrade protection: non-hybrid or truncated ek is rejected',
        () async {
      final (pub, chatId) = await keys('chat-downgrade');
      final enc = await service.encryptForRecipient('no downgrade', pub,
          context: context);
      final priv = (await keyManager.getPrivateKey(chatId))!;
      final json = jsonDecode(enc) as Map<String, dynamic>;
      final ek = base64.decode(json['ek'] as String);

      // unknown scheme byte
      final wrongScheme = Uint8List.fromList([0x01, ...ek.sublist(1)]);
      // scheme byte kept but body truncated to X25519-only length — the
      // underlying KEM would silently fall back; the envelope must reject.
      final truncated =
          Uint8List.fromList([ek[0], ...ek.sublist(1, 1 + 32 + 28)]);

      for (final evil in [wrongScheme, truncated]) {
        final tampered = jsonEncode({
          ...json,
          'ek': base64.encode(evil),
        });
        await expectLater(
          service.decryptEnvelope(tampered, priv, context: context),
          throwsA(anything),
        );
      }
    }, skip: skip);
  });

  group('envelope v3 (legacy compatibility)', () {
    test('still encrypts/decrypts without a context', () async {
      final (pub, chatId) = await keys('chat-v3');
      final enc = await service.encryptForRecipient('legacy', pub);
      expect(jsonDecode(enc)['v'], 3);
      final priv = (await keyManager.getPrivateKey(chatId))!;
      // v3 decrypts with AND without a context (context is ignored).
      expect((await service.decryptEnvelope(enc, priv)).plaintext, 'legacy');
      expect(
        (await service.decryptEnvelope(enc, priv, context: context)).plaintext,
        'legacy',
      );
    }, skip: skip);
  });

  group('per-recipient version gate (P0 rollout safety)', () {
    test('unsigned recipient (v3 client) gets v3 even with a context', () async {
      final (pub, chatId) = await unsignedKeys('chat-gate-v3');
      final enc = await service.encryptForRecipient('hi', pub,
          context: context, signatureB64: 'sig');
      expect(jsonDecode(enc)['v'], 3, reason: 'unsigned => v3');
      // and it decrypts as v3 (no context needed)
      final priv = (await keyManager.getPrivateKey(chatId))!;
      expect((await service.decryptEnvelope(enc, priv)).plaintext, 'hi');
    }, skip: skip);

    test('signed recipient (v4 client) gets v4', () async {
      final (pub, _) = await keys('chat-gate-v4');
      final enc = await service.encryptForRecipient('hi', pub,
          context: context, signatureB64: 'sig');
      expect(jsonDecode(enc)['v'], 4, reason: 'signed => v4');
    }, skip: skip);

    test('mixed group: signed→v4, unsigned→v3, each decrypts its own', () async {
      final (v4Pub, v4Chat) = await keys('chat-mix-a');
      final (v3Pub, v3Chat) = await unsignedKeys('chat-mix-b');
      final out = await service.encryptForAllMembers(
        'mixed', {'v4': v4Pub, 'v3': v3Pub},
        context: context, signatureB64: 'sig');
      expect(jsonDecode(out['v4']!)['v'], 4);
      expect(jsonDecode(out['v3']!)['v'], 3);
      // v4 recipient decrypts with the context; v3 recipient without.
      final v4Priv = (await keyManager.getPrivateKey(v4Chat))!;
      final v3Priv = (await keyManager.getPrivateKey(v3Chat))!;
      expect(
        (await service.decryptEnvelope(out['v4']!, v4Priv, context: context))
            .plaintext,
        'mixed',
      );
      expect(
        (await service.decryptEnvelope(out['v3']!, v3Priv)).plaintext,
        'mixed',
      );
    }, skip: skip);
  });

  group('cross-implementation interop (fixture from crypto_port.ts/Node)', () {
    test('decrypts + verifies a v4 envelope produced by the MCP server',
        () async {
      // Fixture generated with mcp_server's crypto_port.js — proves the v4
      // AAD/scheme-byte/signature byte layouts match across implementations.
      final fixture = jsonDecode(
        File('web_crypto/testdata/interop_v4.json').readAsStringSync(),
      ) as Map<String, dynamic>;

      final privBlob = jsonEncode({
        'x': fixture['xPriv'],
        'm': fixture['mPriv'],
      });
      final ctx = MessageContext(
        chatId: fixture['chatId'] as String,
        senderId: fixture['senderId'] as String,
        messageId: fixture['messageId'] as String,
      );

      final env = await service.decryptEnvelope(
        fixture['envelope'] as String,
        privBlob,
        context: ctx,
      );
      expect(env.version, 4);
      expect(env.plaintext, fixture['plaintext']);

      // The Node-made Ed25519 signature verifies in Dart over the same bytes.
      expect(
        await Ed25519Keys.verifyBase64(
          fixture['identityPub'] as String,
          ctx.signingBytes(env.plaintext),
          env.signatureB64!,
        ),
        isTrue,
      );
      // Wrong context must fail (AAD interop, not just happy path).
      await expectLater(
        service.decryptEnvelope(
          fixture['envelope'] as String,
          privBlob,
          context: MessageContext(
            chatId: ctx.chatId,
            senderId: ctx.senderId,
            messageId: 'msg-WRONG',
          ),
        ),
        throwsA(anything),
      );
    }, skip: skip);
  });
}
