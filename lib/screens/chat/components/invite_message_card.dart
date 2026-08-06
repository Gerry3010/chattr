// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../core/navigation/navigation_provider.dart';
import '../../../features/chats/chats_controller.dart';
import '../../../features/invites/invite_envelope.dart';
import '../../../features/invites/invites_controller.dart';

/// The invitation card rendered for a `_chattr_invite` message: group name +
/// a join button. Tapping joins WITHOUT admin approval (`redeem_chat_invite`)
/// — the server enforces that this only works for members of the chat the
/// invitation was sent to, and that the invite wasn't revoked.
///
/// States: join → joining → open (already a member). Revoked/invalid shows
/// up as an error snackbar on tap — a non-member can't query invite state
/// (RLS), so the tap is the probe.
class InviteMessageCard extends HookConsumerWidget {
  final InviteEnvelope invite;
  final bool isOwn;

  const InviteMessageCard({
    super.key,
    required this.invite,
    required this.isOwn,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final joining = useState(false);
    final scheme = Theme.of(context).colorScheme;

    // Membership is derived live from the chat list: right after a
    // successful join the chat appears there and the card flips to "open".
    final chat = ref
        .watch(chatsControllerProvider)
        .where((c) => c.id == invite.chatId)
        .firstOrNull;
    final isMember = chat != null;

    Future<void> join() async {
      joining.value = true;
      try {
        await ref.read(invitesControllerProvider).redeemInvite(
              token: invite.token,
              chatId: invite.chatId,
            );
      } catch (e) {
        if (context.mounted) {
          final message = e.toString().contains('revoked')
              ? 'invite.revoked'.tr()
              : 'invite.join_failed'.tr();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), backgroundColor: Colors.red),
          );
        }
      } finally {
        joining.value = false;
      }
    }

    void open() {
      if (chat != null) {
        ref.read(navigationServiceProvider).navigateToChat(chat);
      }
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isOwn ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                child: const Icon(Icons.group),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      invite.chatName,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'invite.card_subtitle'.tr(),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: isMember
                ? OutlinedButton(
                    onPressed: open,
                    child: Text('invite.open_chat'.tr()),
                  )
                : FilledButton(
                    onPressed: joining.value ? null : join,
                    child: joining.value
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text('invite.join'.tr()),
                  ),
          ),
        ],
      ),
    );
  }
}
