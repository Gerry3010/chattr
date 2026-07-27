// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/logging/logger_service.dart';
import '../../core/security/security_providers.dart';

/// Screenshot / screen-recording protection (Android FLAG_SECURE). When on,
/// the OS blocks screenshots and recording and hides the app in the
/// recent-apps preview. iOS has no direct equivalent (handled natively by the
/// Apple dev, if at all); the platform channel simply no-ops elsewhere.
final screenSecurityProvider =
    StateNotifierProvider<ScreenSecurityController, bool>((ref) {
  return ScreenSecurityController(ref.read(secureStorageProvider));
});

class ScreenSecurityController extends StateNotifier<bool> {
  static const _channel = MethodChannel('chattr/screen_security');
  static const _storageKey = 'screen_security_enabled_v1';

  final FlutterSecureStorage _storage;

  ScreenSecurityController(this._storage) : super(false) {
    _init();
  }

  Future<void> _init() async {
    final enabled = (await _storage.read(key: _storageKey)) == 'true';
    if (!mounted) return;
    state = enabled;
    if (enabled) await _apply(true);
  }

  Future<void> setEnabled(bool enabled) async {
    await _storage.write(key: _storageKey, value: enabled.toString());
    state = enabled;
    await _apply(enabled);
  }

  /// Force screenshot/recording protection ON for the duration of [action],
  /// then restore the user's persisted preference — regardless of whether they
  /// have the setting enabled. Used to shield a one-time secret reveal (e.g. the
  /// recovery phrase, audit L2) even on a default install. Does NOT persist.
  Future<T> secureWhile<T>(Future<T> Function() action) async {
    await _apply(true);
    try {
      return await action();
    } finally {
      // Revert to the user's actual preference (off unless they enabled it).
      await _apply(state);
    }
  }

  Future<void> _apply(bool secure) async {
    try {
      await _channel.invokeMethod<bool>('setSecure', secure);
    } on MissingPluginException {
      // No native handler (iOS/desktop) — silently ignore.
    } catch (e) {
      logger.warning('setSecure failed: $e', tag: 'ScreenSecurity');
    }
  }
}
