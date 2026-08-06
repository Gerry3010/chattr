// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/app_page_route.dart';
import '../../../screens/chat/chat_detail_screen.dart';
import '../../../screens/chat/chat_members_screen.dart';
import '../../../screens/identity/safety_number_screen.dart';
import '../../chats/chat_model.dart';
import '../../chats/widgets/group_avatar.dart';
import '../../identity/identity_verification_controller.dart';
import 'user_avatar.dart';

/// A compact profile/contact sheet opened by tapping a chat avatar (header or
/// chat-list row, #avatar-tap) OR a member row in a group (member view). Shows
/// the peer/group avatar + name, the end-to-end verification status, and quick
/// actions: verify (a specific peer) / members (group overview) and the
/// chat/contact info screen.
///
/// [otherUserId] identifies the person being shown: the 1:1 peer, or the tapped
/// group member. It is null only for the group OVERVIEW (header/list tap on a
/// group), which shows the group icon + members action. When set — even inside
/// a group — the sheet renders that person's avatar and a verify action.
Future<void> showProfileInfoSheet({
  required BuildContext context,
  required Chat chat,
  required String displayName,
  String? otherUserId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => _ProfileInfoSheet(
      chat: chat,
      displayName: displayName,
      otherUserId: otherUserId,
    ),
  );
}

class _ProfileInfoSheet extends ConsumerWidget {
  final Chat chat;
  final String displayName;
  final String? otherUserId;

  const _ProfileInfoSheet({
    required this.chat,
    required this.displayName,
    this.otherUserId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final verification =
        ref.watch(chatVerificationProvider(chat.id)).asData?.value;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _avatar(context, scheme),
            const SizedBox(height: 12),
            Text(
              displayName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            // The chip is a CHAT-WIDE summary → meaningful for a 1:1 peer or a
            // group overview, but misleading on a single group member, so hide
            // it there (the member's own trust shield lives on the row).
            if (verification != null && !_isGroupMemberView)
              _statusChip(context, verification),
            const SizedBox(height: 16),
            ..._actions(context),
          ],
        ),
      ),
    );
  }

  /// True when showing one member of a group (vs. the group overview or a 1:1).
  bool get _isGroupMemberView => chat.isGroup && otherUserId != null;

  Widget _avatar(BuildContext context, ColorScheme scheme) {
    // A specific person (1:1 peer or tapped group member) → their avatar; only
    // the group OVERVIEW (no otherUserId) shows the group avatar — the actual
    // uploaded picture (1.8.1 fix), tappable to the group viewer.
    if (otherUserId == null) {
      return GroupAvatar(
        chatId: chat.id,
        radius: 44,
        onTap: () => showGroupAvatarViewer(context, chat.id),
      );
    }
    // Tap the person's avatar → open it large (#156).
    return UserAvatar(
      userId: otherUserId!,
      radius: 44,
      onTap: () => showAvatarViewer(context, otherUserId!),
    );
  }

  Widget _statusChip(BuildContext context, ChatVerificationSummary v) {
    final (icon, color, label) = v.anyChanged
        ? (Icons.gpp_bad, Colors.red, 'identity.state_changed'.tr())
        : v.allVerified
            ? (Icons.verified_user, Colors.green, 'identity.state_verified'.tr())
            : (Icons.shield_outlined, Colors.grey,
                'identity.state_unverified'.tr());
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }

  List<Widget> _actions(BuildContext context) {
    return [
      // A specific person (1:1 peer or group member) → their safety number;
      // the group overview → members list. Pop the sheet first so back returns
      // to the chat.
      if (otherUserId != null)
        ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: Text('profile.verify'.tr()),
          onTap: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => SafetyNumberScreen(
                  userId: otherUserId!,
                  username: displayName,
                ),
              ),
            );
          },
        )
      else
        ListTile(
          leading: const Icon(Icons.group_outlined),
          title: Text('profile.members'.tr()),
          onTap: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => ChatMembersScreen(chat: chat)),
            );
          },
        ),
      // Contact / chat info (the header ⓘ target) — Gerry asked for it in here.
      ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text('profile.contact_info'.tr()),
        onTap: () {
          Navigator.pop(context);
          Navigator.push(
            context,
            appPageRoute<void>(builder: (_) => ChatDetailScreen(chat: chat)),
          );
        },
      ),
    ];
  }
}
