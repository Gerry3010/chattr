// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../core/navigation/app_page_route.dart';
import '../../../../features/agents/main_agent_store.dart';
import '../../../../features/chats/chat_members_controller.dart';
import '../../../../features/chats/chat_model.dart';
import '../../../../features/identity/identity_verification_repository.dart';
import '../../../../features/identity/widgets/trust_shield.dart';
import '../../../../features/profiles/profile_helpers.dart';
import '../../../../features/profiles/widgets/profile_info_sheet.dart';
import '../../../../features/profiles/widgets/user_avatar.dart';
import '../../../identity/safety_number_screen.dart';

/// THE member tile — one for the compact list in the chat info and one for the
/// full, searchable members screen.
///
/// There used to be two: a plain one with a `Chip` in the info view and a
/// richer one with coloured pills and a trust shield in the members screen.
/// They not only looked different, they could do different things — in the info
/// view the shield was missing entirely. That of all things the trust indicator
/// depended on which of the four ways one had come in was the actual fault.
class MemberTile extends ConsumerWidget {
  final Chat chat;
  final String memberId;
  final String? currentUserId;
  final bool isCurrentUserAdmin;

  /// Trust state of this member (from `chatVerificationProvider`). `null` = not
  /// loaded yet → no shield rather than a wrong one.
  final IdentityVerificationState? trust;

  /// Shows the start of the id as a second line. Only in the full members
  /// screen, where one looks closely; in the short list of the chat info an id
  /// under every name would be mere noise.
  final bool showId;

  /// This row is in the agent section → star for the main agent.
  final bool isAgentSection;

  const MemberTile({
    super.key,
    required this.chat,
    required this.memberId,
    required this.currentUserId,
    required this.isCurrentUserAdmin,
    this.trust,
    this.showId = false,
    this.isAgentSection = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider(memberId));
    final username = profile?.username ?? 'chat_detail.unknown_user'.tr();
    final isMemberAdmin = chat.isAdmin(memberId);
    final isSelf = memberId == currentUserId;

    // Managing exists only in groups: in a 1:1 neither manages the other — the
    // database forbids it there anyway (00030).
    final canManage = chat.isGroup && isCurrentUserAdmin && !isSelf;

    // Main agent (1.13): exactly one per chat, addressee of the summary. A
    // LOCAL choice of this device, which is why anyone may make it, not just
    // admins. Tapping the filled star lifts the choice again.
    final isMainAgent =
        isAgentSection && ref.watch(mainAgentProvider(chat.id)) == memberId;

    return ListTile(
      leading: UserAvatar(
        userId: memberId,
        radius: 20,
        onTap: () => showProfileInfoSheet(
          context: context,
          chat: chat,
          displayName: username,
          otherUserId: memberId,
        ),
      ),
      // `Wrap` instead of `Row`: a long name plus "you" plus "admin" plus
      // shield does not necessarily fit in one line on a narrow device — and a
      // `Row` then visibly overflows instead of wrapping. The badges now simply
      // move a line down.
      title: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Text(username),
          if (isSelf)
            _Pill(
              label: 'chat_members.you_badge'.tr(),
              color: Colors.blue.shade700,
            ),
          if (isMemberAdmin)
            _Pill(
              label: 'chat_members.admin_badge'.tr(),
              // Deep orange, because the white label on light yellow was
              // illegible.
              color: Colors.orange.shade900,
              icon: Icons.admin_panel_settings,
            ),
          if (!isSelf && trust != null)
            TrustShieldIcon(
              appearance: trustAppearanceFor(trust!),
              onTap: () => Navigator.push(
                context,
                appPageRoute<void>(
                  builder: (_) => SafetyNumberScreen(
                    userId: memberId,
                    username: username,
                  ),
                ),
              ),
            ),
        ],
      ),
      subtitle: isMainAgent
          ? Text('chat_detail.main_agent'.tr())
          : (showId ? Text('ID: ${memberId.substring(0, 8)}...') : null),
      trailing: (!isAgentSection && !canManage)
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isAgentSection)
                  IconButton(
                    icon: Icon(
                      isMainAgent ? Icons.star : Icons.star_border,
                      color: isMainAgent
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    tooltip: 'chat_detail.main_agent'.tr(),
                    onPressed: () => ref
                        .read(mainAgentProvider(chat.id).notifier)
                        .set(isMainAgent ? null : memberId),
                  ),
                if (canManage)
                  PopupMenuButton<String>(
                    onSelected: (value) => _handleAction(
                      context,
                      ref,
                      value,
                      isMemberAdmin,
                      username,
                    ),
                    itemBuilder: (_) => _actions(isMemberAdmin),
                  ),
              ],
            ),
      // The whole row leads to the PERSON, the menu on the right to MANAGING
      // (Gerry, 2026-08-25). Before, a tap on the row opened the promote menu
      // for admins and nothing at all for everyone else, and the sheet hung on
      // the avatar alone — so a target one had to know about, and a different
      // outcome for admins than for the rest. The three-dot button and the star
      // catch their own taps; those never arrive here.
      onTap: () => showProfileInfoSheet(
        context: context,
        chat: chat,
        displayName: username,
        otherUserId: memberId,
      ),
    );
  }

  List<PopupMenuEntry<String>> _actions(bool isMemberAdmin) => [
        if (isMemberAdmin)
          _menuItem('demote', Icons.arrow_downward, 'chat_members.demote'.tr())
        else
          _menuItem('promote', Icons.arrow_upward, 'chat_members.promote'.tr()),
        _menuItem(
          'remove',
          Icons.person_remove,
          'chat_members.remove'.tr(),
          color: Colors.red,
        ),
      ];

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          // `Expanded`, because a bare `Text` in a `Row` does not give way:
          // with large text scaling or a longer translation the striped bar
          // would stand here instead of the label.
          Expanded(
            child: Text(
              label,
              style: color == null ? null : TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    bool isMemberAdmin,
    String username,
  ) async {
    final controller = ref.read(chatMembersControllerProvider);
    final messenger = ScaffoldMessenger.of(context);

    void say(String key) => messenger.showSnackBar(
          SnackBar(content: Text(key.tr(args: [username]))),
        );

    try {
      switch (action) {
        case 'promote':
          await controller.promoteToAdmin(chatId: chat.id, userId: memberId);
          say('chat_members.promoted_success');
        case 'demote':
          await controller.demoteFromAdmin(chatId: chat.id, userId: memberId);
          say('chat_members.demoted_success');
        case 'remove':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('chat_members.confirm_remove_title'.tr()),
              content: Text(
                'chat_members.confirm_remove_message'.tr(args: [username]),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('common.cancel'.tr()),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    'chat_members.remove'.tr(),
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          await controller.removeMember(chatId: chat.id, userId: memberId);
          say('chat_members.removed_success');
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('common.error'.tr(args: [e.toString()])),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

/// Saturated pill with white type — the same recipe for "you" and "admin", so
/// the badges are read as ONE set.
class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const _Pill({required this.label, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: Colors.white),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
