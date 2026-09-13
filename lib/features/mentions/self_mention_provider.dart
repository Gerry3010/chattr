// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../chats/chats_controller.dart';
import '../profiles/profile_helpers.dart';
import 'mention_utils.dart';

/// The `@`-tokens that mean „you" in one chat — the reader's own handle plus
/// the group keyword for their role in *this* chat.
///
/// Role-dependent, hence per chat: the same person can be admin in one group
/// and a plain member in the next, so `@admins` means them here and not there.
///
/// Synchronous on purpose. It drives the in-bubble highlight, which is rebuilt
/// for every message on every frame — a `FutureProvider` would make mentions
/// flicker in unhighlighted on each rebuild.
final selfMentionTokensProvider = Provider.autoDispose.family<Set<String>, String>(
  (ref, chatId) {
    final myId = ref.watch(authControllerProvider);
    if (myId == null) return const {};
    final myUsername = ref.watch(usernameProvider(myId));

    // Re-read on any chat-list change: being promoted to admin flips whether
    // `@admins` means the reader.
    final chats = ref.watch(chatsControllerProvider);
    var isAdmin = false;
    for (final c in chats) {
      if (c.id == chatId) {
        isAdmin = c.isAdmin(myId);
        break;
      }
    }

    // Agent accounts answer to `@agents` regardless of their role. The flag
    // lives on the profile, so a reader whose own profile has not loaded yet
    // simply is not an agent for this frame — the highlight fills in with the
    // rest of the profile.
    final isAgent = ref.watch(profileProvider(myId))?.isAgent ?? false;

    return selfMentionTokens(myUsername, isAdmin: isAdmin, isAgent: isAgent);
  },
);
