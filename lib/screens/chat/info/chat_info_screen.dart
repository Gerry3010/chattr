// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../../features/auth/auth_controller.dart';
import '../../../features/chats/chat_members_controller.dart';
import '../../../features/chats/chat_model.dart';
import '../../../features/chats/chats_controller.dart';
import '../../../features/chats/mute_controller.dart';
import '../../../features/identity/identity_verification_controller.dart';
import '../../../features/identity/identity_verification_repository.dart';
import '../../../features/identity/widgets/trust_shield.dart';
import '../../../features/invites/invites_controller.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../../identity/safety_number_screen.dart';
import '../chat_members_screen.dart';
import '../components/mute_sheet.dart';
import '../favorites_screen.dart';
import '../pending_requests_screen.dart';
import 'chat_info_actions.dart';
import 'chat_notifications_screen.dart';
import 'chat_media_screen.dart';
import 'chat_info_header.dart';
import 'chat_info_members_section.dart';
import 'chat_invites_sheet.dart';
import 'group_edit_screen.dart';
import 'widgets/info_section.dart';

/// The chat info: header, then ordered sections.
///
/// Replaces `ChatDetailScreen`, which had grown to 1566 lines over more than a
/// year and stacked nine equally weighted cards — picture, name, QR code, self-
/// destruct, requests, invitations, members, blocking. When everything is a
/// card, nothing is more important than the rest.
///
/// What is NOT here any more: the QR code as a permanent card (it lives behind
/// "invite"), the inline editing for admins (its own screen) and the complete
/// member list (five rows and a way to the full list — before, all thirty stood
/// there AND below them "show all 30").
class ChatInfoScreen extends ConsumerWidget {
  final Chat chat;

