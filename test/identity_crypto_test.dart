// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:chattr/core/crypto/ed25519.dart';
import 'package:chattr/core/security/kem_key_binding.dart';
import 'package:chattr/features/identity/safety_number.dart';
import 'package:flutter_test/flutter_test.dart';

// Fabricate a plausible per-chat public-key blob ({"x":..,"m":..}) with random
// bytes — the binding layer never cares about the KEM key's validity, only that
// the identity key signs over the exact bytes.
String fakePublicBlob() {
  final x = Uint8List.fromList(List<int>.generate(32, (i) => i & 0xff));
  final m = Uint8List.fromList(List<int>.generate(1184, (i) => (i * 7) & 0xff));
  return jsonEncode({'x': base64.encode(x), 'm': base64.encode(m)});
}

void main() {
  group('Ed25519Keys primitives', () {
    test('sign/verify round-trips; tamper + wrong key fail', () async {
      final kp = await Ed25519Keys.generate();
      final pub = await Ed25519Keys.publicBase64(kp);
      final msg = utf8.encode('the quick brown fox');

      final sig = await Ed25519Keys.signBase64(kp, msg);
      expect(await Ed25519Keys.verifyBase64(pub, msg, sig), isTrue);

      // tampered message
      expect(
        await Ed25519Keys.verifyBase64(pub, utf8.encode('the quick brown FOX'), sig),
        isFalse,
      );
      // wrong signer
      final other = await Ed25519Keys.generate();
      final otherPub = await Ed25519Keys.publicBase64(other);
      expect(await Ed25519Keys.verifyBase64(otherPub, msg, sig), isFalse);
    });

    test('malformed base64 fails closed (no throw)', () async {
      expect(await Ed25519Keys.verifyBase64('!!not b64!!', [1, 2, 3], 'zzz'),
          isFalse);
    });

    test('seed round-trips to the same keypair', () async {
      final kp = await Ed25519Keys.generate();
      final seed = await Ed25519Keys.privateSeed(kp);
      final restored = await Ed25519Keys.fromSeed(seed);
      expect(await Ed25519Keys.publicBase64(restored),
          await Ed25519Keys.publicBase64(kp));
      // signatures from the restored key verify under the original public key.
      final msg = utf8.encode('persisted then reloaded');
      final sig = await Ed25519Keys.signBase64(restored, msg);
      expect(
        await Ed25519Keys.verifyBase64(await Ed25519Keys.publicBase64(kp), msg, sig),
        isTrue,
      );
    });
  });

  group('KemKeyBinding (C1: identity vouches for the per-chat KEM key)', () {
    const chatId = 'chat-aaaa-1111';

    test('attach + verify round-trips for the right chat + identity', () async {
      final id = await Ed25519Keys.generate();
      final idPub = await Ed25519Keys.publicBase64(id);
      final blob = fakePublicBlob();

      final sig = await Ed25519Keys.signBase64(
          id, KemKeyBinding.bindingMessage(chatId, blob));
      final signed = KemKeyBinding.attachSignature(blob, sig);

      expect(await KemKeyBinding.verify(chatId, signed, idPub), isTrue);
    });

    test('unsigned blob fails closed', () async {
      final id = await Ed25519Keys.generate();
      final idPub = await Ed25519Keys.publicBase64(id);
      expect(await KemKeyBinding.verify(chatId, fakePublicBlob(), idPub), isFalse);
    });

    test('a different identity (server MITM swap) does NOT verify', () async {
      final real = await Ed25519Keys.generate();
      final attacker = await Ed25519Keys.generate();
      final blob = fakePublicBlob();
      // attacker signs the blob with ITS key…
      final sig = await Ed25519Keys.signBase64(
          attacker, KemKeyBinding.bindingMessage(chatId, blob));
      final signed = KemKeyBinding.attachSignature(blob, sig);
      // …but the peer pinned the REAL identity → verification fails.
      final realPub = await Ed25519Keys.publicBase64(real);
      expect(await KemKeyBinding.verify(chatId, signed, realPub), isFalse);
    });

    test('signature is bound to chatId (cross-chat replay fails)', () async {
      final id = await Ed25519Keys.generate();
      final idPub = await Ed25519Keys.publicBase64(id);
      final blob = fakePublicBlob();
      final sig = await Ed25519Keys.signBase64(
          id, KemKeyBinding.bindingMessage('chat-ONE', blob));
      final signed = KemKeyBinding.attachSignature(blob, sig);
      // valid in its own chat…
      expect(await KemKeyBinding.verify('chat-ONE', signed, idPub), isTrue);
      // …but not when replayed into another chat.
      expect(await KemKeyBinding.verify('chat-TWO', signed, idPub), isFalse);
    });

    test('tampered KEM key bytes invalidate the signature', () async {
      final id = await Ed25519Keys.generate();
      final idPub = await Ed25519Keys.publicBase64(id);
      final blob = fakePublicBlob();
      final sig = await Ed25519Keys.signBase64(
          id, KemKeyBinding.bindingMessage(chatId, blob));
      // keep the signature but swap the KEM key underneath it.
      final tampered = KemKeyBinding.attachSignature(fakePublicBlob2(), sig);
      expect(await KemKeyBinding.verify(chatId, tampered, idPub), isFalse);
    });
  });

  group('SafetyNumber', () {
    Future<String> pub() async =>
        Ed25519Keys.publicBase64(await Ed25519Keys.generate());

    test('is 60 digits, deterministic, and order-independent', () async {
      final a = await pub();
      final b = await pub();

      final ab = SafetyNumber.compute(a, b);
      expect(ab.length, 60);
      expect(RegExp(r'^\d{60}$').hasMatch(ab), isTrue);

      // same inputs → same number; swapping the order → same number.
      expect(SafetyNumber.compute(a, b), ab);
      expect(SafetyNumber.compute(b, a), ab);
    });

    test('different key pairs yield different numbers', () async {
      final a = await pub();
      final b = await pub();
      final c = await pub();
      expect(SafetyNumber.compute(a, b) == SafetyNumber.compute(a, c), isFalse);
    });

    test('formatted() is twelve space-separated 5-digit groups', () async {
      final f = SafetyNumber.formatted(await pub(), await pub());
      final groups = f.split(' ');
      expect(groups.length, 12);
      expect(groups.every((g) => RegExp(r'^\d{5}$').hasMatch(g)), isTrue);
    });
  });
}

// A second distinct blob for the tamper test.
String fakePublicBlob2() {
  final x = Uint8List.fromList(List<int>.generate(32, (i) => (i + 1) & 0xff));
  final m = Uint8List.fromList(List<int>.generate(1184, (i) => (i * 11) & 0xff));
  return jsonEncode({'x': base64.encode(x), 'm': base64.encode(m)});
}
