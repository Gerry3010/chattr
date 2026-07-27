// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/auth/auth_controller.dart';
import '../../../features/chats/chat_members_controller.dart';
import '../../../features/chats/chat_model.dart';
import '../../../features/chats/chats_controller.dart';
import '../../../features/chats/widgets/chat_avatar.dart';
import '../../../features/profiles/profiles.dart';

/// Chat picker for forwarding a message or an incoming share. Returns the
/// chosen target chat id, or null if dismissed.
///
/// [excludeChatId] hides the source chat when forwarding; pass null (share
/// target) to offer every chat. [titleKey] lets the share flow use its own
/// heading.
Future<String?> showForwardChatSheet({
  required BuildContext context,
  String? excludeChatId,
  String titleKey = 'chat_view.forward_to',
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: _ForwardChatPicker(
        excludeChatId: excludeChatId,
        titleKey: titleKey,
      ),
    ),
  );
}

/// Resolves the display name a chat is shown (and searched) by: the group name,
/// or — for a 1:1 — the other member's username. Falls back to the short id.
String forwardChatDisplayName(
  WidgetRef ref,
  Chat chat,
  String? currentUserId,
) {
  String? displayName = chat.isGroup ? chat.name : null;
  if (displayName == null) {
    final members = ref
            .watch(chatMembersProvider(chat.id))
            .whenOrNull(data: (members) => members) ??
        const <String>[];
    final profiles = ref.watch(profilesListProvider(members));
    displayName = profiles
        .where((profile) => profile.id != currentUserId)
        .map((profile) => profile.username)
        .firstOrNull;
  }
  return displayName ??
      'chat_list.chat_title'.tr(args: [chat.id.substring(0, 8)]);
}

class _ForwardChatPicker extends ConsumerStatefulWidget {
  final String? excludeChatId;
  final String titleKey;

  const _ForwardChatPicker({
    required this.excludeChatId,
    required this.titleKey,
  });

  @override
  ConsumerState<_ForwardChatPicker> createState() =>
      _ForwardChatPickerState();
}

class _ForwardChatPickerState extends ConsumerState<_ForwardChatPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = ref.watch(authControllerProvider);
    final allChats = ref
        .watch(chatsControllerProvider)
        .where((chat) => chat.id != widget.excludeChatId)
        .toList()
      // Same ordering as the main chat list: pinned chats first, then most
      // recent — so a pinned target is right where the user expects it.
      ..sort(compareChatsForList);

    if (allChats.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Text('chat_view.forward_no_chats'.tr()),
      );
    }

    // Resolve names once so the search filter sees the same string the row
    // renders (group name / 1:1 partner username).
    final named = [
      for (final chat in allChats)
        (chat: chat, name: forwardChatDisplayName(ref, chat, currentUserId)),
    ];
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? named
        : named
            .where((e) =>
                q.split(RegExp(r'\s+')).every((p) => e.name.toLowerCase().contains(p)))
            .toList();

    // Lift the sheet above the keyboard and cap its height against the space
    // that is actually left, so the list never hides behind the keyboard.
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final maxSheetHeight =
        (MediaQuery.of(context).size.height - viewInsets) * 0.7;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              widget.titleKey.tr(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'chat_view.forward_search'.tr(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                isDense: true,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surface,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Flexible(
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('chat_view.forward_no_chats'.tr()),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (context, index) => _ForwardChatTile(
                      chat: filtered[index].chat,
                      displayName: filtered[index].name,
                      onTap: () =>
                          Navigator.pop(context, filtered[index].chat.id),
                    ),
                  ),
          ),
          ],
        ),
      ),
    );
  }
}

class _ForwardChatTile extends StatelessWidget {
  final Chat chat;
  final String displayName;
  final VoidCallback onTap;

  const _ForwardChatTile({
    required this.chat,
    required this.displayName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      // Shared reactive chat avatar: group picture (00055) or the 1:1 partner's
      // profile photo, coloured initials only as a fallback.
      leading: ChatAvatar(
        chatId: chat.id,
        fallbackColor: chat.color,
        fallbackInitial: displayName,
      ),
      title: Text(displayName),
      trailing: chat.isPinned
          ? Icon(
              Icons.push_pin,
              size: 16,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : null,
      onTap: onTap,
    );
  }
}
