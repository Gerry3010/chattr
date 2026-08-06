// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../../core/navigation/app_page_route.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../features/chat_view/chat_view_controller.dart';
import '../../../features/chats/chat_model.dart';
import '../../../features/chats/chats_repository.dart';
import '../../../features/identity/identity_verification_controller.dart';
import '../../../features/profiles/profile_helpers.dart';
import '../../../features/profiles/profiles_controller.dart';
import '../../../features/profiles/widgets/profile_info_sheet.dart';
import '../../identity/safety_number_screen.dart';
import '../chat_detail_screen.dart';
import '../chat_members_screen.dart';
import 'message_search_delegate.dart';
import 'summary_sheet.dart';

/// Custom AppBar for the ChatViewScreen.
///
/// It integrates with the `chatview` package's [ChatViewAppBar] but uses
/// our [ChatViewController] for state management (typing status, member count).
class ChatViewAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final String chatId;

  const ChatViewAppBar({super.key, required this.chatId});

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatViewControllerProvider(chatId));
    final chat = state.chat;
    final typingUsers = state.typingUsers;
    final memberCount = state.usernames.length;

    // For a 1:1 chat there is no chat name, so show the other participant's
    // username (matching the chat-list behaviour). Groups use their name.
    String? otherUserName;
    String? otherUserId;
    if (chat == null || !chat.isGroup) {
      for (final entry in state.usernames.entries) {
        if (entry.key != state.currentUserId) {
          otherUserId = entry.key;
          otherUserName = entry.value;
          break;
        }
      }
    }

    // 1:1 chats show the peer's self-chosen avatar next to the title (groups
    // have no single peer, so no header avatar). A picture-less peer falls back
    // to an initials circle via the fork p12 patch (userName below).
    final peerProfile =
        otherUserId == null ? null : ref.watch(profileProvider(otherUserId));
    final peerAvatarUrl = ref
        .read(profilesControllerProvider.notifier)
        .avatarUrl(peerProfile?.avatarPath);

    // Group header avatar (00055): the uploaded group picture, else null (the
    // group falls back to no header avatar, unchanged from before).
    final groupAvatarUrl = (chat != null && chat.isGroup)
        ? ref.read(chatsRepositoryProvider).groupAvatarUrl(
              chat.avatarPath,
              cacheBust: chat.updatedAt.millisecondsSinceEpoch,
            )
        : null;
    final headerAvatarUrl = groupAvatarUrl ?? peerAvatarUrl;

    final verification =
        ref.watch(chatVerificationProvider(chatId)).asData?.value;

    final displayName = (chat != null && chat.isGroup
            ? chat.name
            : otherUserName) ??
        'chat_list.chat_title'.tr(
          args: [chatId.substring(0, 8)],
        );

    return chatview.ChatViewAppBar(
      elevation: 0,
      backGroundColor: Theme.of(context).colorScheme.surface,
      // Header avatar: the peer's picture for 1:1, the group's picture for
      // groups (00055); userName drives the initials fallback for 1:1.
      profilePicture: headerAvatarUrl,
      userName: otherUserName,
      // Tap the header avatar/title → profile & contact sheet (p14 hook). Needs
      // a loaded chat; the closure captures the resolved peer id/name.
      onTitleTap: chat == null
          ? null
          : () => showProfileInfoSheet(
                context: context,
                chat: chat,
                displayName: displayName,
                otherUserId: chat.isGroup ? null : otherUserId,
              ),
      chatTitle: displayName,
      chatTitleTextStyle: TextStyle(
        color: Theme.of(context).colorScheme.onSurface,
        fontWeight: FontWeight.bold,
        fontSize: 18,
      ),
      // Member count only makes sense for groups — a 1:1 always has 2 and
      // reading "2 Mitglieder" under a person's name is odd. 1:1 shows nothing
      // (until we have presence/last-seen); typing status still shows for both.
      userStatus: typingUsers.isNotEmpty
          ? _formatTypingStatus(typingUsers)
          : ((chat?.isGroup ?? false) && memberCount >= 1
              ? '$memberCount ${'chat_view.members'.tr()}'
              : null),
      userStatusTextStyle: TextStyle(
        color: typingUsers.isNotEmpty
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 12,
        fontStyle: typingUsers.isNotEmpty ? FontStyle.italic : FontStyle.normal,
      ),
      actions: [
        // Chat summary — MCP chats ONLY. In a normal chat the other side never
        // consented to a model reading along; in an MCP chat the agent is a
        // member by the owner's own choice. Not negotiable.
        if (chat?.isMcp ?? false)
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            onPressed: () =>
                showSummarySheet(context: context, chatId: chatId),
            tooltip: 'summary.title'.tr(),
          ),
        if (verification != null && verification.peers.isNotEmpty)
          _verificationShield(
            context,
            verification,
            chat: chat,
            otherUserId: otherUserId,
            otherUserName: otherUserName,
          ),
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: () => showSearch<void>(
            context: context,
            delegate: MessageSearchDelegate(
              controller:
                  ref.read(chatViewControllerProvider(chatId).notifier),
              usernames: state.usernames,
              currentUserId: state.currentUserId,
            ),
          ),
          tooltip: 'messages_search.title'.tr(),
        ),
        IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: chat == null
              ? null
              : () {
                  Navigator.push(
                    context,
                    appPageRoute<void>(
                      builder: (_) => ChatDetailScreen(chat: chat),
                    ),
                  );
                },
          tooltip: 'chat_view.chat_info'.tr(),
        ),
      ],
    );
  }

  /// E2E verification shield (audit C1, warn-only): red when any co-member's
  /// key no longer matches its pinned identity, green when everyone is
  /// verified, grey otherwise. Tapping opens the safety-number screen (1:1) or
  /// the members list (group), where each member can be verified.
  Widget _verificationShield(
    BuildContext context,
    ChatVerificationSummary verification, {
    required Chat? chat,
    required String? otherUserId,
    required String? otherUserName,
  }) {
    final (icon, color) = verification.anyChanged
        ? (Icons.gpp_bad, Colors.red)
        : verification.allVerified
            ? (Icons.verified_user, Colors.green)
            : (Icons.shield_outlined, Colors.grey);

    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: 'identity.title'.tr(),
      onPressed: () {
        if (chat != null && chat.isGroup) {
          Navigator.push(
            context,
            appPageRoute<void>(
              builder: (_) => ChatMembersScreen(chat: chat),
            ),
          );
        } else if (otherUserId != null) {
          Navigator.push(
            context,
            appPageRoute<void>(
              builder: (_) => SafetyNumberScreen(
                userId: otherUserId,
                username: otherUserName ?? otherUserId,
              ),
            ),
          );
        }
      },
    );
  }

  String _formatTypingStatus(List<String> typingUsers) {
    if (typingUsers.isEmpty) return '';
    if (typingUsers.length == 1) {
      return 'chat_view.typing_single'.tr(args: [typingUsers[0]]);
    } else if (typingUsers.length == 2) {
      return 'chat_view.typing_double'.tr(
        args: [typingUsers[0], typingUsers[1]],
      );
    } else {
      return 'chat_view.typing_multiple'.tr(
        args: [typingUsers.length.toString()],
      );
    }
  }
}
