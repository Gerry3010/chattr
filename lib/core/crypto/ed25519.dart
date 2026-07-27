// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Ed25519 sign / verify / keygen primitives, shared by the recovery-phrase
/// feature ([RecoveryCrypto]) and the long-term identity key
/// ([IdentityKeyManager]).
///
/// This module deliberately holds ONLY the crypto primitives — no key storage,
/// no network, no I/O — so it stays fully unit-testable and its two consumers
/// keep their key *semantics* strictly separate (the recovery key is an
/// account-takeover credential; the identity key signs routine messages). Only
/// the primitives are shared, never the keys.
///
/// Wire compatibility: the server verifies signatures produced here with Deno
/// WebCrypto `crypto.subtle` `"Ed25519"` (see supabase/functions/*), and the
/// per-chat key-blob signatures are verified by peers with this same code.
class Ed25519Keys {
  static final Ed25519 _algo = Ed25519();

  /// The shared algorithm instance (for callers that already hold a
  /// [SimpleKeyPair], e.g. a BIP39-derived recovery keypair).
  static Ed25519 get algorithm => _algo;

  /// A fresh random keypair.
  static Future<SimpleKeyPair> generate() => _algo.newKeyPair();

  /// Reconstruct a keypair from its 32-byte private seed.
  static Future<SimpleKeyPair> fromSeed(List<int> seed) =>
      _algo.newKeyPairFromSeed(seed);

  /// The 32-byte Ed25519 private seed — the value to persist.
  static Future<Uint8List> privateSeed(SimpleKeyPair kp) async =>
      Uint8List.fromList(await kp.extractPrivateKeyBytes());

  /// The 32-byte public key.
  static Future<Uint8List> publicBytes(SimpleKeyPair kp) async =>
      Uint8List.fromList((await kp.extractPublicKey()).bytes);

  /// Standard-base64 of the public key.
  static Future<String> publicBase64(SimpleKeyPair kp) async =>
      base64.encode(await publicBytes(kp));

  /// Sign [message] bytes; returns the raw 64-byte signature.
  static Future<Uint8List> sign(SimpleKeyPair kp, List<int> message) async {
    final sig = await _algo.sign(message, keyPair: kp);
    return Uint8List.fromList(sig.bytes);
  }

  /// Sign [message] bytes; returns a standard-base64 signature.
  static Future<String> signBase64(SimpleKeyPair kp, List<int> message) async =>
      base64.encode(await sign(kp, message));

  /// Verify a raw signature against a raw 32-byte public key.
  static Future<bool> verify(
    List<int> publicKey,
    List<int> message,
    List<int> signature,
  ) async {
    final pk = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
    return _algo.verify(message, signature: Signature(signature, publicKey: pk));
  }

  /// Verify a base64 public key + base64 signature over [message]. Any
  /// malformed input fails closed (returns false) rather than throwing.
  static Future<bool> verifyBase64(
    String publicKeyB64,
    List<int> message,
    String signatureB64,
  ) async {
    try {
      return await verify(
        base64.decode(publicKeyB64),
        message,
        base64.decode(signatureB64),
      );
    } catch (_) {
      return false;
    }
  }
}
