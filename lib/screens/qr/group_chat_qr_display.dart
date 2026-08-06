// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../features/auth/auth.dart';
import '../../features/chats/chat_model.dart';
import '../../features/invites/invite_envelope.dart';
import '../../features/invites/invites_controller.dart';
import '../../features/messages/message_forward_service.dart';
import '../chat/components/forward_chat_sheet.dart';

class GroupChatQrDisplay extends ConsumerWidget {
  final Chat chat;

  const GroupChatQrDisplay({
    super.key,
    required this.chat,
  });

  /// Admin path (1.13): share the group INTO other chats as invitation
  /// messages — one token per target chat (a shared token would defeat the
  /// "only valid in the chat it was sent to" rule), then the envelope goes
  /// out through the ordinary forward pipeline.
  Future<void> _shareInvite(BuildContext context, WidgetRef ref) async {
    final targets = await showForwardChatSheetMulti(
      context: context,
      excludeChatId: chat.id,
      titleKey: 'invite.share_to',
    );
    if (targets == null || targets.isEmpty || !context.mounted) return;

    final invites = ref.read(invitesControllerProvider);
    final forward = MessageForwardService(ref);
    var sent = 0;
    try {
      for (final target in targets) {
        final token = await invites.createInvite(
          chatId: chat.id,
          targetChatId: target,
        );
        await forward.forwardText(
          target,
          InviteEnvelope(chatId: chat.id, chatName: chat.name!, token: token)
              .encode(),
        );
        sent++;
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('invite.sent'.tr(args: ['$sent']))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('invite.send_failed'.tr(args: ['$e'])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _shareSystem() {
    SharePlus.instance.share(ShareParams(
      text: 'group_qr.share_message'.tr(args: [chat.name!, chat.id]),
      subject: 'group_qr.share_subject'.tr(args: [chat.name!]),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only show QR for group chats (with name)
    if (chat.name == null) {
      return const SizedBox.shrink();
    }

    // Create QR Code data for group chat
    final qrData = jsonEncode({
      'type': 'chattr_group',
      'chat_id': chat.id,
      'chat_name': chat.name,
    });

    // Invitation messages are admin-only — the visibility here is politeness,
    // the rule itself lives in create_chat_invite (00069). Non-admins keep
    // the plain system share (chat id + name), which stays approval-gated.
    final userId = ref.watch(authControllerProvider);
    final isAdmin = userId != null && chat.isAdmin(userId);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  Icons.qr_code,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'group_qr.title'.tr(),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (isAdmin)
                  IconButton(
                    icon: const Icon(Icons.forward_to_inbox),
                    onPressed: () => _shareInvite(context, ref),
                    tooltip: 'invite.share_tooltip'.tr(),
                  ),
                IconButton(
                  icon: const Icon(Icons.share),
                  onPressed: _shareSystem,
                  tooltip: 'group_qr.share'.tr(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'group_qr.description'.tr(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),

            // QR Code centered
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                    width: 1,
                  ),
                ),
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Chat ID (for manual sharing)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.fingerprint,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chat.id,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: chat.id));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('group_qr.id_copied'.tr()),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    tooltip: 'group_qr.copy_id'.tr(),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
