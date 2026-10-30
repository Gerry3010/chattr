// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/ed25519.dart';
import 'key_locked_exception.dart';

/// Long-term per-user **identity** key (Ed25519).
///
/// Unlike [ChatKeyPairManager]'s per-chat KEM keys, this is ONE stable keypair
/// per user/device, generated once and reused. It is the trust anchor the
/// security audit (2026-07-16, C1/H1) requires:
///   • its public key goes into the user's QR + `profiles.identity_public_key`
///     so peers can pin it (TOFU) and compute a safety number;
///   • it signs each per-chat KEM public key, so a peer can detect a server that
///     swaps keys to MITM;
///   • it signs outgoing messages (PR2) so recipients can verify authorship.
///
/// It is deliberately SEPARATE from the recovery-phrase Ed25519 key
/// ([RecoveryCrypto]): that key is an account-takeover credential and is never
/// persisted. This key is persisted (hardened, device-bound) so it can sign
/// routinely without re-entering a phrase. On account recovery / reinstall a
/// fresh identity key is minted (Signal model) and peers see a
/// "safety number changed" warning.
///
/// **Never-silently-re-mint hardening (audit #149, Galaxy 2026-07-18).** A
/// persisted identity that merely became *unreadable* (a keystore/keychain error,
/// or Android `resetOnError` wiping the namespace) must NOT be mistaken for
/// "no identity yet": minting a fresh one republishes it and flips every peer's
/// safety number. So this manager mirrors [EncryptionKeyManager]'s M6/M7
/// defenses:
///   • an ungated existence **sentinel** ([_seedSentinel]) written before the
///     seed, so "does an identity exist" is answerable without touching (or
///     ever overwriting) the seed;
///   • a read that ERRORS, or returns null while the sentinel / local chat data
///     proves a key was there, throws [IdentityKeyLockedException] instead of
///     returning null — callers DEFER, they never re-mint;
///   • `resetOnError:false` on Android so a transient keystore error throws
///     rather than silently wiping the seed.
class IdentityKeyManager {
  static const String _seedStorageKey = 'identity_key_v1';

  /// Marks "an identity key exists", so existence is answerable without reading
  /// (and risking overwriting) the seed. Never gated — mirrors
  /// [EncryptionKeyManager]'s `encryption_key_v1_exists`. Carries no secret.
  static const String _seedSentinel = 'identity_key_v1_exists';

  /// The public identity key this installation last published successfully.
  /// It is what lets a device tell "someone else replaced my key on the
  /// server" (another installation, after a recovery) from "my own publish
  /// has not gone through yet" (see installation_status.dart).
  static const String _publishedKey = 'identity_key_published_v1';

  final FlutterSecureStorage _storage;

  /// Optional backstop for installs that predate the sentinel: returns true when
  /// the local DB already holds chat data, i.e. this is NOT a fresh install. If
  /// the seed AND sentinel are both absent but this returns true, the identity
  /// was lost (not never-created) → [_loadKeyPair] refuses to silently re-mint.
  final Future<bool> Function()? _hasLocalData;

  /// Session cache of the unlocked keypair, so signing doesn't hit secure
  /// storage (and any keychain prompt) on every message.
  SimpleKeyPair? _cached;

  IdentityKeyManager(this._storage, {Future<bool> Function()? hasLocalData})
      // The named (public) param intentionally differs from the private field,
      // so an initializing formal — which would surface `_hasLocalData` as the
      // parameter name — is not usable here.
      // ignore: prefer_initializing_formals
      : _hasLocalData = hasLocalData;

