// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/init/app_init.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/biometric_auth_service.dart';
import '../../core/security/encryption_key_manager.dart';
import '../../core/security/key_locked_exception.dart';
import '../../core/security/passcode_manager.dart';
import '../../core/security/security_providers.dart';
import 'app_lock_native.dart';

final passcodeManagerProvider = Provider<PasscodeManager>((ref) {
  return PasscodeManager(ref.read(secureStorageProvider));
});

final appLockControllerProvider =
    StateNotifierProvider<AppLockController, AppLockState>((ref) {
  return AppLockController(
    ref.read(secureStorageProvider),
    ref.read(passcodeManagerProvider),
    ref.read(biometricAuthServiceProvider),
    ref.read(encryptionKeyManagerProvider),
  );
});

class AppLockState {
  /// Whether the app-lock feature is enabled in settings.
  final bool enabled;

  /// Whether the app is currently locked (lock screen showing).
  final bool locked;

  /// Whether a passcode is set (drives the settings UI + lock screen input).
  final bool hasPasscode;

  /// Privacy blur while the app is merely inactive (app switcher, dialogs) —
  /// distinct from [locked], which requires re-authentication.
  final bool obscured;

  const AppLockState({
    this.enabled = false,
    this.locked = false,
    this.hasPasscode = false,
    this.obscured = false,
  });

  AppLockState copyWith({
    bool? enabled,
    bool? locked,
    bool? hasPasscode,
    bool? obscured,
  }) {
    return AppLockState(
      enabled: enabled ?? this.enabled,
      locked: locked ?? this.locked,
      hasPasscode: hasPasscode ?? this.hasPasscode,
      obscured: obscured ?? this.obscured,
    );
  }
}

/// App lock: privacy blur when the app leaves the foreground and a
/// re-authentication gate (biometrics, passcode fallback) when it comes back
/// or cold-starts. Locking also drops the cached DB encryption key and
/// re-arms the biometric session gate, so local data is not readable while
/// the lock screen is up.
class AppLockController extends StateNotifier<AppLockState> {
  static const String _enabledKey = 'app_lock_enabled_v1';

  final FlutterSecureStorage _storage;
  final PasscodeManager _passcodes;
  final BiometricAuthService _biometrics;
  final EncryptionKeyManager _keyManager;

  AppLockController(
    this._storage,
    this._passcodes,
    this._biometrics,
    this._keyManager,
  ) : super(AppLockState(
          // Start already locked if app lock was engaged at cold start (resolved
          // in AppInit before runApp). The first frame must render locked, not
          // flash the chat list before an async keychain read flips it.
          enabled: AppInit.appLockEngagedAtStartup,
          locked: AppInit.appLockEngagedAtStartup,
        )) {
    _init();
  }

  Future<void> _init() async {
    final enabledFlag = (await _storage.read(key: _enabledKey)) == 'true';
    // Reconcile a possible crash between setKeyGated() and the _enabledKey write
    // during enable: that leaves the key GATED but the flag false. If we trusted
    // the flag alone the gate would show no lock screen, yet getKey would hit the
    // gated item once the keychain grace window lapses → KeyLockedException in
    // the decrypt paths with no way to unlock = soft-lockout. A gated key MUST
    // imply app-lock-on, so derive the effective state from BOTH and heal the
    // flag. (The disable path clears the marker before the flag, so it is already
    // safe the other way.)
    final gated = await _keyManager.isKeyGated();
    final enabled = enabledFlag || gated;
    if (enabled && !enabledFlag) {
      await _storage.write(key: _enabledKey, value: 'true');
    }
    final hasPasscode = await _passcodes.hasPasscode();
    if (!mounted) return;
    // Cold start with the lock enabled starts locked.
    state = AppLockState(
      enabled: enabled,
      locked: enabled,
      hasPasscode: hasPasscode,
    );
  }

