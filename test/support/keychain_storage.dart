// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Separate namespace per iOS service (accountName) and class, like the
/// keychain. Non-Apple options are ignored, as on iOS.
class KeychainStorage extends Fake implements FlutterSecureStorage {
  final Map<String, Map<String, String>> spaces = {};

  static String _space(AppleOptions? o) =>
      '${o?.accountName ?? AppleOptions.defaultAccountName}|'
      '${(o?.accessibility ?? KeychainAccessibility.unlocked).name}';

  Map<String, String> _of(AppleOptions? o) =>
      spaces.putIfAbsent(_space(o), () => {});

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _of(iOptions).remove(key);
    } else {
      _of(iOptions)[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _of(iOptions)[key];

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      Map.of(_of(iOptions));

  /// Like the keychain: every class of ONE service (the default one unless
  /// [iOptions] names another). Other services stay.
  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final service = iOptions?.accountName ?? AppleOptions.defaultAccountName;
    spaces.removeWhere((space, _) => space.startsWith('$service|'));
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _of(iOptions).remove(key);
}

