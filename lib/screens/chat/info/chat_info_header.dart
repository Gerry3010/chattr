// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/utils/app_time.dart';
import '../../../features/chats/chat_model.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../../features/chats/mute_controller.dart';
import '../../../features/chats/widgets/group_avatar.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../../../features/profiles/widgets/user_avatar.dart';
import 'chat_notifications_screen.dart';
import 'widgets/add_member_sheet.dart';
import 'widgets/trimmed_description.dart';

/// The head of the chat info: picture, name, one line of numbers, the
/// description — and two quick buttons.
///
/// It is deliberately the only part with visual weight. Before, picture, name
/// and description were spread over three identical-looking cards; what the
/// group is about thereby stood optically level with the QR code.
class ChatInfoHeader extends ConsumerWidget {
  final Chat chat;
  final String? peerId;
  final int memberCount;
  final bool isAdmin;

  const ChatInfoHeader({
    super.key,
    required this.chat,
    required this.peerId,
    required this.memberCount,
    required this.isAdmin,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final title = chat.isGroup
        ? (chat.name ?? 'chat_list.chat_title'.tr(args: [chat.id.substring(0, 8)]))
        : (peerId == null
            ? 'chat_detail.unknown_user'.tr()
            : ref.watch(profileProvider(peerId!))?.username ??
                'chat_detail.unknown_user'.tr());

    // `Localizations.localeOf` instead of `context.locale`: both yield the same
    // language in the app (EasyLocalization sets exactly this one on the
    // MaterialApp), but `context.locale` throws without an initialised
    // EasyLocalization — and with that the header would be testable in no
    // widget test.
    final locale = Localizations.localeOf(context).toString();

    final meta = chat.isGroup
        ? '${'chat_detail.member_count'.tr(args: ['$memberCount'])} · '
            '${'chat_detail.created_on'.tr(args: [AppTime.ymd(chat.createdAt, locale)])}'
        : 'chat_detail.chat_since'.tr(
            args: [AppTime.ymd(chat.createdAt, locale)],
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          if (chat.isGroup)
            GroupAvatar(
              chatId: chat.id,
              radius: 56,
              onTap: () => showGroupAvatarViewer(context, chat.id),
            )
          else if (peerId != null)
            UserAvatar(
              userId: peerId!,
              radius: 56,
              onTap: () => showAvatarViewer(context, peerId!),
            ),
          const SizedBox(height: 12),
          Text(
            title,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            meta,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          if (chat.isGroup && (chat.description?.isNotEmpty ?? false)) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: TrimmedDescription(chat.description!),
            ),
          ],
          const SizedBox(height: 16),
          _QuickActions(chat: chat, isAdmin: isAdmin),
        ],
      ),
    );
  }
}

class _QuickActions extends ConsumerWidget {
  final Chat chat;
  final bool isAdmin;

  const _QuickActions({required this.chat, required this.isAdmin});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = ref.watch(chatIsMutedProvider(chat.id));

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          icon: Icon(muted ? Icons.notifications_off : Icons.notifications),
          label: Text(
            (muted ? 'chat_detail.unmute' : 'chat_detail.mute').tr(),
          ),
          // A shortcut, not a second route (Gerry, 2026-08-25): the button
          // leads into the notifications screen and opens the duration picker
          // there straight away. Before, it called the same code as the row
          // below it — two entry points for exactly one action, and neither of
          // them showed that there is more to set.
          //
          // Un-muting stays handled here at once: there is nothing to choose
          // for that, and a screen change would only be in the way.
          onPressed: () {
            final controller = ref.read(mutedChatsProvider.notifier);
            if (controller.isMuted(chat.id)) {
              controller.unmute(chat.id);
              return;
            }
            Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => ChatNotificationsScreen(
                  chat: chat,
                  openMuteSheet: true,
                ),
              ),
            );
          },
        ),
        // Inviting stays an admin matter: joining needs an admin's approval
        // anyway, and a button promising an invitation that then silts up in a
        // queue would be no service.
        if (chat.isGroup && isAdmin)
          OutlinedButton.icon(
            icon: const Icon(Icons.person_add_alt),
            label: Text('chat_detail.invite_short'.tr()),
            onPressed: () => showAddMemberSheet(context: context, chat: chat),
          ),
      ],
    );
  }
}
