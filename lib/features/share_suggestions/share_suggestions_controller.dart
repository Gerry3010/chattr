// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/security_providers.dart';
import 'share_suggestions_channel.dart';

/// Switch for Share-Suggestions ("contact suggestions in the share menu").
///
/// **Default ON.** When ON, the app donates a conversation's recipient metadata
/// (name + ids + a local avatar file, never content) to the OS' **on-device**
/// suggestion store, so recent Chattr chats surface in the system share-sheet
/// suggestion row.
///
/// Donated on SENDING **and** on OPENING a chat that had something unread —
/// both directions of a conversation count. Donating only on send meant the
/// ranking saw half the traffic and Chattr lost to sparser conversations in
/// other apps (see `MessagesController._donateShareSuggestion` for why the
/// trigger is the open and not the receive).
///
/// Nothing leaves the device (no server); the metadata just enters the OS'
/// local store, and the user can turn it OFF, which wipes any donations already
/// made ([ShareSuggestionsChannel.deleteAll]). No-op on platforms without a
/// native handler.
final shareSuggestionsEnabledProvider =
    StateNotifierProvider<ShareSuggestionsController, bool>((ref) {
  return ShareSuggestionsController(ref.read(secureStorageProvider));
});

class ShareSuggestionsController extends StateNotifier<bool> {
  static const _storageKey = 'share_suggestions_enabled_v1';

  final FlutterSecureStorage _storage;

  // Completes once the persisted value has been read. The SEND path awaits this
  // (via [resolvedValue]) so a cold start never donates before we know the real
  // setting — the sync `state` is only for the settings toggle display.
  final Completer<void> _loaded = Completer<void>();

  // Default ON — an absent key means enabled; only an explicit 'false' disables.
  ShareSuggestionsController(this._storage) : super(true) {
    _init();
  }

  Future<void> _init() async {
    try {
      final raw = await _storage.read(key: _storageKey);
      if (mounted) state = raw != 'false';
    } finally {
      if (!_loaded.isCompleted) _loaded.complete();
    }
  }

  /// The persisted value, awaiting the initial secure-storage load first — use
  /// this on the SEND path so a cold start doesn't act on the stale default.
  Future<bool> resolvedValue() async {
    await _loaded.future;
    return state;
  }

  Future<void> setEnabled(bool enabled) async {
    await _storage.write(key: _storageKey, value: enabled.toString());
    state = enabled;
    // Turning it off must wipe any donations already sitting in iOS' store.
    if (!enabled) await ShareSuggestionsChannel.deleteAll();
  }
}
