// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:local_auth/local_auth.dart';

import '../logging/logger_service.dart';

/// Biometric Authentication Service
///
/// Handles biometric authentication (fingerprint, face ID, etc.)
class BiometricAuthService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Once the user authenticates successfully, skip further prompts for the rest
  /// of the app session. Callers (chats/messages controllers) authenticate on
  /// every chat open — without this gate that spams Face ID / macOS auth on each
  /// open. Static so it holds across all service instances. Reset on logout.
  static bool _sessionAuthenticated = false;

  /// A single in-flight (non-forced) prompt, shared by concurrent callers.
  /// A cold start races two unlock triggers — the lock screen's initState and
  /// the lifecycle-resume gate — and `local_auth` throws `authInProgress` for
  /// the SECOND concurrent `authenticate()`, which the lock screen renders as a
  /// spurious "Fehlgeschlagen" until the user taps retry (Galaxy 2026-07-19).
  /// Coalescing onto one attempt makes both callers await the same real result.
  /// Static so it holds across all service instances (like [_sessionAuthenticated]).
  static Future<bool>? _pending;

  /// Clear the session gate (call on logout / app lock) so access re-prompts.
  static void resetSession() => _sessionAuthenticated = false;

  /// Check if biometric authentication is available
  Future<bool> isAvailable() async {
    try {
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    } catch (e) {
      return false;
    }
  }

  /// Get list of available biometric types
  Future<List<BiometricType>> getSupportedTypes() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  /// Authenticate user with biometrics.
  /// Returns true if authentication was successful.
  ///
  /// [forcePrompt] bypasses the session cache for a fresh re-auth gate on a
  /// sensitive surface (e.g. the dev log) — it neither short-circuits on a prior
  /// unlock nor writes the cache, so it never weakens or is weakened by the
  /// normal chat-open gate. On devices without usable biometrics it still
  /// returns true (there is no passcode fallback yet).
  Future<bool> authenticate({
    String localizedReason = 'Please authenticate to access your chats',
    bool forcePrompt = false,
  }) async {
    // Already unlocked this session — don't prompt again (unless forced).
    if (!forcePrompt && _sessionAuthenticated) return true;

    // forcePrompt (dev-log re-auth) always runs its own attempt so it can't be
    // satisfied by a concurrent normal unlock's cached result.
    if (forcePrompt) return _authenticateOnce(localizedReason, true);

    // Coalesce concurrent normal prompts onto one attempt (avoids the
    // cold-start `authInProgress` → spurious "Fehlgeschlagen"; see [_pending]).
    final pending = _pending;
    if (pending != null) return pending;
    final attempt = _authenticateOnce(localizedReason, false);
    _pending = attempt;
    try {
      return await attempt;
    } finally {
      _pending = null;
    }
  }

  Future<bool> _authenticateOnce(String localizedReason, bool forcePrompt) async {
    try {
      // Check if biometrics are available
      final isAvailable =
          await this.isAvailable() && (await getSupportedTypes()).isNotEmpty;
      if (!isAvailable) {
        // TODO: Return true for now, until we make a passcode
        if (!forcePrompt) _sessionAuthenticated = true;
        return true;
      }

      // Attempt authentication. persistAcrossBackgrounding is the local_auth 3
      // name for stickyAuth; PIN/password fallback stays allowed
      // (biometricOnly: false is the default).
      final authenticated = await _auth.authenticate(
        localizedReason: localizedReason,
        persistAcrossBackgrounding: true,
      );

      if (authenticated && !forcePrompt) _sessionAuthenticated = true;
      return authenticated;
    } on LocalAuthException catch (e) {
      // No usable biometrics, lockout, cancel … — all mean "not authenticated".
      // MUST be logged: a plugin-level failure here (e.g. MainActivity not
      // being a FragmentActivity) silently locks the user out of all data.
      logger.warning('Biometric authentication failed', error: e);
      return false;
    } catch (e) {
      logger.warning('Biometric authentication error', error: e);
      return false;
    }
  }

  /// Stop any ongoing authentication
  Future<void> stopAuthentication() async {
    try {
      await _auth.stopAuthentication();
    } catch (e) {
      // Ignore errors
    }
  }
}
