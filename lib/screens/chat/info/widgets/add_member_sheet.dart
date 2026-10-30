// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../../core/logging/logger_service.dart';
import '../../../../core/navigation/app_page_route.dart';
import '../../../../features/chats/chat_model.dart';
import '../../../qr/group_chat_qr_display.dart';
import '../../../qr/qr_scanner_screen.dart';

/// THE invitation sheet — the only place the group QR code stands.
///
/// In the end-to-end model an admin cannot simply "add" anybody: whoever joins
/// generates their own key pair and makes a request. "Add" therefore means:
/// share the invitation (QR or chat id) — or, the other way round, scan the
/// other person's QR code.
///
/// Before, the QR code stood in THREE places: as a permanent card in the info
/// view and in two separate sheets, only one of which offered scanning.
Future<void> showAddMemberSheet({
  required BuildContext context,
  required Chat chat,
}) {
  logger.info('Add member: showing group invite for chat ${chat.id}');
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'chat_detail.add_member'.tr(),
              style: Theme.of(sheetContext).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'chat_detail.add_member_hint'.tr(),
              style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            // The reverse route: the admin scans the other person's QR code.
            // The new member then has no chat key yet — their app fetches that
            // itself at the next look at the group.
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: Text('chat_members.scan_to_add'.tr()),
              onPressed: () async {
                Navigator.pop(sheetContext);
                await Navigator.push<Map<String, dynamic>>(
                  context,
                  appPageRoute(
                    builder: (_) => QrScannerScreen(addToChatId: chat.id),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 12),
            GroupChatQrDisplay(chat: chat),
          ],
        ),
      ),
    ),
  );
}
