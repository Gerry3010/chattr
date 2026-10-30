// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../core/crypto/undecryptable_notice.dart';

/// Stands in for a message this device received but cannot open.
///
/// Until 1.32.2 such a message existed only as an error in the log, and the
/// chat showed nothing at all. The card says THAT something arrived (the
/// bubble around it carries who and when) and, as far as it can, why. For a
/// missing one-time key it names a recovery on another device as the usual
/// cause without claiming it: a wiped database looks the same from here.
class UndecryptableMessageCard extends StatelessWidget {
  const UndecryptableMessageCard({super.key, required this.notice});

  final UndecryptableNotice notice;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurfaceVariant;
    final text = Theme.of(context).textTheme;
    final body = notice.reason == UndecryptableNotice.prekey
        ? 'chat_view.undecryptable_body_prekey'
        : 'chat_view.undecryptable_body_keys';

    return Container(
      key: const ValueKey('undecryptable_message_card'),
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 20, color: fg),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'chat_view.undecryptable_title'.tr(),
                  style: text.bodyMedium
                      ?.copyWith(color: fg, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(body.tr(), style: text.bodySmall?.copyWith(color: fg)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
