// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/utils/app_time.dart';
import '../../../features/auth/auth_controller.dart';
import '../../../features/chats/chats_controller.dart';
import '../../../features/invites/invites_controller.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../components/forward_chat_sheet.dart';

/// This group's active invitation messages (admins only — to everyone else row-
/// level security returns an empty list anyway).
///
/// Revoking kills the key server-side: whoever has already joined stays in, the
/// card in the target chat merely stops working.
///
/// Before, this was a permanently expanded card in the info view — even when
/// exactly one invitation was open. Now a row with a number stands there, and
/// the list opens when one wants to see it.
Future<void> showChatInvitesSheet({
  required BuildContext context,
  required String chatId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _InvitesSheet(chatId: chatId),
  );
}

class _InvitesSheet extends ConsumerWidget {
  final String chatId;

  const _InvitesSheet({required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invitesAsync = ref.watch(chatInvitesProvider(chatId));
    final chats = ref.watch(chatsControllerProvider);
    final currentUserId = ref.watch(authControllerProvider);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'invite.active_title'.tr(),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Flexible(
              child: invitesAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('common.error'.tr(args: ['$e'])),
                ),
                data: (invites) {
                  final active = invites.where((i) => !i.isRevoked).toList();
                  if (active.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text('invite.active_empty'.tr()),
                    );
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: active.length,
                    itemBuilder: (context, i) {
                      final invite = active[i];
                      final target = chats
                          .where((c) => c.id == invite.targetChatId)
                          .firstOrNull;
                      // A fellow admin can invite into a chat we are not in —
                      // then there is no name to resolve. Printing the raw id
                      // prefix read like a username; better to say clearly that
                      // the chat is not ours.
                      final targetName = target == null
                          ? 'invite.target_not_visible'.tr()
                          : (currentUserId == null
                              ? (target.name ??
                                  'invite.target_not_visible'.tr())
                              : forwardChatDisplayName(
                                  ref, target, currentUserId));
                      // Who created it. A group can have several admins, and
                      // here one of them decides about another's invitation —
                      // so whose it is has to be stated.
                      final creatorId = invite.createdBy;
                      final creator = creatorId == null
                          ? null
                          : (creatorId == currentUserId
                              ? 'chat_detail.you'.tr()
                              : ref.watch(optionalUsernameProvider(creatorId)));
                      final when = AppTime.ymdHm(
                        invite.createdAt,
                        context.locale.toString(),
                      );
                      return ListTile(
                        leading: const Icon(Icons.forward_to_inbox),
                        title: Text(targetName),
                        subtitle: Text(
                          creator == null
                              ? when
                              : 'invite.created_by'.tr(
                                  namedArgs: {'name': creator, 'when': when},
                                ),
                        ),
                        trailing: TextButton(
                          onPressed: () => _revoke(context, ref, invite.token),
                          child: Text('invite.revoke'.tr()),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    String token,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(invitesControllerProvider).revokeInvite(token);
      ref.invalidate(chatInvitesProvider(chatId));
      messenger.showSnackBar(
        SnackBar(content: Text('invite.revoked_done'.tr())),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('invite.revoke_failed'.tr(args: ['$e'])),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
