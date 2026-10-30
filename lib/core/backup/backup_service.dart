// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../security/chat_key_pair_manager.dart';
import '../security/encryption_key_manager.dart';
import '../security/identity_key_manager.dart';
import '../security/security_providers.dart';
import '../supabase/supabase_client_provider.dart';
import '../../features/identity/identity_verification_repository.dart';

/// Backup / restore of the *identity + keys* an anonymous Chattr install keeps
/// only on the device — nothing here has a server-side copy, so losing the app
/// container (wipe / reinstall) is otherwise permanent (anonymous auth has no
/// recovery). This is the Phase-1 safety net: a passphrase-encrypted file the
/// user stores themselves. It deliberately does NOT include message history
/// (the local SQLite DB) — restoring identity + keys gets you back into every
/// chat and able to decrypt future messages; already-read messages were cleared
/// server-side and are out of scope here (see docs/… / the backup plan).
///
/// A durable, file-less recovery (a mnemonic that survives without exporting a
/// token that can expire) is Phase 2.

/// What a backup captures. Kept as a plain, JSON-round-trippable object so the
/// crypto envelope ([BackupCrypto]) can be unit-tested without any device I/O.
class BackupPayload {
  /// The anonymous auth user id — the identity everything is keyed by.
  final String userId;

  /// Supabase session refresh token — re-authenticates as the SAME user id on
  /// restore, so server-side chat memberships stay intact.
  final String refreshToken;

  /// The local AES DB key (`encryption_key_v1`) — without it the restored
  /// SQLite rows and any re-synced messages can't be decrypted.
  final String encryptionKey;

  /// Every per-chat hybrid keypair blob, keyed by its secure-storage key
  /// (`chat_pqc_key_<chatId>` and any retained `chat_pqc_key_prev_<chatId>`).
  final Map<String, String> chatKeys;

  /// The Ed25519 identity seed (base64). Optional: backups made before
  /// CHAT-8 do not carry it. Restoring it keeps every peer's safety number
  /// and the signatures on the restored chat keys valid.
  final String? identitySeed;

  /// The pin document (which peers were verified), JSON. Optional as above.
  final String? identityPins;

  const BackupPayload({
    required this.userId,
    required this.refreshToken,
    required this.encryptionKey,
    required this.chatKeys,
    this.identitySeed,
    this.identityPins,
  });

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'refreshToken': refreshToken,
        'encryptionKey': encryptionKey,
        'chatKeys': chatKeys,
        if (identitySeed != null) 'identitySeed': identitySeed,
        if (identityPins != null) 'identityPins': identityPins,
      };

  factory BackupPayload.fromJson(Map<String, dynamic> j) => BackupPayload(
        userId: j['userId'] as String,
        refreshToken: j['refreshToken'] as String,
        encryptionKey: j['encryptionKey'] as String,
        chatKeys: (j['chatKeys'] as Map)
            .map((k, v) => MapEntry(k as String, v as String)),
        identitySeed: j['identitySeed'] as String?,
        identityPins: j['identityPins'] as String?,
      );
}

/// Why a backup or restore failed, for the screen to pick its text.
enum BackupError {
  noSession,
  noEncryptionKey,
  noRefreshToken,
  badFile,
  wrongPassphrase,
  malformed,

  /// The login stored in the file no longer works (it has been used since)
  /// and this device is signed in as someone else. A recovery-phrase login
  /// as the backed-up account first, then the file again.
  sessionExpired,

  /// The file belongs to another account than the one the login ended up in.
  accountMismatch,
}

/// Raised for a bad file or a wrong passphrase (indistinguishable by design —
/// AES-GCM auth failure covers both).
class BackupException implements Exception {
  final String message;
  final BackupError? error;
  BackupException(this.message, [this.error]);
  @override
  String toString() => 'BackupException: $message';
}

