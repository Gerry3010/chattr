// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'biometric_auth_service.dart';
import 'key_locked_exception.dart';

/// Encryption Key Manager
///
/// Manages the local database (content) encryption key in secure storage.
///
/// **App lock / at-rest (audit M6/M7).** When app lock is enabled, the key is
/// re-written bound to the iOS keychain `userPresence` access-control, so a
/// non-interactive read (forensic extraction, a background task while the device
/// is locked) fails with -25308 instead of handing over the key. This is the
/// at-rest layer; the interactive unlock challenge on resume is a separate
/// `local_auth` prompt owned by the app-lock controller (the ACL alone does not
/// reliably prompt on an already-unlocked device — device-measured grace
/// window). See [setKeyGated] and `docs`/memory `m6m7-keychain-acl-enforcement`.
class EncryptionKeyManager {
  static const String _keyStorageKey = 'encryption_key_v1';

  /// Marks "a content key exists", so [hasKey] never has to touch the key
  /// itself (audit M6/M7).
  ///
  /// Once app lock is on, the key sits behind a keychain ACL: reading it demands
  /// device presence. But [hasKey] runs during app init, before any UI — and its
  /// answer feeds `if (!hasKey) generateKey()` (app_init.dart:130), which
  /// OVERWRITES the key. A locked read that got mistaken for "no key" would
  /// therefore wipe every stored message. Reading a separate, deliberately
  /// unprotected marker keeps that question answerable without a prompt and
  /// without ever risking the wrong answer.
  ///
  /// It carries no secret — only that this install has a key at all, which is
  /// hardly a revelation for a chat app.
  static const String _keySentinel = 'encryption_key_v1_exists';

  /// Ungated marker recording whether the key is CURRENTLY written with the
  /// `userPresence` ACL. Like the sentinel it is never gated, so writers can
  /// consult it without a prompt. Its whole job is to keep [generateKey] /
  /// [importKey] from silently DOWNGRADING a gated key back to ungated when they
  /// rewrite it.
  static const String _keyGatedMarker = 'encryption_key_gated_v1';

  /// The raw `kSecUseAuthenticationUI` value that turns "needs presence" into an
  /// error instead of a prompt — device-measured on an iPhone 16 Pro; `"fail"`
  /// does NOT arm it (see memory `m6m7-keychain-acl-enforcement`). Used only by
  /// the silent-downgrade verification, never on a real getKey.
  static const String _uiSuppress = 'u_AuthUIF';

  final FlutterSecureStorage _storage;
  // Retained for constructor compatibility / future use. The interactive
  // biometric challenge lives in the app-lock controller (local_auth), NOT here:
  // gating the key with an OS ACL and ALSO prompting via local_auth on the same
  // read would double-prompt, and the ACL does not reliably prompt anyway.
  // ignore: unused_field
  final BiometricAuthService _biometricAuth;

  /// Session cache of the unlocked key, so we don't trigger a biometric /
  /// keychain prompt on every read. Dropped by [clearCache] on app lock.
  String? _cachedKey;

  EncryptionKeyManager(this._storage, this._biometricAuth);