  /// Enable requires an unlock method (biometrics available or passcode set);
  /// callers ensure a passcode exists first on biometrics-less devices.
  ///
  /// Enabling also binds the content key to the keychain `userPresence` ACL —
  /// the at-rest layer (iOS), atomically verified via a real unlock round-trip
  /// ([EncryptionKeyManager.setKeyGated]). If the device cannot gate the key, or
  /// the native unlock path cannot read it back, that throws
  /// [KeyGatingUnavailableException]; we let it propagate WITHOUT flipping the
  /// enabled flag, so app lock is never turned on over a gated-but-unreadable
  /// key that would lock the user out of their whole message DB. Off iOS,
  /// [EncryptionKeyManager.setKeyGated] is a no-op and this is just the UI gate.
  Future<void> setEnabled(bool enabled, {String? unlockReason}) async {
    if (enabled) {
      await _keyManager.setKeyGated(
        true,
        verifyReadBack: (expectedKey) async {
          final readBack = await AppLockNativeUnlock.unlockAndReadContentKey(
            reason: unlockReason ?? 'Unlock Chattr',
          );
          return readBack == expectedKey;
        },
      );
    } else {
      await _keyManager.setKeyGated(false);
    }
    await _storage.write(key: _enabledKey, value: enabled.toString());
    if (!mounted) return;
    state = state.copyWith(enabled: enabled, locked: false);
  }

  Future<void> setPasscode(String passcode) async {
    await _passcodes.setPasscode(passcode);
    state = state.copyWith(hasPasscode: true);
  }

  /// Removing the passcode also disables the lock when no biometrics exist —
  /// otherwise the next lock would be unopenable.
  Future<void> removePasscode() async {
    await _passcodes.removePasscode();
    var enabled = state.enabled;
    if (enabled && !await _biometrics.isAvailable()) {
      await _storage.write(key: _enabledKey, value: 'false');
      enabled = false;
    }
    state = state.copyWith(hasPasscode: false, enabled: enabled);
  }

  /// App went to background: lock (if enabled) and drop unlocked key state.
  void lock() {
    if (!state.enabled || state.locked) return;
    BiometricAuthService.resetSession();
    _keyManager.clearCache();
    state = state.copyWith(locked: true, obscured: false);
    logger.info('App locked', tag: 'AppLock');
  }

  /// Privacy blur only (momentarily inactive, e.g. app switcher preview).
  void setObscured(bool obscured) {
    if (!state.enabled) return;
    if (state.obscured == obscured) return;
    state = state.copyWith(obscured: obscured);
  }

  Future<bool> unlockWithBiometrics({required String localizedReason}) async {
    // iOS + a gated key: one native LAContext runs the challenge AND reads the
    // key back (a single Face ID — a separate local_auth prompt does NOT carry
    // into the keychain read, device-measured). Prime the cache so the next
    // decrypt does not prompt again.
    if (AppLockNativeUnlock.isSupported && await _keyManager.isKeyGated()) {
      try {
        final key = await AppLockNativeUnlock.unlockAndReadContentKey(
          reason: localizedReason,
        );
        if (key != null) {
          _keyManager.primeCache(key);
          if (mounted) state = state.copyWith(locked: false, obscured: false);
          return true;
        }
        // Marker says gated but the shim found no gated key — fall through to
        // the biometric gate rather than get stuck locked.
      } on KeyLockedException {
        return false; // cancelled / auth failed → stay locked
      }
    }

    final ok = await _biometrics.authenticate(localizedReason: localizedReason);
    if (ok && mounted) {
      state = state.copyWith(locked: false, obscured: false);
    }
    return ok;
  }

  Future<bool> unlockWithPasscode(String passcode) async {
    final ok = await _passcodes.verifyPasscode(passcode);
    if (!ok) return false;
    // Warm the content-key cache so the next decrypt does not trigger a second
    // (device-auth) prompt. getKey caches internally on success; on iOS+gated
    // the app passcode cannot itself satisfy the userPresence ACL, but inside
    // the post-unlock grace window the read is silent. If the grace has lapsed
    // it throws — best-effort, leave it uncached and the decrypt paths surface
    // the lock again.
    try {
      await _keyManager.getKey(requireBiometric: false);
    } on KeyLockedException {
      // best-effort priming only.
    }
    if (mounted) {
      state = state.copyWith(locked: false, obscured: false);
    }
    return true;
  }

  Future<bool> biometricsAvailable() => _biometrics.isAvailable();

  /// Safety hatch: the lock is showing but NO unlock method exists anymore
  /// (biometrics revoked at OS level after the passcode was removed). Never
  /// leave the user locked out of their own data.
  void forceUnlockWithoutMethod() {
    if (!state.locked || state.hasPasscode) return;
    logger.warning('App lock has no unlock method — releasing', tag: 'AppLock');
    state = state.copyWith(locked: false, obscured: false);
  }
}
