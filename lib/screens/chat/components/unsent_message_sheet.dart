// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../features/messages/outgoing_message.dart';

/// The red mark beside an own bubble the server never got (CHAT-66). It takes
/// the place of the ticks, so it is where people already look to see whether
/// a message went out.
class UnsentReceipt extends StatelessWidget {
  const UnsentReceipt({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'chat_view.unsent.semantic'.tr(),
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 2, 4),
          child: Icon(
            Icons.error,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
    );
  }
}

/// What can be done with an own message the server does not have: send it
/// again, copy it, or drop it. While its send is still running there is
/// nothing to decide yet, so only copying is offered.
Future<void> showUnsentMessageSheet(
  BuildContext context, {
  required SendFailure? failure,
  required bool sending,
  required VoidCallback onRetry,
  required VoidCallback onDiscard,
  required VoidCallback onCopy,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => UnsentMessageSheet(
      failure: failure,
      sending: sending,
      onRetry: onRetry,
      onDiscard: onDiscard,
      onCopy: onCopy,
    ),
  );
}

class UnsentMessageSheet extends StatelessWidget {
  const UnsentMessageSheet({
    super.key,
    required this.failure,
    required this.sending,
    required this.onRetry,
    required this.onDiscard,
    required this.onCopy,
  });

  final SendFailure? failure;
  final bool sending;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reason = switch (failure) {
      SendFailure.keysNotReady => 'chat_view.unsent.keys_not_ready',
      SendFailure.rejected => 'chat_view.unsent.rejected',
      _ => 'chat_view.unsent.network',
    };
    void then(VoidCallback action) {
      Navigator.of(context).pop();
      action();
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              (sending ? 'chat_view.unsent.sending' : 'chat_view.unsent.title')
                  .tr(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (!sending)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                reason.tr(),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          if (!sending)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text('chat_view.unsent.retry'.tr()),
              onTap: () => then(onRetry),
            ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: Text('chat_view.copy'.tr()),
            onTap: () => then(onCopy),
          ),
          if (!sending)
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(
                'chat_view.unsent.discard'.tr(),
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => then(onDiscard),
            ),
        ],
      ),
    );
  }
}