  const ChatInfoScreen({super.key, required this.chat});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the living chat, not the snapshot from the route: name,
    // description, picture and self-destruct duration change while the view is
    // open.
    final live = ref.watch(chatProvider(chat.id)) ?? chat;
    final me = ref.watch(authControllerProvider);
    final isAdmin = me != null && live.isAdmin(me);
    final members =
        ref.watch(chatMembersProvider(chat.id)).asData?.value ?? const [];
    final peerId = live.isGroup
        ? null
        : members.where((id) => id != me).firstOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          (live.isGroup ? 'chat_detail.title_group' : 'chat_detail.title_direct')
              .tr(),
        ),
        actions: [
          if (live.isGroup && isAdmin)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'group_edit.title'.tr(),
              onPressed: () => Navigator.push(
                context,
                appPageRoute<void>(
                  builder: (_) => GroupEditScreen(chat: live),
                ),
              ),
            ),
          PopupMenuButton<String>(
            onSelected: (value) => switch (value) {
              'report' => reportChat(context, ref, live, me),
              'rotate' => rotateChatKey(context, ref, live),
              _ => null,
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'report',
                child: ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: Text('chat_detail.report_user'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'rotate',
                child: ListTile(
                  leading: const Icon(Icons.key),
                  title: Text('chat_detail.rotate_key'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        children: [
          ChatInfoHeader(
            chat: live,
            peerId: peerId,
            memberCount: members.length,
            isAdmin: isAdmin,
          ),
          const Divider(),
          _InChatSection(chat: live),
          _SettingsSection(chat: live, isAdmin: isAdmin, peerId: peerId),
          if (live.isGroup && isAdmin) _AdminSection(chat: live, me: me),
          // The members stand FAR DOWN, although they are the most important
          // thing about the group (Gerry, 2026-08-25). The reason is their
          // length: five people are capped, the agents below them are NOT — in
          // a project chat the section pushes everything else off the bottom of
          // the screen. Whoever wants to check who is in scrolls once; whoever
          // wants to change a setting finds it at once. The other way round one
          // had to pass the whole list to mute.
          //
          // Not quite last: leaving and deleting stay the end. What cannot be
          // undone belongs below everything else, not in the middle of it.
          if (live.isGroup)
            ChatInfoMembersSection(
              chat: live,
              currentUserId: me,
              isAdmin: isAdmin,
            ),
          _DangerSection(
            chat: live,
            me: me,
            isAdmin: isAdmin,
            peerId: peerId,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Result the info view is closed with when the user wants to search in the
/// chat. The search itself belongs in the chat: its selection dialog hangs on
/// the `chatViewControllerProvider`, which is `autoDispose.family` — opened
/// from here it would rebuild the controller for the search alone and start
/// with empty names. So back into the chat and trigger the search there;
/// whoever did not open the info from a chat simply ignores the result.
const String chatInfoSearchResult = 'suchen';

/// "In this chat" — what lies in this one history.
class _InChatSection extends ConsumerWidget {
  final Chat chat;

  const _InChatSection({required this.chat});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favCount = ref.watch(chatFavoriteCountProvider(chat.id)).asData?.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('chat_detail.section_in_chat'.tr()),
        InfoActionRow(
          icon: Icons.star_outline,
          title: 'chat_detail.favorites_in_chat'.tr(),
          trailingText: favCount == null ? null : '$favCount',
          onTap: () => Navigator.push(
            context,
            appPageRoute<void>(
              builder: (_) => FavoritesScreen(chatId: chat.id),
            ),
          ),
        ),
        InfoActionRow(
          icon: Icons.perm_media_outlined,
          title: 'chat_detail.media_and_files'.tr(),
          onTap: () => Navigator.push(
            context,
            appPageRoute<void>(
              builder: (_) => ChatMediaScreen(chatId: chat.id),
            ),
          ),
        ),
        InfoActionRow(
          icon: Icons.search,
          title: 'messages_search.title'.tr(),
          onTap: () => Navigator.pop(context, chatInfoSearchResult),
        ),
        const Divider(),
      ],
    );
  }
}

class _SettingsSection extends ConsumerWidget {
  final Chat chat;
  final bool isAdmin;
  final String? peerId;

  const _SettingsSection({
    required this.chat,
    required this.isAdmin,
    required this.peerId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = ref.watch(chatIsMutedProvider(chat.id));
    final until = ref.read(mutedChatsProvider.notifier).mutedUntil(chat.id);
    final verification = ref.watch(chatVerificationProvider(chat.id)).asData?.value;

    // The state belongs ON the row, not inside the menu one sets it from.
    // Before, one had to open the menu to see whether a chat is muted — a
    // setting that hides itself while it is in effect.
    final muteState = !muted
        ? 'chat_detail.notifications_on'.tr()
        : (until == null
            ? 'chat_detail.muted_forever'.tr()
            : 'chat_detail.muted_until'
                .tr(args: [formatMuteUntil(context, until)]));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('chat_detail.section_settings'.tr()),
        InfoActionRow(
          icon: muted ? Icons.notifications_off : Icons.notifications_active,
          title: 'chat_detail.notifications'.tr(),
          subtitle: muteState,
          // Now leads to its own screen rather than straight into the sheet:
          // besides muting, that is where this chat's sound lives, and the row
          // was already called "notifications" and not "mute".
          onTap: () => Navigator.push(
            context,
            appPageRoute<void>(
              builder: (_) => ChatNotificationsScreen(chat: chat),
            ),
          ),
        ),
        InfoActionRow(
          icon: Icons.timer_outlined,
          title: 'chat_detail.disappearing_messages'.tr(),
          // Non-admins may not set the duration (`chats` UPDATE is admin-only,
          // 00005). In a stack of cards a dead row hardly stood out, in a flat
          // list very much so — so it says why it does not react instead of
          // staying silent.
          subtitle: isAdmin ? null : 'chat_detail.ttl_admin_only'.tr(),
          trailingText: ttlLabel(chat.messageTtlSeconds),
          onTap: isAdmin ? () => showTtlPicker(context, ref, chat) : null,
        ),
        if (verification != null && verification.peers.isNotEmpty)
          _VerificationRow(
            chat: chat,
            peerId: peerId,
            verification: verification,
          ),
        const Divider(),
      ],
    );
  }
}

class _VerificationRow extends ConsumerWidget {
  final Chat chat;
  final String? peerId;
  final ChatVerificationSummary verification;

  const _VerificationRow({
    required this.chat,
    required this.peerId,
    required this.verification,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = trustAppearanceForSummary(verification);
    final verifiziert = verification.peers.values
        .where((s) => s == IdentityVerificationState.verified)
        .length;

    return ListTile(
      leading: Icon(look.icon, color: look.color),
      title: Text('identity.title'.tr()),
      subtitle: Text(
        chat.isGroup
            ? 'chat_detail.verification_summary'
                .tr(args: ['$verifiziert', '${verification.peers.length}'])
            : look.label,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        if (chat.isGroup) {
          // In a group verification happens per member — the list is the place
          // for it.
          Navigator.push(
            context,
            appPageRoute<void>(builder: (_) => ChatMembersScreen(chat: chat)),
          );
        } else if (peerId != null) {
          Navigator.push(
            context,
            appPageRoute<void>(
              builder: (_) => SafetyNumberScreen(
                userId: peerId!,
                username:
                    ref.read(profileProvider(peerId!))?.username ?? peerId!,
              ),
            ),
          );
        }
      },
    );
  }
}

class _AdminSection extends ConsumerWidget {
  final Chat chat;
  final String? me;

  const _AdminSection({required this.chat, required this.me});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending =
        ref.watch(pendingMembersProvider(chat.id)).asData?.value ?? const [];
    final invites = ref.watch(chatInvitesProvider(chat.id)).asData?.value;
    final activeInvites =
        invites?.where((i) => !i.isRevoked).length ?? 0;

    // A section that shows only zeros is not administration but trimming — it
    // appears once there is something to administer.
    if (pending.isEmpty && activeInvites == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('chat_detail.section_admin'.tr()),
        if (pending.isNotEmpty)
          InfoActionRow(
            icon: Icons.hourglass_empty,
            title: 'chat_detail.pending_requests'.tr(),
            trailingText: '${pending.length}',
            onTap: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => PendingRequestsScreen(chatId: chat.id),
              ),
            ),
          ),
        if (activeInvites > 0)
          InfoActionRow(
            icon: Icons.forward_to_inbox,
            title: 'invite.active_title'.tr(),
            trailingText: '$activeInvites',
            onTap: () =>
                showChatInvitesSheet(context: context, chatId: chat.id),
          ),
        const Divider(),
      ],
    );
  }
}

class _DangerSection extends ConsumerWidget {
  final Chat chat;
  final String? me;
  final bool isAdmin;
  final String? peerId;

  const _DangerSection({
    required this.chat,
    required this.me,
    required this.isAdmin,
    required this.peerId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!chat.isGroup && peerId != null && me != null)
          InfoActionRow(
            icon: Icons.block,
            title: 'chat_detail.block_user'.tr(),
            color: Colors.red,
            chevron: false,
            onTap: () => blockPeer(context, ref, chat, peerId!, me!),
          ),
        InfoActionRow(
          icon: Icons.logout,
          title: 'chat_detail.leave_chat'.tr(),
          color: Colors.red,
          chevron: false,
          onTap: () => leaveChat(context, ref, chat, me),
        ),
        if (isAdmin)
          InfoActionRow(
            icon: Icons.delete_forever,
            title: 'chat_detail.delete_chat'.tr(),
            color: Colors.red,
            chevron: false,
            onTap: () => deleteChat(context, ref, chat),
          ),
      ],
    );
  }
}
