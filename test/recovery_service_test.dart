// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Crypto tests for the recovery-phrase derivation (RecoveryCrypto). The Ed25519
// keypair MUST be (a) deterministic — same 24-word phrase → same public key on
// any device — and (b) interoperable with the server's verifier (Deno
// crypto.subtle Ed25519 in supabase/functions/recover-identity). The VECTOR
// test prints a fixed phrase → public_key + signature triple that a cross-check
// script feeds to that same verifier (scratchpad/verify_recovery_vector.mjs).

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/recovery/recovery_service.dart';

void main() {
  // A valid 24-word BIP39 mnemonic (test vector — NOT a real account).
  const fixedPhrase =
      'legal winner thank year wave sausage worth useful legal winner thank '
      'year wave sausage worth useful legal winner thank year wave sausage '
      'worth title';

  test('generateMnemonic yields a valid 24-word phrase', () {
    final m = RecoveryCrypto.generateMnemonic();
    expect(m.split(' ').length, 24);
    expect(RecoveryCrypto.validateMnemonic(m), isTrue);
  });

  test('validateMnemonic rejects garbage, accepts the fixed vector', () {
    expect(RecoveryCrypto.validateMnemonic('not a real phrase at all'), isFalse);
    expect(RecoveryCrypto.validateMnemonic(fixedPhrase), isTrue);
  });

  test('derivation is deterministic (same phrase → same public key)', () async {
    final a = await RecoveryCrypto.publicKeyFor(fixedPhrase);
    final b = await RecoveryCrypto.publicKeyFor(fixedPhrase);
    expect(a, b);
    expect(base64.decode(a).length, 32); // 32-byte Ed25519 public key
  });

  test('whitespace/case do not change the derived key', () async {
    final a = await RecoveryCrypto.publicKeyFor(fixedPhrase);
    final messy = '  ${fixedPhrase.toUpperCase().replaceAll(' ', '   ')}  ';
    final b = await RecoveryCrypto.publicKeyFor(messy);
    expect(a, b);
  });

  test('different phrases → different keys', () async {
    final other = RecoveryCrypto.generateMnemonic();
    expect(await RecoveryCrypto.publicKeyFor(fixedPhrase),
        isNot(await RecoveryCrypto.publicKeyFor(other)));
  });

  test('VECTOR: Dart-signed challenge self-verifies + emitted for cross-check',
      () async {
    final kp = await RecoveryCrypto.deriveKeyPair(fixedPhrase);
    final pubB64 = await RecoveryCrypto.publicKeyFor(fixedPhrase);
    const challenge = 'Y2hhbGxlbmdlLXRlc3QtdmVjdG9yLTEyMzQ1Njc4OTA=';
    final sigB64 = await RecoveryCrypto.signChallenge(kp, challenge);

    // Self-verify in Dart.
    final pub = await kp.extractPublicKey();
    final ok = await RecoveryCrypto.ed25519.verify(
      utf8.encode(challenge),
      signature: Signature(base64.decode(sigB64), publicKey: pub),
    );
    expect(ok, isTrue);
    expect(base64.encode(pub.bytes), pubB64);
    expect(base64.decode(sigB64).length, 64);

    // ignore: avoid_print
    print('RECOVERY_VECTOR ${jsonEncode({
          'public_key': pubB64,
          'challenge': challenge,
          'signature': sigB64,
        })}');
  });
}
