// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Thrown by [EncryptionKeyManager.getKey] when the content key EXISTS but is
/// locked behind its keychain access-control (app lock on + the device isn't
/// satisfying `userPresence` — typically a background/non-interactive read).
///
/// This type exists to keep "locked" strictly separate from "absent". A locked
/// read on iOS throws (OSStatus -25308, errSecInteractionNotAllowed) instead of
/// returning a value; if that were flattened to `null` it would read as "no
/// key", and every null-means-absent path downstream is destructive:
///   * `app_init.dart` → `if (!hasKey) generateKey()` overwrites the key,
///   * `EncryptionService.decrypt` → returns null → the message looks corrupt,
///     the row can be dropped and the sent-receipt watermark can advance past a
///     message that was merely locked, not undecryptable.
///
/// So callers MUST catch this and DEFER (retry after unlock) — never treat it as
/// absence, corruption, or a reason to drop/advance anything. Existence is
/// answered by [EncryptionKeyManager.hasKey] (the ungated sentinel), which never
/// throws and never prompts.
class KeyLockedException implements Exception {
  /// The underlying platform error (e.g. the PlatformException carrying the
  /// OSStatus), kept for logging/diagnosis. Not for control flow.
  final Object? cause;

  const KeyLockedException([this.cause]);

  @override
  String toString() => 'KeyLockedException: content key is locked (app lock '
      'engaged, device not present)${cause == null ? '' : ' — $cause'}';
}

/// Thrown by [IdentityKeyManager] when the long-term identity key EXISTS but a
/// read could not return it — the platform threw (keystore/keychain error), or
/// the read came back null while the existence sentinel (or local chat data)
/// proves a key was there. It is the identity-key analogue of
/// [KeyLockedException] and exists for the same reason: keep "locked/lost"
/// strictly separate from "absent".
///
/// A null-means-absent identity read is uniquely destructive: `ensureKeyPair`
/// would mint a FRESH identity, publish it to `profiles.identity_public_key`,
/// and every peer's TOFU pin would flip to "safety number changed" — the exact
/// Galaxy 2026-07-18 regression, where Android `resetOnError:true` wiped the
/// secure-storage namespace on a transient keystore error and the identity was
/// silently re-minted.
///
/// Callers MUST treat this as DEFER, never as absence: skip signing this round
/// (register the KEM key unsigned → peer sees "unverified", not a key change),
/// retry later. NEVER mint a new identity in response. Existence is answered by
/// [IdentityKeyManager.hasKeyPair] (the ungated sentinel), which never mints.
class IdentityKeyLockedException implements Exception {
  /// The underlying cause (a PlatformException, or a short reason string) —
  /// for logging/diagnosis only, not control flow.
  final Object? cause;

  const IdentityKeyLockedException([this.cause]);

  @override
  String toString() =>
      'IdentityKeyLockedException: identity key present but unreadable — '
      'defer, do NOT re-mint${cause == null ? '' : ' ($cause)'}';
}

/// Thrown by [EncryptionKeyManager.setKeyGated] when the caller asked to bind
/// the content key to `userPresence` but the platform silently produced an
/// UNPROTECTED item — the `SecAccessControlCreateWithFlags` path returns nil
/// when the device has no biometry and no device passcode, and the plugin then
/// writes the key with no ACL and no error.
///
/// We verify the write actually attached the ACL (a UI-suppressed probe read
/// must fail with -25308); if it comes back with the value instead, the gate is
/// a no-op and we refuse to claim at-rest protection we do not have. The app
/// lock's UX challenge (local_auth / passcode) can still function — only the
/// at-rest layer is unavailable on such a device.
class KeyGatingUnavailableException implements Exception {
  final String message;
  const KeyGatingUnavailableException(this.message);

  @override
  String toString() => 'KeyGatingUnavailableException: $message';
}

/// Thrown at startup ([AppInit._initializeEncryption]) when the secure key store
/// itself is UNREADABLE — a keystore/keychain error surfaced by a read rather
/// than absence (audit #149 holistic anti-wipe).
///
/// Before #149, Android `resetOnError:true` answered such an error by wiping the
/// whole secure-storage namespace and re-generating, silently losing the
/// identity/content keys (the Galaxy 2026-07-18 re-key). With `resetOnError:false`
/// the error THROWS instead — never destructive, but if nothing catches it the
/// app would just fail to boot. This type lets the bootstrap distinguish
/// "storage unreadable" from a generic init crash and show a recovery screen
/// (restore via the recovery phrase / reinstall) instead of a blank retry.
class SecureStorageUnreadableException implements Exception {
  /// The underlying platform error, for logging/diagnosis.
  final Object? cause;

  const SecureStorageUnreadableException([this.cause]);

  @override
  String toString() =>
      'SecureStorageUnreadableException: local secure key store is unreadable'
      '${cause == null ? '' : ' ($cause)'}';
}
