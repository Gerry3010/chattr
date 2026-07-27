// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';

/// Pure crypto for the recovery-phrase feature — no I/O, so it's fully
/// unit-testable (see test/recovery_service_test.dart). A 24-word BIP39
/// mnemonic deterministically derives an Ed25519 keypair; the same phrase
/// yields the same keypair on any device. The derivation is versioned via the
/// HKDF `info` label so it can evolve without breaking enrolled phrases. The
/// server (Deno crypto.subtle Ed25519, supabase/functions/recover-identity)
/// verifies signatures produced here.
class RecoveryCrypto {
  /// 256-bit entropy → 24 words.
  static const int entropyBits = 256;
  static const String hkdfInfo = 'chattr-recovery-auth-v1';

  static final Ed25519 ed25519 = Ed25519();

  static String generateMnemonic() => bip39.generateMnemonic(strength: entropyBits);

  static bool validateMnemonic(String mnemonic) =>
      bip39.validateMnemonic(normalize(mnemonic));

  static String normalize(String mnemonic) =>
      mnemonic.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

  /// Same phrase → same keypair.
  static Future<SimpleKeyPair> deriveKeyPair(String mnemonic) async {
    final seed = bip39.mnemonicToSeed(normalize(mnemonic)); // 64 bytes
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(seed),
      info: utf8.encode(hkdfInfo),
    );
    final seed32 = await derived.extractBytes();
    return ed25519.newKeyPairFromSeed(seed32);
  }

  /// Base64 (standard) Ed25519 public key for a mnemonic.
  static Future<String> publicKeyFor(String mnemonic) async {
    final pub = await (await deriveKeyPair(mnemonic)).extractPublicKey();
    return base64.encode(pub.bytes);
  }

  /// Sign a (base64) challenge string over its UTF-8 bytes; returns base64 sig.
  static Future<String> signChallenge(SimpleKeyPair kp, String challenge) async {
    final sig = await ed25519.sign(utf8.encode(challenge), keyPair: kp);
    return base64.encode(sig.bytes);
  }
}

/// Networked recovery flow: enrollment (needs a session) and recovery (no
/// session yet) via the enroll-recovery / recover-identity edge functions.
class RecoveryService {
  final SupabaseClient _client;
  final FlutterSecureStorage _storage;
  RecoveryService(this._client, this._storage);

  /// Local marker that this account has a recovery phrase set up. Set on enroll
  /// AND on a successful recover, so a recovered device also reports "enabled"
  /// and can warn before overwriting the phrase. (A restore via the Phase-1
  /// backup file won't set this — a `recovery-status` edge function would be the
  /// server-truth follow-up.)
  static const String _enrolledKey = 'recovery_enrolled_v1';

  String generateMnemonic() => RecoveryCrypto.generateMnemonic();
  bool validateMnemonic(String mnemonic) => RecoveryCrypto.validateMnemonic(mnemonic);

  Future<bool> isEnrolled() async =>
      (await _storage.read(key: _enrolledKey)) == 'true';

  Future<void> markEnrolled() async =>
      _storage.write(key: _enrolledKey, value: 'true');

  /// Enroll this device's recovery public key (requires an active session).
  /// Overwrites any previous enrollment server-side — callers should confirm
  /// with the user first if [isEnrolled] is already true.
  Future<void> enroll(String mnemonic) async {
    final publicKey = await RecoveryCrypto.publicKeyFor(mnemonic);
    final res = await _client.functions.invoke(
      'enroll-recovery',
      body: {'public_key': publicKey},
    );
    if (res.status != 200) {
      throw RecoveryException('enroll failed (HTTP ${res.status})');
    }
    await markEnrolled();
  }

  /// Recover the identity from a mnemonic on a device with no session: challenge
  /// → sign → verify → redeem token. Leaves the client authenticated as the
  /// original user; returns that user id.
  Future<String> recover(String mnemonic) async {
    if (!RecoveryCrypto.validateMnemonic(mnemonic)) {
      throw RecoveryException('Invalid recovery phrase.');
    }
    final kp = await RecoveryCrypto.deriveKeyPair(mnemonic);
    final publicKey = base64.encode((await kp.extractPublicKey()).bytes);

    final challengeRes = await _client.functions.invoke(
      'recover-identity',
      body: {'action': 'challenge', 'public_key': publicKey},
    );
    if (challengeRes.status != 200) {
      throw RecoveryException('recovery challenge failed (HTTP ${challengeRes.status})');
    }
    final challenge = (challengeRes.data as Map)['challenge'] as String;

    final signatureB64 = await RecoveryCrypto.signChallenge(kp, challenge);

    final verifyRes = await _client.functions.invoke(
      'recover-identity',
      body: {
        'action': 'verify',
        'public_key': publicKey,
        'challenge': challenge,
        'signature': signatureB64,
      },
    );
    if (verifyRes.status != 200) {
      throw RecoveryException('This phrase is not enrolled or the challenge expired.');
    }
    final tokenHash = (verifyRes.data as Map)['token_hash'] as String;

    final auth = await _client.auth.verifyOTP(
      type: OtpType.magiclink,
      tokenHash: tokenHash,
    );
    final userId = auth.user?.id;
    if (userId == null) {
      throw RecoveryException('Recovery token could not be redeemed.');
    }
    // This account provably has recovery set up — mark it so the settings
    // screen reflects "enabled" and warns before overwriting the phrase.
    await markEnrolled();
    return userId;
  }
}

class RecoveryException implements Exception {
  final String message;
  RecoveryException(this.message);
  @override
  String toString() => 'RecoveryException: $message';
}

final recoveryServiceProvider = Provider<RecoveryService>((ref) {
  return RecoveryService(
    ref.read(supabaseClientProvider),
    ref.read(secureStorageProvider),
  );
});

/// Whether this account has a recovery phrase set up (local flag). Invalidate
/// after enrolling to refresh the settings screen.
final recoveryEnrolledProvider = FutureProvider.autoDispose<bool>((ref) {
  return ref.read(recoveryServiceProvider).isEnrolled();
});
