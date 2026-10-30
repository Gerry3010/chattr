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

    // Every colour on this card is derived from the card's OWN background, not
    // from the surrounding surface. The card paints itself `primaryContainer`
    // (own) or `surfaceContainerHighest` (other) — so title, subtitle and the
    // button have to use the matching `on…` role. They used to inherit the
    // bubble's text colour and the M3 default button foreground (`primary`),
    // which in the forest theme is a gold accent sitting on beige: the title
    // was white-on-beige and "open" nearly invisible. Deriving it here fixes it
    // for every theme at once instead of tuning one palette.
    final onCard = isOwn ? scheme.onPrimaryContainer : scheme.onSurface;
    // 0.85, not the usual 0.7: at 0.72 the subtitle drops to 3.7:1 on the
    // lighter palettes (meadow, system/light), i.e. below WCAG AA for text this
    // size. See test/invite_card_contrast_test.dart, which holds the line.
    final onCardMuted = onCard.withValues(alpha: 0.85);

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
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: onCard,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'invite.card_subtitle'.tr(),
                      style: TextStyle(fontSize: 12, color: onCardMuted),
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
                    style: OutlinedButton.styleFrom(
                      foregroundColor: onCard,
                      side: BorderSide(color: onCard.withValues(alpha: 0.45)),
                    ),
                    child: Text('invite.open_chat'.tr()),
                  )
                : FilledButton(
                    onPressed: joining.value ? null : join,
                    // primary/onPrimary is a contrast pair by construction, so
                    // the label stays legible whatever the card underneath is.
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                    ),
                    child: joining.value
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              // Default is `primary` — gold on a gold button.
                              color: scheme.onPrimary,
                            ),
                          )
                        : Text('invite.join'.tr()),
                  ),
          ),
        ],
      ),
    );
  }
}