  // Device-bound, non-exportable-via-backup accessibility — mirrors
  // EncryptionKeyManager. `first_unlock_this_device` keeps the key off iCloud
  // Keychain backups; a distinct accountName isolates it from the DB key. The
  // sentinel shares these options (it is never gated either).
  IOSOptions _iOptions() => const IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
        accountName: 'chattr_identity',
      );

  // resetOnError is deliberately FALSE (differs from the pre-#149 default). With
  // `true`, a transient AndroidKeyStore decrypt error makes flutter_secure_storage
  // call deleteAll() — silently wiping the identity seed AND (deleteAll clears
  // the whole EncryptedSharedPreferences file) the sentinel with it. ensureKeyPair
  // then sees "no key" and mints a FRESH identity, flipping every peer's safety
  // number: the Galaxy 2026-07-18 regression. With `false` the error THROWS;
  // _loadKeyPair surfaces it as IdentityKeyLockedException and callers DEFER,
  // leaving the seed intact for the next (recovered) read.
  //
  // NOTE: the namespace wipe is only FULLY closed once every other secure-storage
  // caller (EncryptionKeyManager, ChatKeyPairManager, PrekeyManager) also drops
  // resetOnError:true — a deleteAll from any one of them still clears this key.
  // Tracked in #149; this manager does its part.
  AndroidOptions _aOptions() => const AndroidOptions(resetOnError: false);
  LinuxOptions _lOptions() => const LinuxOptions();

  /// True if an identity key already exists on this device.
  ///
  /// Reads the ungated sentinel first, so it never touches (nor risks
  /// overwriting) the seed and never mints. Falls back to a seed read only for
  /// installs predating the sentinel, adopting the sentinel so future reads are
  /// guarded. A locked seed read (PlatformException) counts as "exists".
  Future<bool> hasKeyPair() async {
    if (await _sentinelPresent()) return true;
    String? raw;
    try {
      raw = await _readSeed();
    } on PlatformException {
      return true; // present but locked → it exists
    }
    if (raw == null) return false;
    await _writeSentinel(); // pre-sentinel install: adopt it
    return true;
  }

  /// Ensure an identity key exists (generate on first call), returning the
  /// base64 public key. Idempotent — safe to call on every startup.
  ///
  /// Throws [IdentityKeyLockedException] if an identity EXISTS but is currently
  /// unreadable — callers must DEFER, not re-mint. Only mints when the identity
  /// is genuinely absent (no seed, no sentinel, no local chat data).
  Future<String> ensureKeyPair() async {
    final existing = await _loadKeyPair();
    if (existing != null) return Ed25519Keys.publicBase64(existing);
    return _generateAndStore();
  }

  /// The base64 public identity key, or null if none exists yet. Throws
  /// [IdentityKeyLockedException] if one exists but is unreadable.
  Future<String?> publicKeyBase64() async {
    final kp = await _loadKeyPair();
    if (kp == null) return null;
    return Ed25519Keys.publicBase64(kp);
  }

  /// Sign [message] bytes with the identity key; returns a base64 signature.
  /// Throws [StateError] if no identity key exists (call [ensureKeyPair] first),
  /// or [IdentityKeyLockedException] if one exists but is unreadable.
  Future<String> sign(List<int> message) async {
    final kp = await _loadKeyPair();
    if (kp == null) {
      throw StateError('IdentityKeyManager.sign: no identity key present');
    }
    return Ed25519Keys.signBase64(kp, message);
  }

  /// Replace the identity key with a fresh one (Signal-model recovery /
  /// reinstall). Returns the new base64 public key so the caller can republish
  /// it. Peers will see a "safety number changed" warning.
  ///
  /// This is the ONLY intentional re-mint. It is explicit (never reached by a
  /// failed read) — the whole point of the hardening above is that no silent
  /// path lands here.
  Future<String> regenerate() async {
    _cached = null;
    return _generateAndStore();
  }

  /// The public key this installation last published, or null if it never
  /// recorded one (installs from before 1.32.2, or after a storage wipe).
  Future<String?> lastPublishedPublicKey() async {
    try {
      return await _storage.read(
        key: _publishedKey,
        iOptions: _iOptions(),
        aOptions: _aOptions(),
        lOptions: _lOptions(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Record that [publicKeyBase64] is now on the server, published by THIS
  /// installation. Call after every successful identity publish.
  Future<void> markPublished(String publicKeyBase64) => _storage.write(
        key: _publishedKey,
        value: publicKeyBase64,
        iOptions: _iOptions(),
        aOptions: _aOptions(),
        lOptions: _lOptions(),
      );

  /// Delete the identity key (account wipe / reinitialize). Removes the sentinel
  /// too, else [hasKeyPair] would keep claiming a key that no longer exists.
  Future<void> deleteKeyPair() async {
    _cached = null;
    await _storage.delete(
      key: _publishedKey,
      iOptions: _iOptions(),
      aOptions: _aOptions(),
      lOptions: _lOptions(),
    );
    await _storage.delete(
      key: _seedStorageKey,
      iOptions: _iOptions(),
      aOptions: _aOptions(),
      lOptions: _lOptions(),
    );
    await _storage.delete(
      key: _seedSentinel,
      iOptions: _iOptions(),
      aOptions: _aOptions(),
      lOptions: _lOptions(),
    );
  }

  /// The identity seed (base64) for the backup, or null if this device has
  /// none yet (CHAT-8). A locked or lost seed throws, as everywhere else: a
  /// backup without the identity must not look like a complete one.
  Future<String?> exportSeed() async {
    final kp = await _loadKeyPair();
    if (kp == null) return null;
    return base64.encode(await Ed25519Keys.privateSeed(kp));
  }

  /// Replaces this device's identity with the one from a backup (CHAT-8).
  ///
  /// Wanted on a restore: peers pinned the OLD identity, and the per-chat keys
  /// coming back with the backup were signed by it. The device's own (newer)
  /// key is dropped on purpose; publishing and re-signing the chat keys happen
  /// on the next start through the usual reconcile (`installationStatus` reads
  /// "unknown", `_publishIdentityKey` and `_registerMyKey` write the restored
  /// key). Same write order as [_generateAndStore].
  Future<void> importRestoredSeed(String seedBase64) async {
    final seed = base64.decode(seedBase64);
    // Validates the seed before anything is overwritten.
    final kp = await Ed25519Keys.fromSeed(seed);
    await _writeSentinel();
    await _storage.write(
      key: _seedStorageKey,
      value: base64.encode(seed),
      iOptions: _iOptions(),
      aOptions: _aOptions(),
      lOptions: _lOptions(),
    );
    _cached = kp;
  }

  Future<String> _generateAndStore() async {
    final kp = await Ed25519Keys.generate();
    final seed = await Ed25519Keys.privateSeed(kp);
    // Sentinel FIRST, then the seed — same ordering rationale as
    // EncryptionKeyManager._writeKeyAndSentinel: a crash between the two leaves
    // "sentinel, no seed" (a later read throws IdentityKeyLockedException → the
    // app defers loudly, nothing overwritten) rather than "seed, no sentinel"
    // (a later null read looks absent and could overwrite the seed).
    await _writeSentinel();
    await _storage.write(
      key: _seedStorageKey,
      value: base64.encode(seed),
      iOptions: _iOptions(),
      aOptions: _aOptions(),
      lOptions: _lOptions(),
    );
    _cached = kp;
    return Ed25519Keys.publicBase64(kp);
  }

  /// Load the identity keypair, distinguishing ABSENT (returns null → caller may
  /// mint) from LOCKED/LOST (throws [IdentityKeyLockedException] → caller
  /// defers). Never returns null for a key that merely became unreadable.
  Future<SimpleKeyPair?> _loadKeyPair() async {
    if (_cached != null) return _cached;

    String? raw;
    try {
      raw = await _readSeed();
    } on PlatformException catch (e) {
      // Present but unreadable (keystore/keychain error). NEVER null — that would
      // read as "absent" and re-mint the identity, flipping every peer's safety
      // number. Surface typed so callers defer and retry.
      throw IdentityKeyLockedException(e);
    }

    if (raw != null) {
      _cached = await Ed25519Keys.fromSeed(base64.decode(raw));
      // Existing (pre-sentinel) install: adopt the sentinel now that we've
      // confirmed the seed is present, so a LATER null read is recognised as
      // "lost" and refuses to re-mint. Best-effort — a failed adopt must not
      // break a load that already succeeded.
      await _adoptSentinelIfMissing();
      return _cached;
    }

    // raw == null. Distinguish "genuinely fresh" from "was here, now lost".
    if (await _sentinelPresent()) {
      // The sentinel proves a seed was written before → a null read now means it
      // was wiped/lost, not that this is a first run. Do NOT re-mint.
      throw const IdentityKeyLockedException(
        'identity seed missing but existence sentinel present',
      );
    }
    // No sentinel: a genuinely fresh install, or a pre-sentinel install whose
    // seed was already lost. If the local DB holds chat data this cannot be a
    // fresh install → the identity was lost; refuse the silent re-mint.
    if (_hasLocalData != null && await _hasLocalData()) {
      throw const IdentityKeyLockedException(
        'identity seed missing but local chat data present',
      );
    }
    return null; // genuinely absent → caller may mint
  }

  Future<String?> _readSeed() => _storage.read(
        key: _seedStorageKey,
        iOptions: _iOptions(),
        aOptions: _aOptions(),
        lOptions: _lOptions(),
      );

  Future<bool> _sentinelPresent() async {
    final marker = await _storage.read(
      key: _seedSentinel,
      iOptions: _iOptions(),
      aOptions: _aOptions(),
      lOptions: _lOptions(),
    );
    return marker != null;
  }

  Future<void> _writeSentinel() => _storage.write(
        key: _seedSentinel,
        value: '1',
        iOptions: _iOptions(),
        aOptions: _aOptions(),
        lOptions: _lOptions(),
      );

  /// Write the sentinel iff it is missing (pre-sentinel install adoption).
  /// Best-effort: swallows storage errors so it can never break a load that has
  /// already produced a valid keypair.
  Future<void> _adoptSentinelIfMissing() async {
    try {
      if (!await _sentinelPresent()) await _writeSentinel();
    } catch (_) {
      // Adoption is an optimisation, not a correctness requirement for THIS
      // load; ignore and try again next session.
    }
  }
}
