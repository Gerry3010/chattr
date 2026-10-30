// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../../features/chats/chat_members_controller.dart';
import '../../../features/chats/chat_model.dart';
import '../../../features/identity/identity_verification_controller.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../chat_members_screen.dart';
import 'widgets/info_section.dart';
import 'widgets/member_tile.dart';
import '../../../core/network/load_error_view.dart';

/// The chat info's short member list.
///
/// Deliberately TRUNCATED: before, the info view rendered every member and
/// still put "show all N" below it — in a group of thirty people, thirty rows
/// and a button showing the same thirty again. Five rows say who is here;
/// whoever wants to search goes to the full list.
class ChatInfoMembersSection extends ConsumerWidget {
  static const int _maxLines = 5;

  final Chat chat;
  final String? currentUserId;
  final bool isAdmin;

  const ChatInfoMembersSection({
    super.key,
    required this.chat,
    required this.currentUserId,
    required this.isAdmin,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membersAsync = ref.watch(chatMembersProvider(chat.id));
    // Read without a loading indicator: the trust provider queries profile and
    // keys per member — a slow connection must not hold up the list, the
    // shields simply arrive a little later.
    final verification =
        ref.watch(chatVerificationProvider(chat.id)).asData?.value;

    return membersAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, _) => LoadErrorView(
        error: err,
        compact: true,
        onRetry: () => ref.invalidate(chatMembersProvider(chat.id)),
      ),
      data: (memberIds) {
        // Agents stand separately (1.13): the separation is pure display
        // (`profiles.is_agent`), but a model in the member list is something
        // one wants to SEE, not to discover.
        final agentIds = memberIds
            .where((id) => ref.watch(profileProvider(id))?.isAgent ?? false)
            .toList();
        final humanIds =
            memberIds.where((id) => !agentIds.contains(id)).toList();
        final gezeigt = humanIds.take(_maxLines).toList();
        final verborgen = humanIds.length - gezeigt.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader('chat_detail.members'.tr()),
            for (final memberId in gezeigt)
              MemberTile(
                chat: chat,
                memberId: memberId,
                currentUserId: currentUserId,
                isCurrentUserAdmin: isAdmin,
                trust: verification?.peers[memberId],
              ),
            if (agentIds.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  'chat_detail.agents'.tr(),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final agentId in agentIds)
                MemberTile(
                  chat: chat,
                  memberId: agentId,
                  currentUserId: currentUserId,
                  isCurrentUserAdmin: isAdmin,
                  trust: verification?.peers[agentId],
                  isAgentSection: true,
                ),
            ],
            // The row says what it DOES — and that depends on whether anybody
            // is missing at all. "Show all 6" under a list in which all 6
            // already stand would be exactly the redundancy this view was
            // rebuilt over. If everybody is there, the row still leads on — to
            // the search, which exists only there.
            InfoActionRow(
              icon: verborgen > 0 ? Icons.groups_outlined : Icons.search,
              title: verborgen > 0
                  ? 'chat_detail.view_all_members'
                      .tr(args: ['${memberIds.length}'])
                  : 'chat_detail.search_members'.tr(),
              onTap: () => Navigator.push(
                context,
                appPageRoute<void>(
                  builder: (_) => ChatMembersScreen(chat: chat),
                ),
              ),
            ),
            const Divider(),
          ],
        );
      },
    );
  }
}
