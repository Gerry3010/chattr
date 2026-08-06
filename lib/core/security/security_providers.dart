// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../database/database_service.dart';
import 'biometric_auth_service.dart';
import 'encryption_key_manager.dart';
import 'encryption_service.dart';
import 'chat_key_pair_manager.dart';
import 'identity_key_manager.dart';
import 'message_encryption_service.dart';

/// Provider for secure storage.
///
/// `resetOnError: false` is the process-wide default (audit #149 follow-up,
/// Galaxy 2026-07-19). With the plugin default `true`, ANY transient
/// AndroidKeyStore decrypt error on ANY read makes flutter_secure_storage call
/// `deleteAll()` — wiping the WHOLE EncryptedSharedPreferences namespace
/// (`chat_pqc_key_*`, identity, passcode, app-lock flag). The three key
/// managers passed explicit `resetOnError:false`, but callers that inherit the
/// instance default (PasscodeManager, AppLockController's `app_lock_enabled_v1`
/// read, ChatKeyPairManager's legacy-migration read) did NOT — so a cold-start
/// keystore-not-ready hiccup wiped the per-chat KEM keys, which then silently
/// regenerated + re-registered → a false `keys_rotated` alarm to every peer on
/// every Galaxy cold start. Defaulting the shared instance to `false` closes
/// that for every inheriting caller at once. iOS is unaffected (Android-only
/// option). Callers may still override per-call.
final secureStorageProvider = Provider<FlutterSecureStorage>((ref) {
  return const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
});

/// Provider for database service
final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService.instance;
});

/// Provider for biometric authentication service
final biometricAuthServiceProvider = Provider<BiometricAuthService>((ref) {
  return BiometricAuthService();
});

/// Provider for encryption key manager
final encryptionKeyManagerProvider = Provider<EncryptionKeyManager>((ref) {
  final storage = ref.read(secureStorageProvider);
  final biometricAuth = ref.read(biometricAuthServiceProvider);
  return EncryptionKeyManager(storage, biometricAuth);
});

/// Provider for encryption service
final encryptionServiceProvider = Provider<EncryptionService>((ref) {
  final keyManager = ref.read(encryptionKeyManagerProvider);
  return EncryptionService(keyManager);
});

/// Provider for chat key pair manager
final chatKeyPairManagerProvider = Provider<ChatKeyPairManager>((ref) {
  final storage = ref.read(secureStorageProvider);
  return ChatKeyPairManager(storage);
});

/// Provider for the long-term per-user identity key (Ed25519).
///
/// `hasLocalData` is the guard Mac's iOS analysis flagged as the most important
/// (#149): on iOS the plugin THROWS on any keychain error except a genuine
/// `errSecItemNotFound`, so the only silent-mint vector left is a real "item not
/// found" while the account is actually established (an entitlement / access-
/// group regression — the M5 class). Cross-checking the local DB for chat data
/// turns that from a silent identity rotation into a surfaced error/defer.
/// A DB-read error here propagates and is caught by the (already defensive)
/// ensureKeyPair callers → defer, never mint.
final identityKeyManagerProvider = Provider<IdentityKeyManager>((ref) {
  final storage = ref.read(secureStorageProvider);
  return IdentityKeyManager(
    storage,
    hasLocalData: () async {
      final db = await ref.read(databaseServiceProvider).database;
      final rows = await db.rawQuery('SELECT 1 FROM chats LIMIT 1');
      return rows.isNotEmpty;
    },
  );
});

/// Provider for message encryption service
final messageEncryptionServiceProvider = Provider<MessageEncryptionService>((ref) {
  final keyManager = ref.read(chatKeyPairManagerProvider);
  return MessageEncryptionService(keyManager);
});
