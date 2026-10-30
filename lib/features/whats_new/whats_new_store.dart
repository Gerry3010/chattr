// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'whats_new_catalog.dart';
import 'whats_new_rules.dart';

/// Which "new in" cards this device has marked as read. Not a secret, so
/// plain SharedPreferences; a lost store only means a card shows once more.
class WhatsNewStore {
  static const _key = 'whats_new_seen_v1';

  Future<Set<String>> _seen() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  /// Versions whose cards are still unread, oldest first.
  Future<List<String>> unread({String? installed}) async {
    final version = installed ?? (await PackageInfo.fromPlatform()).version;
    return unreadWhatsNew(
      catalogVersions: whatsNewCatalog.keys,
      seen: await _seen(),
      installed: version,
    );
  }

  Future<void> markRead(Iterable<String> versions) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = await _seen()..addAll(versions);
    await prefs.setStringList(_key, seen.toList()..sort(compareVersions));
  }

  /// Settings → "show the news again": everything counts as unread.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final whatsNewStoreProvider = Provider<WhatsNewStore>((_) => WhatsNewStore());
