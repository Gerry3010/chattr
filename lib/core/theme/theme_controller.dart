// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../security/security_providers.dart';
import 'app_theme.dart';

/// Selected app theme, persisted in secure storage.
final themeControllerProvider =
    StateNotifierProvider<ThemeController, AppTheme>((ref) {
  return ThemeController(ref.read(secureStorageProvider));
});

class ThemeController extends StateNotifier<AppTheme> {
  final FlutterSecureStorage _storage;
  static const _key = 'app_theme';

  ThemeController(this._storage) : super(AppTheme.system) {
    _load();
  }

  Future<void> _load() async {
    final value = await _storage.read(key: _key);
    state = AppTheme.values.firstWhere(
      (t) => t.name == value,
      orElse: () => AppTheme.system,
    );
  }

  Future<void> setTheme(AppTheme theme) async {
    state = theme;
    await _storage.write(key: _key, value: theme.name);
  }

  /// Quick light/dark flip ([currentBrightness] is the resolved brightness).
  Future<void> toggle(Brightness currentBrightness) async {
    await setTheme(
      currentBrightness == Brightness.dark ? AppTheme.light : AppTheme.dark,
    );
  }
}