/// The passphrase → key → sealed-bytes envelope. Pure and static so it's fully
/// unit-testable (see test/backup_service_test.dart). Format v1:
///   Argon2id(m=19 MiB, t=3, p=1, 32 B) over the passphrase + random salt,
///   then AES-256-GCM (authenticated) over the JSON payload. The envelope is a
///   small JSON header carrying salt/nonce/ct/mac so the format is
///   self-describing and versioned.
class BackupCrypto {
  static const String magic = 'CHATTR-BACKUP';
  static const int version = 1;

  // OWASP mobile baseline: m=19 MiB (19456 × 1 kB blocks), t=3, p=1.
  static const int _memoryBlocks = 19456;
  static const int _iterations = 3;
  static const int _parallelism = 1;

  static Argon2id _kdf() => Argon2id(
        parallelism: _parallelism,
        memory: _memoryBlocks,
        iterations: _iterations,
        hashLength: 32,
      );
  static final AesGcm _aes = AesGcm.with256bits();

  static Future<SecretKey> _deriveKey(String passphrase, List<int> salt) =>
      _kdf().deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);

  /// Serialize + encrypt [payload] under [passphrase]. Returns the file bytes.
  static Future<Uint8List> seal(BackupPayload payload, String passphrase) async {
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final key = await _deriveKey(passphrase, salt);
    final plaintext = utf8.encode(jsonEncode(payload.toJson()));
    final box = await _aes.encrypt(plaintext, secretKey: key);
    final envelope = {
      'magic': magic,
      'v': version,
      'kdf': 'argon2id',
      'm': _memoryBlocks,
      't': _iterations,
      'p': _parallelism,
      'salt': base64.encode(salt),
      'nonce': base64.encode(box.nonce),
      'ct': base64.encode(box.cipherText),
      'mac': base64.encode(box.mac.bytes),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  /// Decrypt + parse file [bytes] with [passphrase]. Throws [BackupException]
  /// on a non-Chattr file or a wrong passphrase.
  static Future<BackupPayload> open(Uint8List bytes, String passphrase) async {
    Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      throw BackupException(
          'Not a valid Chattr backup file.', BackupError.badFile);
    }
    if (env['magic'] != magic) {
      throw BackupException(
          'Not a valid Chattr backup file.', BackupError.badFile);
    }
    final salt = base64.decode(env['salt'] as String);
    final key = await _deriveKey(passphrase, salt);
    final box = SecretBox(
      base64.decode(env['ct'] as String),
      nonce: base64.decode(env['nonce'] as String),
      mac: Mac(base64.decode(env['mac'] as String)),
    );
    List<int> clear;
    try {
      clear = await _aes.decrypt(box, secretKey: key);
    } catch (_) {
      // AES-GCM auth failure — wrong passphrase or tampered file.
      throw BackupException(
          'Wrong passphrase or corrupted backup.', BackupError.wrongPassphrase);
    }
    try {
      return BackupPayload.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
    } catch (_) {
      throw BackupException(
          'Backup payload is malformed.', BackupError.malformed);
    }
  }
}

/// The session side of a restore, a seam so the flow is testable without a
/// Supabase client.
abstract class BackupAuth {
  String? get currentUserId;
  String? get currentRefreshToken;

  /// Signs in with [refreshToken]; returns the user id it lands on.
  Future<String?> signInWithRefreshToken(String refreshToken);
}

class _SupabaseBackupAuth implements BackupAuth {
  _SupabaseBackupAuth(this._client);
  final SupabaseClient _client;

  @override
  String? get currentUserId => _client.auth.currentSession?.user.id;

  @override
  String? get currentRefreshToken => _client.auth.currentSession?.refreshToken;

  @override
  Future<String?> signInWithRefreshToken(String refreshToken) async =>
      (await _client.auth.setSession(refreshToken)).user?.id;
}

/// Gathers the on-device identity + keys into a [BackupPayload] and applies a
/// restored one. The crypto lives in [BackupCrypto]; this side handles the
/// (device-specific, side-effectful) reading/writing.
///
/// Every secret is read and written through the manager that owns it, with
/// that manager's storage options (CHAT-8): a plain `readAll()` sees only the
/// plugin's default keychain service on iOS and missed every chat key.
class BackupService {
  final EncryptionKeyManager _keyManager;
  final ChatKeyPairManager _chatKeyPairManager;
  final IdentityKeyManager _identityKeyManager;
  final IdentityVerificationRepository _pins;
  final BackupAuth _auth;

