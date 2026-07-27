// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/legacy.dart';

/// Tracks chats whose local KEM **private** key is missing while the public key
/// is still registered on the server — i.e. secure storage was wiped but we had
/// already published a key (the Galaxy `resetOnError` deleteAll class, #149).
///
/// We deliberately do NOT silently re-mint in that state: a fresh key can't
/// decrypt in-flight ciphertext AND fires a false `keys_rotated` alarm to every
/// peer. Instead the key-registration paths flag the chat here, and the chat
/// view surfaces a banner (#11) offering the user to rotate a new key on
/// purpose (which re-establishes decryptable messaging going forward).
class LostKeysNotifier extends StateNotifier<Set<String>> {
  LostKeysNotifier() : super(const {});

  /// Flag [chatId] as having a lost local key (idempotent).
  void markLost(String chatId) {
    if (state.contains(chatId)) return;
    state = {...state, chatId};
  }

  /// Clear the flag once the user has rotated a fresh key (or it recovered).
  void clear(String chatId) {
    if (!state.contains(chatId)) return;
    state = {...state}..remove(chatId);
  }

  bool isLost(String chatId) => state.contains(chatId);
}

/// Session-scoped set of chats with a lost local KEM key (#11). Not persisted —
/// re-derived on the next key-registration pass after a restart.
final lostKeysProvider =
    StateNotifierProvider<LostKeysNotifier, Set<String>>(
  (ref) => LostKeysNotifier(),
);
