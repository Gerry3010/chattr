// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';

/// Global (not per-chat — a per-chat toggle would confuse users) switch for the
/// composer's Markdown formatting bar. Default OFF: the bar is hidden until the
/// user enables it from the composer context menu. Markdown *rendering* of
/// received/sent messages is independent of this and always works.
final markdownBarEnabledProvider =
    StateNotifierProvider<MarkdownBarController, bool>((ref) {
  return MarkdownBarController(ref.read(secureStorageProvider));
});

class MarkdownBarController extends StateNotifier<bool> {
  static const _storageKey = 'markdown_bar_enabled_v1';

  final FlutterSecureStorage _storage;

  // Default OFF: an absent key means hidden — only an explicit 'true' shows it.
  MarkdownBarController(this._storage) : super(false) {
    _init();
  }

  Future<void> _init() async {
    final raw = await _storage.read(key: _storageKey);
    if (mounted) state = raw == 'true';
  }

  Future<void> setEnabled(bool enabled) async {
    await _storage.write(key: _storageKey, value: enabled.toString());
    state = enabled;
  }

  Future<void> toggle() => setEnabled(!state);
}