  BackupService(
    this._keyManager,
    this._chatKeyPairManager,
    this._identityKeyManager,
    this._pins,
    this._auth,
  );

  /// Collects the current identity + keys and returns an encrypted backup file.
  /// Throws [BackupException] if there's no active session or DB key to back up.
  Future<Uint8List> createBackup(String passphrase) async {
    final userId = _auth.currentUserId;
    if (userId == null) {
      throw BackupException(
          'No active session to back up.', BackupError.noSession);
    }
    final refreshToken = _auth.currentRefreshToken ?? '';
    if (refreshToken.isEmpty) {
      throw BackupException(
          'Session has no refresh token — cannot back up identity.',
          BackupError.noRefreshToken);
    }
    final encKey = await _keyManager.getKey(requireBiometric: false);
    if (encKey == null) {
      throw BackupException(
          'No encryption key to back up.', BackupError.noEncryptionKey);
    }

    final payload = BackupPayload(
      userId: userId,
      refreshToken: refreshToken,
      encryptionKey: encKey,
      chatKeys: await _chatKeyPairManager.exportAllKeys(),
      identitySeed: await _identityKeyManager.exportSeed(),
      identityPins: await _pins.exportDocument(),
    );
    return BackupCrypto.seal(payload, passphrase);
  }

  /// Restores identity + keys from an encrypted backup. The caller should
  /// re-run app init / restart so the DB opens under the restored key and
  /// chats re-sync. Throws [BackupException] on a bad file/passphrase or when
  /// the backed-up account cannot be signed into.
  ///
  /// **The login comes first, and from the file only if it has to** (CHAT-8).
  /// The refresh token in the file is single-use: the first session refresh
  /// after the backup retires it, so a backup a day old usually cannot sign in
  /// any more, and re-using a retired token can make the server revoke the
  /// whole session family. If this device is already signed in as the
  /// backed-up account (the normal case after a recovery-phrase login), the
  /// file only supplies keys. Otherwise the token is tried once; if it fails,
  /// nothing is written and the user is pointed at the recovery phrase.
  Future<BackupPayload> restoreBackup(Uint8List bytes, String passphrase) async {
    final payload = await BackupCrypto.open(bytes, passphrase);

    if (_auth.currentUserId != payload.userId) {
      String? landed;
      try {
        landed = await _auth.signInWithRefreshToken(payload.refreshToken);
      } catch (_) {
        throw BackupException(
          'The login stored in this backup has expired.',
          BackupError.sessionExpired,
        );
      }
      if (landed != payload.userId) {
        throw BackupException(
          'Signed into a different account than the backup belongs to.',
          BackupError.accountMismatch,
        );
      }
    }

    // Restore the local DB key and every per-chat keypair. The chat keys go
    // through the manager's hardened write (audit M5 device-binding) — writing
    // them raw here used the plugin DEFAULT options, which re-introduced the
    // pre-M5 exfiltratable copy (backup-migratable, not device-bound) until the
    // first read migrated them. importKey already hardens the DB key itself.
    await _keyManager.importKey(payload.encryptionKey);
    await _chatKeyPairManager.restoreKeys(payload.chatKeys);
    final seed = payload.identitySeed;
    if (seed != null) await _identityKeyManager.importRestoredSeed(seed);
    final pins = payload.identityPins;
    if (pins != null) await _pins.importDocument(pins);
    return payload;
  }
}

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    ref.read(encryptionKeyManagerProvider),
    ref.read(chatKeyPairManagerProvider),
    ref.read(identityKeyManagerProvider),
    ref.read(identityVerificationRepositoryProvider),
    _SupabaseBackupAuth(ref.read(supabaseClientProvider)),
  );
});
