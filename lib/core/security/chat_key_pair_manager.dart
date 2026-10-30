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

  /// Generations in flight, by storage key. Static: every instance in this
  /// isolate writes to the same storage, so they must share the guard.
  static final Map<String, Future<void>> _generating = {};

  /// Makes sure [chatId] has a key pair: generates one if, and only if, there
  /// is none yet, and never two at once for the same chat.
  ///
  /// A new chat sets off several paths together (the chat-request accept,
  /// the `newChat` event for our own row, a `chatUpdate` refresh,
  /// `memberKeyRegistered`). Each used to see "no key yet" and generate its
  /// own; the last local write and the last publish could then be DIFFERENT
  /// keys, so peers encrypted to a key this device no longer had. Found on
  /// 2026-10-12: six "neue Schlüssel" notices within 100 ms of creating a
  /// chat, and messages the receiving device could not open. With at most one
  /// generation, every concurrent publisher publishes the same key.
  ///
  /// A deliberate new key is [rotateKeyPairForChat], which keeps the old one.
  Future<void> generateKeyPairForChat(String chatId) {
    final key = _storageKey(chatId);
    // Block body on purpose: `=> _generating.remove(key)` would return the
    // removed future — this very future — and whenComplete waits for what its
    // callback returns. It would wait for itself, forever.
    return _generating[key] ??= _generateIfAbsent(chatId).whenComplete(() {
      _generating.remove(key);
    });
  }

  Future<void> _generateIfAbsent(String chatId) async {
    if (await hasKeyPair(chatId)) return;
    await _generateFresh(chatId);
  }

  /// Generates a hybrid key pair and stores it, replacing the current one.
  Future<void> _generateFresh(String chatId) async {
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
    // Let a first generation in flight finish, or it would land on top.
    await _generating[_storageKey(chatId)];
    final currentRaw = await _readMigrating(_storageKey(chatId));
    if (currentRaw != null) {
      await _writeHardened(_prevStorageKey(chatId), currentRaw);
    }
    await _generateFresh(chatId);
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

  /// Every chat key blob on this device, keyed by its storage key, for the
  /// backup (CHAT-8).
  ///
  /// Read with the SAME options the keys are written with. The backup used to
  /// call `readAll()` with the plugin defaults; on iOS the defaults name a
  /// different keychain service (`flutter_secure_storage_service` instead of
  /// `chattr_chat_keys`) and class, so every backup made on an iPhone held no
  /// chat key at all and restored into "keys lost" everywhere. The
  /// default-options read is kept for keys that predate the hardening and were
  /// never migrated; the hardened copy wins.
  Future<Map<String, String>> exportAllKeys() async {
    final out = <String, String>{};
    if (_accountSeparated) {
      final legacy = await _storage.readAll(
        aOptions: _aOptions,
        lOptions: _lOptions,
      );
      for (final e in legacy.entries) {
        if (e.key.startsWith(keyPrefix)) out[e.key] = e.value;
      }
    }
    final hardened = await _storage.readAll(
      iOptions: _iOptions,
      aOptions: _aOptions,
      lOptions: _lOptions,
    );
    for (final e in hardened.entries) {
      if (e.key.startsWith(keyPrefix)) out[e.key] = e.value;
    }
    return out;
  }

  /// Writes the chat keys of a backup without ever replacing a key this device
  /// already holds (CHAT-8).
  ///
  /// The usual way to a restore is a recovery-phrase login first, which mints
  /// and registers FRESH keys for every chat; messages sent since then are
  /// encrypted to those. Overwriting them with the backup's keys would make
  /// exactly those messages unreadable. So the backup only fills gaps: its
  /// current key becomes this device's current key where there is none, and
  /// otherwise the previous generation (which still decrypts what was sent to
  /// the old device and is waiting on the server). The backup's own previous
  /// generation fills the previous slot only if that is still empty.
  ///
  /// Returns how many entries were written.
  Future<int> restoreKeys(Map<String, String> entries) async {
    var written = 0;
    final chatIds = <String>{
      for (final key in entries.keys)
        if (key.startsWith(prevKeyPrefix))
          key.substring(prevKeyPrefix.length)
        else if (key.startsWith(keyPrefix))
          key.substring(keyPrefix.length),
    };
    for (final chatId in chatIds) {
      final current = entries[_storageKey(chatId)];
      final prev = entries[_prevStorageKey(chatId)];
      var haveCurrent = await _readMigrating(_storageKey(chatId));
      var havePrev = await _readMigrating(_prevStorageKey(chatId));
      if (current != null && current != haveCurrent) {
        if (haveCurrent == null) {
          await _writeHardened(_storageKey(chatId), current);
          haveCurrent = current;
          written++;
        } else if (havePrev == null) {
          await _writeHardened(_prevStorageKey(chatId), current);
          havePrev = current;
          written++;
        }
      }
      if (prev != null &&
          havePrev == null &&
          prev != haveCurrent) {
        await _writeHardened(_prevStorageKey(chatId), prev);
        written++;
      }
    }
    return written;
  }

  /// Removes every chat key this device holds (logout, CHAT-37).
  ///
  /// On iOS the keys live in their own keychain service (`chattr_chat_keys`),
  /// and the `deleteAll()` of the logout only reaches the plugin's default
  /// service: the keys survived logout, remote wipe and even uninstalling.
  /// Deleted by key here, under both option sets, so it works the same on
  /// every platform and touches nothing else.
  Future<void> deleteAllKeys() async {
    final keys = (await exportAllKeys()).keys.toList();
    for (final key in keys) {
      await _storage.delete(
        key: key,
        iOptions: _iOptions,
        aOptions: _aOptions,
        lOptions: _lOptions,
      );
      await _storage.delete(key: key, aOptions: _aOptions, lOptions: _lOptions);
    }
    _legacySwept.clear();
  }

  /// Storage-key prefix of every chat key blob (current and previous).
  static const String keyPrefix = 'chat_pqc_key_';

  /// Prefix of the retained previous generation (a sub-prefix of [keyPrefix]).
  static const String prevKeyPrefix = 'chat_pqc_key_prev_';

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
