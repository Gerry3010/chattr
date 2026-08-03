// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/ml_kem.dart';

/// Chat Key Pair Manager (post-quantum).
///
/// Manages per-chat **hybrid** key pairs (X25519 + ML-KEM-768) stored in secure
/// storage. X25519 keys are generated cross-platform via the `cryptography`
/// package; ML-KEM-768 keys via the platform hybrid-KEM (native FFI / web JS).
///
/// Public/private keys are exchanged as a small JSON blob so the existing
/// `chat_members.public_key` column and the message-encryption API can stay
/// unchanged (no schema migration):
///   public:  `{"x": base64(x25519 pub),  "m": base64(ml-kem pub)}`
///   private: `{"x": base64(x25519 priv), "m": base64(ml-kem priv)}`
class ChatKeyPairManager {
  final FlutterSecureStorage _storage;

  ChatKeyPairManager(this._storage);

  static final X25519 _x25519 = X25519();

  // Device-bound accessibility (audit M5): per-chat private keys are the E2E
  // secret material, so they must NOT ride into an iCloud/iTunes Keychain
  // backup where they could be exfiltrated off-device. `first_unlock_this_device`
  // keeps them local and readable only after the first unlock — mirrors
  // EncryptionKeyManager / IdentityKeyManager. A distinct accountName isolates
  // this keychain service from the DB key and the identity key.
  static const IOSOptions _iOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    accountName: 'chattr_chat_keys',
  );
  // resetOnError:false (audit #149, part of the holistic anti-wipe). With `true`
  // a transient AndroidKeyStore decrypt error makes flutter_secure_storage call
  // deleteAll() — wiping the whole EncryptedSharedPreferences namespace, which
  // takes the identity key + its sentinel with it (the Galaxy 2026-07-18 silent
  // re-key). With `false` the error THROWS instead: a per-chat key read then
  // surfaces as a decrypt-defer / registration-skip (every caller's generate is
  // AFTER the throwing read and try/caught, so a throw never regenerates or
  // wipes) and the shared namespace is left intact.
  static const AndroidOptions _aOptions = AndroidOptions(resetOnError: false);
  static const LinuxOptions _lOptions = LinuxOptions();

  // Keys whose legacy (default-options) copy we've already swept this session,
  // so the belt-and-braces cleanup in [_readMigrating] runs at most once per
  // key — chat keys are read on every message decrypt, so we don't want a
  // keychain delete on every read.
  final Set<String> _legacySwept = <String>{};

  // Only the iOS Keychain gives the hardened vs default options a SEPARATE item
  // (via `accountName` in [_iOptions]), so a legacy default-options copy lingers
  // there as a distinct orphan that's safe to sweep. On ANDROID the hardened
  // [_aOptions] add NO namespace/prefix — the "default" item IS the hardened item
  // (same as web/desktop) — so deleting the "legacy" copy destroys the ONE and
  // ONLY chat key. That was the 1.6.0 Android receive bug: after the M5 sweep,
  // `chat_pqc_key_*` vanished on the first read (right after registration) →
  // `hasKeyPair()==false` → "No private key" → the device could send but could
  // NEVER receive (iOS was fine — its keychain items really are separate).
  // Never sweep/migrate-delete anywhere the two aren't genuinely separate.
  static final bool _accountSeparated =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  String _storageKey(String chatId) => 'chat_pqc_key_$chatId';
  // One previous generation is retained after a rotation so in-flight messages
  // (encrypted for the old public key before senders learned the new one) still
  // decrypt. The next rotation overwrites it.
  String _prevStorageKey(String chatId) => 'chat_pqc_key_prev_$chatId';

  Future<void> _writeHardened(String key, String value) => _storage.write(
        key: key,
        value: value,
        iOptions: _iOptions,
        aOptions: _aOptions,
        lOptions: _lOptions,
      );

  /// Read a key blob, transparently migrating pre-M5 records.
  ///
  /// Existing installs stored these under the DEFAULT keychain options (backed
  /// up, exfiltratable — the M5 finding). We first look under the hardened
  /// options; if nothing is there we fall back to the EXACT legacy read (byte
  /// identical to the old code, so a key readable before the upgrade is still
  /// readable), then rewrite it under the hardened options and drop the legacy
  /// copy. This makes the accessibility change strictly no-data-loss.
  Future<String?> _readMigrating(String key) async {
    final hardened = await _storage.read(
      key: key,
      iOptions: _iOptions,
      aOptions: _aOptions,
      lOptions: _lOptions,
    );
    if (hardened != null) {
      // Belt-and-braces (mac-claude's keychain-level M5 review): if a legacy
      // default-options copy ALSO lingers — e.g. a generate/rotate wrote the
      // hardened item while the old one was never migrated — it survives as a
      // backup-exfiltratable orphan in the hardened item's shadow. Sweep it
      // once per session, but ONLY on account-separated backends (else the
      // "legacy" read IS the hardened item and we'd delete the only key).
      if (_accountSeparated && _legacySwept.add(key)) {
        await _storage.delete(key: key);
      }
      return hardened;
    }

    final legacy = await _storage.read(key: key);
    if (legacy == null) return null;
    // Migrate in place: harden, then remove the old (default-options) copy —
    // again only where that copy is a SEPARATE item (iOS/Android).
    await _writeHardened(key, legacy);
    if (_accountSeparated) await _storage.delete(key: key);
    _legacySwept.add(key);
    return legacy;
  }

  /// Generate a hybrid key pair for a chat and store it in secure storage.
  Future<void> generateKeyPairForChat(String chatId) async {
    final xkp = await _x25519.newKeyPair();
    final xPriv = Uint8List.fromList(await xkp.extractPrivateKeyBytes());
    final xPub = Uint8List.fromList((await xkp.extractPublicKey()).bytes);
    final (mPriv, mPub) = await mlKemGenerate();

    final record = jsonEncode({
      'xPriv': base64.encode(xPriv),
      'xPub': base64.encode(xPub),
      'mPriv': base64.encode(mPriv),
      'mPub': base64.encode(mPub),
    });
    await _writeHardened(_storageKey(chatId), record);
  }

  Future<Map<String, dynamic>?> _record(String chatId) async {
    final raw = await _readMigrating(_storageKey(chatId));
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Combined public key blob (JSON: {"x":..,"m":..}) or null.
  Future<String?> getPublicKey(String chatId) async {
    final r = await _record(chatId);
    if (r == null) return null;
    return jsonEncode({'x': r['xPub'], 'm': r['mPub']});
  }

  /// Combined private key blob (JSON: {"x":..,"m":..}) or null. Passed to
  /// [MessageEncryptionService.decryptMessage].
  Future<String?> getPrivateKey(String chatId) async {
    final r = await _record(chatId);
    if (r == null) return null;
    return jsonEncode({'x': r['xPriv'], 'm': r['mPriv']});
  }

  /// All private-key blobs valid for decryption, current first, then the one
  /// retained previous generation (after a rotation). Callers try them in
  /// order so a message encrypted for either key still decrypts.
  Future<List<String>> getAllPrivateKeys(String chatId) async {
    final keys = <String>[];
    final current = await getPrivateKey(chatId);
    if (current != null) keys.add(current);
    final prevRaw = await _readMigrating(_prevStorageKey(chatId));
    if (prevRaw != null) {
      final p = jsonDecode(prevRaw) as Map<String, dynamic>;
      keys.add(jsonEncode({'x': p['xPriv'], 'm': p['mPriv']}));
    }
    return keys;
  }

  /// Rotate the chat's key pair: keep the current one as the (single) previous
  /// generation, then generate a fresh current. Returns the new combined
  /// public key so the caller can register it. Old locally-stored messages are
  /// unaffected (they're kept under the local DB key, not this chat key).
  Future<String?> rotateKeyPairForChat(String chatId) async {
    final currentRaw = await _readMigrating(_storageKey(chatId));
    if (currentRaw != null) {
      await _writeHardened(_prevStorageKey(chatId), currentRaw);
    }
    await generateKeyPairForChat(chatId);
    return getPublicKey(chatId);
  }

  /// Check if a key pair exists for the chat.
  Future<bool> hasKeyPair(String chatId) async {
    return (await _readMigrating(_storageKey(chatId))) != null;
  }

  /// Restore a raw (storageKey, value) chat-key entry from a backup, written
  /// with the SAME device-bound hardened options as freshly generated keys
  /// (audit M5) rather than the plugin defaults. The backup export preserves the
  /// raw storage keys (`chat_pqc_key_*`, incl. the retained `_prev_` generation),
  /// so restore writes them back verbatim through [_writeHardened] — keeping
  /// restored keys off iCloud/iTunes backups (device-bound) instead of
  /// re-introducing the pre-M5 exfiltratable copy until the first read migrates
  /// it. [_readMigrating] reads the hardened item first, so restored keys are
  /// found without any migration round-trip.
  Future<void> importRestoredKey(String storageKey, String value) =>
      _writeHardened(storageKey, value);

  /// Delete the key pair for the chat (current and any retained previous).
  /// Deletes both the hardened and any legacy (pre-M5) copy.
  Future<void> deleteKeyPair(String chatId) async {
    for (final key in [_storageKey(chatId), _prevStorageKey(chatId)]) {
      await _storage.delete(
        key: key,
        iOptions: _iOptions,
        aOptions: _aOptions,
        lOptions: _lOptions,
      );
      await _storage.delete(key: key); // legacy default-options copy
    }
  }

  /// Generate a hybrid key pair and return the combined public/private blobs
  /// WITHOUT touching secure storage. Useful for tests (two users in one process)
  /// and for callers that manage key storage themselves.
  static Future<({String publicKey, String privateKey})>
      generateDetachedKeyPair() async {
    final xkp = await _x25519.newKeyPair();
    final xPriv = Uint8List.fromList(await xkp.extractPrivateKeyBytes());
    final xPub = Uint8List.fromList((await xkp.extractPublicKey()).bytes);
    final (mPriv, mPub) = await mlKemGenerate();
    return (
      publicKey:
          jsonEncode({'x': base64.encode(xPub), 'm': base64.encode(mPub)}),
      privateKey:
          jsonEncode({'x': base64.encode(xPriv), 'm': base64.encode(mPriv)}),
    );
  }

  // ── Combined-key codec (shared with MessageEncryptionService) ──────────────

  /// Decodes a combined public-key blob into (x25519Pub, mlkemPub) bytes.
  static (Uint8List, Uint8List) decodePublic(String combined) {
    final m = jsonDecode(combined) as Map<String, dynamic>;
    return (base64.decode(m['x'] as String), base64.decode(m['m'] as String));
  }

  /// Decodes a combined private-key blob into (x25519Priv, mlkemPriv) bytes.
  static (Uint8List, Uint8List) decodePrivate(String combined) {
    final m = jsonDecode(combined) as Map<String, dynamic>;
    return (base64.decode(m['x'] as String), base64.decode(m['m'] as String));
  }
}
