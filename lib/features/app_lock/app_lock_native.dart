// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import '../../core/security/key_locked_exception.dart';

/// Thin bridge to the iOS native app-lock unlock shim (`AppLockChannel.swift`).
///
/// The unlock challenge and the gated content-key read MUST share one
/// `LAContext` to stay a single Face ID (device-measured: a separate `local_auth`
/// prompt does not carry into a `flutter_secure_storage` read — two prompts).
/// The native side owns that context; this just invokes it.
class AppLockNativeUnlock {
  static const MethodChannel _channel =
      MethodChannel('net.geraldhofbauer.chattr/applock');

  /// Only iOS has the native shim; elsewhere the caller uses the ordinary
  /// biometric/passcode path.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Runs the device-owner-auth challenge and reads the gated content key under
  /// the same authenticated context — one prompt.
  ///
  /// Returns the key on success, or null if no gated key is present (the caller
  /// falls back to its normal read — e.g. app lock is on but the key is not yet
  /// migrated to gated). Throws [KeyLockedException] on cancel / auth failure.
  static Future<String?> unlockAndReadContentKey({
    required String reason,
  }) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<String>(
        'unlockAndReadContentKey',
        {'reason': reason},
      );
    } on PlatformException catch (e) {
      throw KeyLockedException(e);
    }
  }
}
