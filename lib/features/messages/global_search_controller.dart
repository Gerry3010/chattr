// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../chats/chat_members_controller.dart';
import '../chats/chats_controller.dart';
import '../profiles/profile_helpers.dart';
import 'message_model.dart';
import 'messages_local_provider.dart';

/// One global-search hit: the matching message plus the id of the chat it
/// lives in (the message already carries [Message.chatId], but the display
/// name is resolved separately via [chatDisplayNameProvider]).
class GlobalSearchHit {
  final Message message;
  const GlobalSearchHit(this.message);

  String get chatId => message.chatId;
}

/// Cross-chat message search. Content is encrypted at rest, so this decrypts
/// and substring-filters the whole local store (see
/// [MessagesLocalRepository.searchAllMessages]) — debounce at the UI layer.
final globalMessageSearchProvider = FutureProvider.autoDispose
    .family<List<GlobalSearchHit>, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const [];
  final repo = ref.read(messagesLocalRepositoryProvider);
  final messages = await repo.searchAllMessages(trimmed);
  return messages.map(GlobalSearchHit.new).toList();
});

/// Contact/chat suggestions for global search: chat ids whose resolved display
/// name matches [query] (1:1 partner username or group name). Synchronous — no
/// decrypt needed — so it can surface instantly above the (async) message hits.
/// Returns [] for an empty query or when nothing matches (section then hidden).
final contactSearchProvider =
    Provider.autoDispose.family<List<String>, String>((ref, query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final parts = q.split(RegExp(r'\s+'));
  final chats = ref.watch(chatsControllerProvider).toList()
    ..sort((a, b) => b.sortDate.compareTo(a.sortDate));
  final matches = <String>[];
  for (final chat in chats) {
    final name = ref.watch(chatDisplayNameProvider(chat.id)).toLowerCase();
    if (parts.every(name.contains)) matches.add(chat.id);
  }
  return matches;
});

/// Display name for a chat, matching the chat-list logic: a group uses its
/// name, a 1:1 uses the other participant's username. Reusable anywhere a
/// chat needs a human label (global search, notifications, …).
final chatDisplayNameProvider =
    Provider.autoDispose.family<String, String>((ref, chatId) {
  final currentUserId = ref.watch(authControllerProvider);
  final chat = ref.watch(chatsControllerProvider).where((c) => c.id == chatId);
  final chatModel = chat.isEmpty ? null : chat.first;

  if (chatModel != null && chatModel.isGroup && chatModel.name != null) {
    return chatModel.name!;
  }

  // 1:1 (or unnamed): the other member's username.
  final members =
      ref.watch(chatMembersProvider(chatId)).whenOrNull(data: (m) => m) ?? [];
  final otherId = members.firstWhere(
    (id) => id != currentUserId,
    orElse: () => '',
  );
  if (otherId.isNotEmpty) {
    final name = ref.watch(optionalUsernameProvider(otherId));
    if (name != null) return name;
  }
  return chatModel?.name ??
      'chat_list.chat_title'.tr(
        args: [chatId.length >= 8 ? chatId.substring(0, 8) : chatId],
      );
});
