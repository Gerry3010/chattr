// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/utils/ttl_format.dart';
import '../../../features/blocks/blocked_users_repository.dart';
import '../../../features/chats/chat_members_controller.dart';
import '../../../features/chats/chat_model.dart';
import '../../../features/chats/chats_controller.dart';
import '../../../features/chats/report_controller.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../../../features/reports/reports_repository.dart';
import '../../../features/share_suggestions/share_suggestions_channel.dart';

/// The chat info's actions as free functions — so the section widgets stay thin
/// and only describe what they show.

Future<bool?> confirmDialog(
  BuildContext context,
  String title,
  String message, {
  bool destructive = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('common.cancel'.tr()),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? TextButton.styleFrom(foregroundColor: Colors.red)
              : null,
          child: Text('common.confirm'.tr()),
        ),
      ],
    ),
  );
}

/// Waehlbare Dauern der Selbstzerstoerung. null = aus.
const List<int?> kTtlOptions = [null, 30, 300, 3600, 86400, 604800];

/// Shares [formatMessageTtl] with the system message that announces a changed
/// duration — otherwise the picker and the announcement could name the same
/// duration differently.
String ttlLabel(int? seconds) =>
    seconds == null ? 'chat_detail.ttl_off'.tr() : formatMessageTtl(seconds);

void showTtlPicker(BuildContext context, WidgetRef ref, Chat chat) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'chat_detail.disappearing_messages'.tr(),
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
          ),
          for (final option in kTtlOptions)
            ListTile(
              title: Text(ttlLabel(option)),
              trailing: option == chat.messageTtlSeconds
                  ? Icon(
                      Icons.check,
                      color: Theme.of(sheetContext).colorScheme.primary,
                    )
                  : null,
              onTap: () async {
                Navigator.pop(sheetContext);
                await ref
                    .read(chatsControllerProvider.notifier)
                    .updateMessageTtl(chat: chat, ttlSeconds: option);
              },
            ),
        ],
      ),
    ),
  );
}

/// Report: mute and flag locally, plus a content-blind report to the server
/// (metadata only). The latter is deliberately "best effort" — the local report
/// already stands, a server error would be without consequence.
Future<void> reportChat(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  String? currentUserId,
) async {
  final confirmed = await confirmDialog(
    context,
    'chat_detail.confirm_report_title'.tr(),
    'chat_detail.confirm_report_message'.tr(),
  );
  if (confirmed != true) return;

  await ref.read(reportedChatsProvider.notifier).report(chat.id);
  try {
    final reports = ref.read(reportsRepositoryProvider);
    if (chat.isGroup) {
      await reports.reportGroup(chatId: chat.id, reason: 'reported_from_chat');
    } else {
      final members = await ref.read(chatMembersProvider(chat.id).future);
      final peerId =
          members.where((id) => id != currentUserId).firstOrNull;
      if (peerId != null) {
        await reports.reportUser(
          reportedUserId: peerId,
          chatId: chat.id,
          reason: 'reported_from_chat',
        );
      }
    }
  } catch (_) {
    /* Server-Meldung ist bestes Bemuehen */
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('chat_detail.reported'.tr())),
  );
}

Future<void> rotateChatKey(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final confirmed = await confirmDialog(
    context,
    'chat_detail.confirm_rotate_title'.tr(),
    'chat_detail.confirm_rotate_message'.tr(),
  );
  if (confirmed != true) return;
  await ref.read(chatsControllerProvider.notifier).rotateChatKey(chat.id);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('chat_detail.key_rotated'.tr()),
      backgroundColor: Colors.green,
    ),
  );
}

/// Leave the chat. The screen is only closed once the server has REALLY carried
/// the departure out: when the last admin leaves, the trigger may roll the
/// transaction back — before, the view closed anyway and the chat quietly
/// remained.
Future<void> leaveChat(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  String? currentUserId,
) async {
  final confirmed = await confirmDialog(
    context,
    'chat_detail.confirm_leave_title'.tr(),
    'chat_detail.confirm_leave_message'.tr(),
  );
  if (confirmed != true || currentUserId == null) return;

  try {
    await ref
        .read(chatMembersControllerProvider)
        .leaveChat(chatId: chat.id, currentUserId: currentUserId);
    if (context.mounted) Navigator.pop(context);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('common.error'.tr(args: [e.toString()]))),
    );
  }
}

Future<void> deleteChat(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
) async {
  final confirmed = await confirmDialog(
    context,
    'chat_detail.confirm_delete_title'.tr(),
    'chat_detail.confirm_delete_message'.tr(),
    destructive: true,
  );
  if (confirmed != true) return;

  final success =
      await ref.read(chatsControllerProvider.notifier).deleteChat(chat.id);
  if (!context.mounted) return;
  if (success) {
    Navigator.popUntil(context, (route) => route.isFirst);
  } else {
    // Row-level security refused (not an admin) or the request failed — the
    // chat still exists, so do not pretend it is gone.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('chat_detail.delete_failed'.tr())),
    );
  }
}

/// Block (1:1 only): block first, then leave. The order matters — otherwise the
/// leave trigger hands the chat to the other side or deletes it, and without a
/// block in place they could start a new one immediately.
Future<void> blockPeer(
  BuildContext context,
  WidgetRef ref,
  Chat chat,
  String otherUserId,
  String currentUserId,
) async {
  final otherName =
      ref.read(profileProvider(otherUserId))?.username ?? otherUserId;
  final confirmed = await confirmDialog(
    context,
    'chat_detail.block_confirm_title'.tr(args: [otherName]),
    'chat_detail.block_confirm_message'.tr(args: [otherName]),
  );
  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(blockedUsersRepositoryProvider).block(otherUserId);
    await ref
        .read(chatMembersControllerProvider)
        .leaveChat(chatId: chat.id, currentUserId: currentUserId);
    // Withdraw the iOS share suggestion for the blocked chat.
    await ShareSuggestionsChannel.deleteConversations([chat.id]);
    if (context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text('chat_detail.blocked_success'.tr(args: [otherName])),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('common.error'.tr(args: ['$e']))),
    );
  }
}
