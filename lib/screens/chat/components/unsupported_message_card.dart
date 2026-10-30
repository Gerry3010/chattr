// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/crypto/envelope_version.dart';

/// Stands in for a message this build cannot open yet.
///
/// Before this existed, such a message simply was not there: it failed to
/// decrypt, was never stored, and left no trace in the chat. A gap nobody can
/// see is a gap nobody reports — the person would just never learn that
/// something had been said.
///
/// The card deliberately shows what it CAN say (that a message exists, from
/// whom, at what time — the bubble around it carries those) and names the one
/// thing that helps: updating. It does not pretend to be the message.
///
/// The wording avoids blaming the sender. They did nothing unusual; this
/// device is simply behind.
class UnsupportedMessageCard extends StatelessWidget {
  const UnsupportedMessageCard({
    super.key,
    required this.notice,
    required this.isOwn,
  });

  final UnsupportedEnvelopeNotice notice;
  final bool isOwn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The warning role, not the error role: nothing is broken and nothing is
    // lost — the message is waiting, and there is a way to reach it.
    final bg = scheme.surfaceContainerHighest;
    final fg = scheme.onSurfaceVariant;

    return Container(
      key: const ValueKey('unsupported_message_card'),
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.system_update_alt, size: 20, color: fg),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'chat_view.unsupported_title'.tr(),
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: fg, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  'chat_view.unsupported_body'.tr(),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