  static bool get _isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Generate a new AES-256 encryption key
  Future<String> generateKey() async {
    // Generate 32 random bytes (256 bits)
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));

    // Convert to base64 for storage
    final key = base64.encode(bytes);

    await _writeKeyAndSentinel(key, gated: await isKeyGated());
    _cachedKey = key;
    return key;
  }

  /// Store the key plus its existence marker, **sentinel first**.
  ///
  /// The order is the whole safety property, so it is worth spelling out. A
  /// crash between the two writes leaves either:
  ///   sentinel, no key  → [hasKey] says true → nobody calls [generateKey] →
  ///                       the app fails loudly and nothing was overwritten.
  ///   key, no sentinel  → [hasKey] says false → [generateKey] overwrites the
  ///                       key we just wrote.
  ///
  /// The second looks harmless for a fresh install (the key was new and unused),
  /// which is exactly the trap: [importKey] runs the same path with a key
  /// RESTORED FROM A BACKUP (backup_service.dart:217). Overwriting that one
  /// destroys the history the user was in the middle of rescuing. So we take the
  /// order that fails visibly over the one that fails silently.
  Future<void> _writeKeyAndSentinel(String key, {required bool gated}) async {
    await _storage.write(
      key: _keySentinel,
      value: '1',
      iOptions: _getSentinelIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
    await _storage.write(
      key: _keyStorageKey,
      value: key,
      iOptions: gated ? _getGatedIOSOptions() : _getIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
  }

  /// Get the content key.
  ///
  /// Contract (audit M6/M7):
  ///  * key present & readable → returns it (and caches it for the session),
  ///  * key present but LOCKED → throws [KeyLockedException] — NEVER null,
  ///    NEVER cached. Null would read as "no key" and wipe/drop data.
  ///  * key genuinely absent    → returns null (callers already handle this).
  ///
  /// [requireBiometric] is retained for source compatibility; the interactive
  /// unlock challenge is owned by the app-lock controller, so all callers pass
  /// false and this does not prompt.
  Future<String?> getKey({bool requireBiometric = true}) async {
    // Reuse the session-cached key if already unlocked — avoids a keychain
    // prompt on every read.
    if (_cachedKey != null) return _cachedKey;

    // The read options match the ungated write's ACCESSIBILITY exactly
    // (`first_unlock_this_device`) whether or not the key is gated — gating only
    // adds `accessControlFlags`, which is not a search constraint. Keeping the
    // accessibility CONSTANT across the gated/ungated states is deliberate: a
    // mismatched accessibility is the M5 trap where a read misses the item and a
    // false "absent" wipes it.
    String? key;
    try {
      key = await _storage.read(
        key: _keyStorageKey,
        iOptions: _getIOSOptions(),
        aOptions: _getAndroidOptions(),
        lOptions: _getLinuxOptions(),
      );
    } on PlatformException catch (e) {
      // A gated key that isn't currently unlockable (background / device not
      // present) throws instead of returning null. Surface it typed so the lock
      // layer can defer; do NOT cache and do NOT fall through to null.
      throw KeyLockedException(e);
    }

    _cachedKey = key;
    return key;
  }

  /// Write a specific key value back into secure storage (used by restore — the
  /// key is recovered from a backup, not freshly generated). Preserves the
  /// current gating so a restore does not silently downgrade a gated key, and
  /// refreshes the session cache.
  Future<void> importKey(String key) async {
    await _writeKeyAndSentinel(key, gated: await isKeyGated());
    _cachedKey = key;
  }

  /// Whether the stored key is currently bound to the `userPresence` ACL.
  /// Reads the ungated marker, so it never prompts.
  Future<bool> isKeyGated() async {
    final marker = await _storage.read(
      key: _keyGatedMarker,
      iOptions: _getSentinelIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
    return marker == '1';
  }

  /// Bind (or unbind) the content key to the keychain `userPresence` ACL — the
  /// at-rest layer of app lock. Idempotent; a no-op off iOS (only iOS keychain
  /// ACLs are device-verified here).
  ///
  /// Enabling rewrites the key WITH the ACL first, then sets the marker; if it
  /// crashes between, the marker is absent so [isKeyGated] reports false and the
  /// UI understates rather than overstates protection. Disabling clears the
  /// marker first, then rewrites ungated — same fail-toward-not-claiming bias.
  ///
  /// After a successful enable it runs TWO verifications before committing the
  /// gated state, because a half-verified enable can lock the user out of the
  /// entire message DB (the key is present but unreadable):
  ///  1. the ACL actually attached — a UI-suppressed probe read must fail with
  ///     -25308 (else the platform silently produced an unprotected item, e.g.
  ///     no device biometry/passcode),
  ///  2. [verifyReadBack] — the REAL unlock path can read the key back. The
  ///     gated write goes through this plugin but the unlock read goes through a
  ///     native shim; if their keychain query schemas ever drift, the shim finds
  ///     nothing and the user is locked out. Passing a round-trip that exercises
  ///     the shim on THIS device/schema catches that before it is too late.
  ///
  /// If either check fails it rolls the key back to ungated, leaves the marker
  /// off, and throws [KeyGatingUnavailableException]. It NEVER leaves a
  /// gated-but-unreadable key behind.
  Future<void> setKeyGated(
    bool gated, {
    Future<bool> Function(String expectedKey)? verifyReadBack,
  }) async {
    if (!_isIOS) return; // ACL binding is iOS-only for now (device-verified).
    if (await isKeyGated() == gated) return;

    // Read the current key while it is still reachable (foreground, unlocked).
    final key = await getKey(requireBiometric: false);
    if (key == null) {
      // No key to gate yet. Only the DISABLE direction is safe to record here:
      // clearing the marker cannot create a lockout. We must NOT optimistically
      // mark "gated" without a key present — a later generateKey would then
      // write the key gated WITHOUT the enable-time _gatedItemEnforces /
      // verifyReadBack checks, risking a gated-but-unverifiable key. (Unreachable
      // in practice: a content key always exists before Settings can toggle.)
      if (!gated) await _setGatedMarker(false);
      return;
    }

    if (gated) {
      await _storage.write(
        key: _keyStorageKey,
        value: key,
        iOptions: _getGatedIOSOptions(),
        aOptions: _getAndroidOptions(),
        lOptions: _getLinuxOptions(),
      );

      Future<Never> rollback(String why) async {
        await _storage.write(
          key: _keyStorageKey,
          value: key,
          iOptions: _getIOSOptions(),
          aOptions: _getAndroidOptions(),
          lOptions: _getLinuxOptions(),
        );
        throw KeyGatingUnavailableException(why);
      }

      if (!await _gatedItemEnforces()) {
        // Silent downgrade: the ACL never attached (no device auth).
        await rollback(
          'Keychain refused the userPresence ACL — the device has no biometry '
          'or passcode, so at-rest key protection is unavailable.',
        );
      }
      // Verify the REAL unlock path can read the just-gated key back. A false
      // return OR a throw (e.g. the user cancels the round-trip auth) both mean
      // "not proven readable" — either way we must undo before committing, or a
      // schema drift / cancelled verify could leave the user locked out.
      var readBackOk = verifyReadBack == null;
      if (verifyReadBack != null) {
        try {
          readBackOk = await verifyReadBack(key);
        } catch (_) {
          readBackOk = false;
        }
      }
      if (!readBackOk) {
        await rollback(
          'The unlock round-trip failed — the native read could not retrieve '
          'the gated key, so enabling app lock would lock you out. Rolled back.',
        );
      }
      await _setGatedMarker(true);
    } else {
      await _setGatedMarker(false);
      await _storage.write(
        key: _keyStorageKey,
        value: key,
        iOptions: _getIOSOptions(),
        aOptions: _getAndroidOptions(),
        lOptions: _getLinuxOptions(),
      );
    }
    // The cache still holds the plaintext key; the next read after a lock's
    // clearCache() re-hits the (now gated) item.
  }

  Future<void> _setGatedMarker(bool gated) async {
    if (gated) {
      await _storage.write(
        key: _keyGatedMarker,
        value: '1',
        iOptions: _getSentinelIOSOptions(),
        aOptions: _getAndroidOptions(),
        lOptions: _getLinuxOptions(),
      );
    } else {
      await _storage.delete(
        key: _keyGatedMarker,
        iOptions: _getSentinelIOSOptions(),
        aOptions: _getAndroidOptions(),
        lOptions: _getLinuxOptions(),
      );
    }
  }

  /// The silent-downgrade check: a UI-suppressed read of the just-gated key must
  /// FAIL (interactionNotAllowed) for the ACL to be real. If it returns the
  /// value, `SecAccessControlCreateWithFlags` handed back an unprotected item.
  Future<bool> _gatedItemEnforces() async {
    try {
      final value = await _storage.read(
        key: _keyStorageKey,
        iOptions: _getGatedProbeIOSOptions(),
        aOptions: _getAndroidOptions(),
        lOptions: _getLinuxOptions(),
      );
      // A value came back with the UI suppressed → no ACL is enforcing.
      return value == null;
    } on PlatformException {
      // -25308 / interactionNotAllowed → the ACL is real and enforcing.
      return true;
    }
  }

  /// Check if encryption key exists.
  ///
  /// Reads the unprotected sentinel rather than the key. The old version read
  /// the key itself and already carried a scar from it: get the platform options
  /// wrong and the read misses the item, hasKey returns false on every launch,
  /// and generateKey silently overwrites a key that was there all along.
  ///
  /// App lock (M6/M7) would reopen that wound in a new way — a locked key read
  /// throws or prompts, and neither answer belongs in a boolean this early in
  /// startup. The sentinel sidesteps the question: it is never gated, so it
  /// answers "does a key exist" without authentication and without the key.
  ///
  /// Keep it that way. Anything that reads the key here can only be wrong.
  Future<bool> hasKey() async {
    final marker = await _storage.read(
      key: _keySentinel,
      iOptions: _getSentinelIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
    if (marker != null) return true;

    // No sentinel: either a genuinely fresh install, or an install predating the
    // sentinel. Fall back to the key read (never gated before app lock exists,
    // so it cannot prompt) and adopt it, so an upgrade does not look empty.
    final key = await _storage.read(
      key: _keyStorageKey,
      iOptions: _getIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
    if (key == null) return false;

    await _storage.write(
      key: _keySentinel,
      value: '1',
      iOptions: _getSentinelIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
    return true;
  }

  /// Drop the session-cached key (app lock): the next read re-authenticates.
  /// The key itself stays in secure storage.
  void clearCache() {
    _cachedKey = null;
  }

  /// Seed the session cache with a key obtained out-of-band. The native app-lock
  /// unlock shim reads the gated key under its own authenticated LAContext (one
  /// Face ID for challenge + read) and hands the plaintext here, so the next
  /// [getKey] returns it without prompting a SECOND time. Only trusted callers
  /// (the unlock flow) should use this.
  void primeCache(String key) {
    _cachedKey = key;
  }

  /// Delete encryption key
  Future<void> deleteKey() async {
    _cachedKey = null;
    // Order does not matter here — a wipe is deliberate, so a half-done one is
    // still a wipe. But the sentinel MUST go too: leaving it behind would make
    // [hasKey] claim a key that no longer exists, and startup would then skip
    // generateKey and come up with no key at all.
    await _storage.delete(
      key: _keyStorageKey,
      iOptions: _getIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
    await _storage.delete(
      key: _keySentinel,
      iOptions: _getSentinelIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
    await _storage.delete(
      key: _keyGatedMarker,
      iOptions: _getSentinelIOSOptions(),
      aOptions: _getAndroidOptions(),
      lOptions: _getLinuxOptions(),
    );
  }

  /// iOS options for the (ungated) key, and for EVERY read of the key. Gating
  /// only ADDS `accessControlFlags` on the write; the accessibility stays
  /// `first_unlock_this_device` in both states so reads never mismatch.
  IOSOptions _getIOSOptions() {
    return const IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      accountName: 'chattr_encryption',
    );
  }

  /// iOS options for the GATED key write: same account + accessibility, plus the
  /// `userPresence` access-control. The matrix on Gerry's iPhone proved
  /// `first_unlock_this_device` + `userPresence` enforces (-25308 under a
  /// suppressed-UI read), so we keep the accessibility constant rather than move
  /// to `unlocked_this_device` and risk an accessibility-mismatch read.
  IOSOptions _getGatedIOSOptions() {
    return const IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      accountName: 'chattr_encryption',
      accessControlFlags: [AccessControlFlag.userPresence],
    );
  }

  /// Gated read with the auth-UI suppressed — used ONLY to verify the ACL
  /// attached. On a real gated item this errors (-25308); on a silently
  /// unprotected one it returns the value.
  IOSOptions _getGatedProbeIOSOptions() {
    return const IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      accountName: 'chattr_encryption',
      accessControlFlags: [AccessControlFlag.userPresence],
      authenticationUIBehavior: _uiSuppress,
    );
  }

  /// Options for the existence + gating markers: same account, deliberately
  /// never gated.
  ///
  /// Their entire job is to be readable when the key is not — during app init,
  /// before any unlock UI. Adding an ACL here would defeat the purpose and
  /// re-open the startup-wipe path this exists to close.
  IOSOptions _getSentinelIOSOptions() {
    return const IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      accountName: 'chattr_encryption',
    );
  }

  /// Android-specific options (biometric protection)
  AndroidOptions _getAndroidOptions() {
    // #149 holistic anti-wipe: resetOnError MUST stay false. With `true`, a
    // Keystore decrypt error made flutter_secure_storage silently wipe the whole
    // namespace and re-key — destroying the content key (the Galaxy 2026-07-18
    // re-key). With `false` such an error THROWS instead; AppInit catches it as a
    // SecureStorageUnreadableException and routes to the recovery screen rather
    // than a destructive reset. (Android-only flag — a no-op on iOS/macOS, whose
    // Keychain reads already throw on error via the darwin plugin.)
    return const AndroidOptions(
      resetOnError: false,
    );
  }

  /// Linux-specific options
  LinuxOptions _getLinuxOptions() {
    return const LinuxOptions();
  }
}
