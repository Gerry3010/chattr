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
}) async {
  final ids = await showModalBottomSheet<List<String>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ForwardChatPicker(
        excludeChatId: excludeChatId,
        titleKey: titleKey,
        multiSelect: false,
      ),
    ),
  );
  return (ids == null || ids.isEmpty) ? null : ids.first;
}

/// Multi-select variant (share target / forward to several chats): checkbox
/// rows + a "send (n)" button. Returns the chosen chat ids in selection order,
/// or null if dismissed.
Future<List<String>?> showForwardChatSheetMulti({
  required BuildContext context,
  String? excludeChatId,
  String titleKey = 'chat_view.forward_to',
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ForwardChatPicker(
        excludeChatId: excludeChatId,
        titleKey: titleKey,
        multiSelect: true,
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

@visibleForTesting
class ForwardChatPicker extends ConsumerStatefulWidget {
  final String? excludeChatId;
  final String titleKey;

  /// Single tap-to-pick (false) or checkbox rows + send button (true). Both
  /// pop with a `List<String>` of chat ids.
  final bool multiSelect;

  const ForwardChatPicker({
    super.key,
    required this.excludeChatId,
    required this.titleKey,
    required this.multiSelect,
  });

  @override
  ConsumerState<ForwardChatPicker> createState() => _ForwardChatPickerState();
}

class _ForwardChatPickerState extends ConsumerState<ForwardChatPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  /// Selection order is preserved — sends loop in the order the user picked.
  final List<String> _selected = [];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggle(String chatId) {
    setState(() {
      if (!_selected.remove(chatId)) _selected.add(chatId);
    });
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
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      final selected = _selected.contains(entry.chat.id);
                      return _ForwardChatTile(
                        chat: entry.chat,
                        displayName: entry.name,
                        selected: widget.multiSelect ? selected : null,
                        onTap: widget.multiSelect
                            ? () => _toggle(entry.chat.id)
                            : () =>
                                Navigator.pop(context, [entry.chat.id]),
                      );
                    },
                  ),
          ),
          if (widget.multiSelect)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('forward_multi_send_button'),
                  icon: const Icon(Icons.send),
                  label: Text(
                    'chat_view.forward_send_count'
                        .tr(args: ['${_selected.length}']),
                  ),
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context, List<String>.from(_selected)),
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

  /// null → single-select row (chevron-less plain tile); true/false → a
  /// checkbox row in multi-select mode.
  final bool? selected;

  const _ForwardChatTile({
    required this.chat,
    required this.displayName,
    required this.onTap,
    this.selected,
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
      selected: selected ?? false,
      trailing: selected != null
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : chat.isPinned
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
