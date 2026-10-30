// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reaction a double tap on a photo or video sets (CHAT-15).
///
/// ❤️ by default, changeable in the settings through the same emoji picker as
/// the "+" in the message menu (Gerry, 2026-10-28). Stored exactly as picked:
/// reactions are compared by their text, so a re-composed character would no
/// longer match and could not be taken back with a second double tap.
final doubleTapReactionProvider =
    NotifierProvider<DoubleTapReactionController, String>(
  DoubleTapReactionController.new,
);

class DoubleTapReactionController extends Notifier<String> {
  static const storageKey = 'double_tap_reaction_v1';
  static const fallback = '❤️';

  @override
  String build() {
    unawaited(_load());
    return fallback;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(storageKey);
      if (ref.mounted && stored != null && stored.isNotEmpty) state = stored;
    } catch (_) {
      // Unreadable: stay at the default.
    }
  }

  Future<void> set(String emoji) async {
    if (emoji.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, emoji);
    state = emoji;
  }
}
