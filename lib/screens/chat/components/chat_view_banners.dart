// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/navigation/app_page_route.dart';
import '../../../features/auth/auth_controller.dart';
import '../../../features/chat_view/chat_view_controller.dart';
import '../../../features/chats/chat_members_controller.dart';
import '../../../features/chats/chats_controller.dart';
import '../../../features/chats/lost_keys_provider.dart';
import '../../../features/identity/identity_verification_controller.dart';
import '../../identity/safety_number_screen.dart';

/// Displays status banners at the top of the chat view.
///
/// Shows informational or warning banners based on membership status:
/// - Pending approval: User is waiting for access.
/// - No longer a member: User was removed or chat is restricted.
class ChatViewBanners extends ConsumerWidget {
  final String chatId;

  const ChatViewBanners({super.key, required this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chatViewControllerProvider(chatId));

    Widget? banner;
    if (state.isNotMember && state.isPending) {
      banner = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: Colors.orange[100],
        child: Row(
          children: [
            Icon(Icons.hourglass_empty, color: Colors.orange[900]),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'chat_view.pending_approval'.tr(),
                style: TextStyle(
                  color: Colors.orange[900],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final userId = ref.read(authControllerProvider);
                if (userId == null) return;
                await ref
                    .read(chatMembersControllerProvider)
                    .cancelRequest(chatId: chatId, userId: userId);
                if (context.mounted) {
                  Navigator.pop(context); // leave the chat view
                }
              },
              child: Text(
                'chat_view.withdraw_request'.tr(),
                style: TextStyle(
                  color: Colors.orange[900],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (state.isNotMember && !state.isPending) {
      banner = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: Colors.red[100],
        child: Row(
          children: [
            Icon(Icons.block, color: Colors.red[900]),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'chat_view.no_longer_member'.tr(),
                style: TextStyle(
                  color: Colors.red[900],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('chat_view.delete_chat_title'.tr()),
                    content: Text('chat_view.delete_chat_message'.tr()),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text('chat_view.cancel'.tr()),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        child: Text('chat_view.delete'.tr()),
                      ),
                    ],
                  ),
                );

                if (confirmed == true && context.mounted) {
                  await ref
                      .read(chatViewControllerProvider(chatId).notifier)
                      .deleteChatLocally();
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                }
              },
              child: Text(
                'chat_view.delete'.tr(),
                style: TextStyle(
                  color: Colors.red[900],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Lost local key (#11): our KEM private key is gone but the public key is
    // still on the server (secure-storage wipe, #149). New incoming messages
    // can't be decrypted until we deliberately rotate a fresh key. Shown to a
    // member only; offer the rotate directly.
    if (banner == null && ref.watch(lostKeysProvider).contains(chatId)) {
      banner = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: Colors.amber[100],
        child: Row(
          children: [
            Icon(Icons.key_off, color: Colors.amber[900]),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'chat_view.lost_key'.tr(),
                style: TextStyle(
                  color: Colors.amber[900],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('chat_view.lost_key_title'.tr()),
                    content: Text('chat_view.lost_key_message'.tr()),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text('chat_view.cancel'.tr()),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text('chat_view.regenerate_key'.tr()),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ref
                      .read(chatsControllerProvider.notifier)
                      .rotateChatKey(chatId);
                }
              },
              child: Text(
                'chat_view.regenerate_key'.tr(),
                style: TextStyle(
                  color: Colors.amber[900],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Key-change warning (audit C1, warn-only): a co-member's key no longer
    // matches its pinned identity — possible MITM or a reinstall/recovery.
    // Membership banners take precedence; sending stays possible either way.
    if (banner == null) {
      final verification =
          ref.watch(chatVerificationProvider(chatId)).asData?.value;
      final changed = verification?.changedPeers ?? const <String>[];
      if (changed.isNotEmpty) {
        final firstId = changed.first;
        final name = state.usernames[firstId] ?? firstId.substring(0, 8);
        banner = Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          color: Colors.red[100],
          child: Row(
            children: [
              Icon(Icons.gpp_bad, color: Colors.red[900]),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'chat_view.verification_changed'.tr(args: [name]),
                  style: TextStyle(
                    color: Colors.red[900],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    appPageRoute<void>(
                      builder: (_) => SafetyNumberScreen(
                        userId: firstId,
                        username: name,
                      ),
                    ),
                  );
                },
                child: Text(
                  'chat_view.verify_now'.tr(),
                  style: TextStyle(
                    color: Colors.red[900],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }

    if (banner == null) return const SizedBox.shrink();
    // SafeArea(bottom: false) keeps the banner out from under the status bar /
    // Dynamic Island — the chat view has no Scaffold AppBar above it.
    return SafeArea(bottom: false, child: banner);
  }
}
