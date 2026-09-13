// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../chats/chats_controller.dart';
import '../messages/messages_local_provider.dart';
import '../profiles/profile_helpers.dart';
import 'mention_utils.dart';

/// Whether a chat has at least one UNREAD (by me) message from someone else that
/// @-mentions the current user — drives the chat-list @-marker (1.10).
///
/// Content-derived (the server can't read encrypted messages), so it scans the
/// local decrypted messages. Callers gate it on `chat.unreadCount > 0` so it
/// only decrypts chats that actually have unread messages, and so the marker
/// disappears the moment the chat is read (unread count → 0). It re-watches the
/// chats list so it recomputes when a new message arrives or a chat is read.
final unreadMentionProvider = FutureProvider.autoDispose.family<bool, String>((
  ref,
  chatId,
) async {
  // Recompute on any chat-list change (new message / read receipts update it).
  final chats = ref.watch(chatsControllerProvider);

  final myId = ref.watch(authControllerProvider);
  if (myId == null) return false;
  final myUsername = ref.watch(usernameProvider(myId));

  // My role in this chat decides whether @admins / @members target me.
  var isAdmin = false;
  for (final c in chats) {
    if (c.id == chatId) {
      isAdmin = c.isAdmin(myId);
      break;
    }
  }

  final repo = ref.read(messagesLocalRepositoryProvider);
  final messages = await repo.loadAllMessages(chatId);
  for (final m in messages) {
    if (m.senderId == myId) continue; // my own messages never mention "me"
    if (m.readAt[myId] != null) continue; // already read by me
    if (mentionTargetsMe(
      m.decryptedContent ?? '',
      myUsername,
      isAdmin: isAdmin,
    )) {
      return true;
    }
  }
  return false;
});
