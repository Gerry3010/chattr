// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../push_notifications/push_cache_bridge_ios.dart';

/// Whether iOS lists Chattr calls in the Phone app's Recents (CHAT-38).
///
/// CallKit does that by default, with the chat name, and Recents travel to
/// every device on the same Apple account through iCloud: a list of who called
/// when, outside Chattr. On by default (Gerry, 2026-10-28), because that is what
/// people expect from a phone call; the switch takes Chattr out.
///
/// SharedPreferences rather than secure storage: it is not a secret, and the
/// background isolate that rings a call reads it. On iOS the value is also
/// mirrored into the App Group, because the VoIP push is reported to CallKit
/// natively before any Dart runs (AppDelegate.swift).
final callsInRecentsProvider =
    NotifierProvider<CallsInRecentsController, bool>(
  CallsInRecentsController.new,
);

class CallsInRecentsController extends Notifier<bool> {
  static const storageKey = 'calls_in_recents_v1';

  /// The stored value; the default when nothing is stored or it is unreadable.
  static Future<bool> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(storageKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  @override
  bool build() {
    unawaited(_load());
    return true;
  }

  Future<void> _load() async {
    final value = await read();
    if (!ref.mounted) return;
    state = value;
    // Re-publish on every start, so an App Group that lost it (reinstall,
    // first run after the update) is set again.
    await mirrorCallsInRecentsForAppGroup(value);
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(storageKey, enabled);
    state = enabled;
    await mirrorCallsInRecentsForAppGroup(enabled);
  }
}
