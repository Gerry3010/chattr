// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// "Copy mode" for a message (CHAT-15): the text in a sheet where it can be
/// marked and copied in parts. A double tap on a text bubble opens it.
///
/// A sheet rather than selection inside the bubble: the bubbles are drawn by
/// the chatview package as plain text, and every bubble already carries swipe,
/// long-press and double-tap handlers that a selectable text would fight with.
Future<void> showTextSelectionSheet(BuildContext context, String text) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _TextSelectionSheet(text: text),
  );
}

class _TextSelectionSheet extends StatelessWidget {
  const _TextSelectionSheet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'chat_view.select_text_hint'.tr(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    key: const ValueKey('text_selection_sheet_text'),
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('text_selection_copy_all'),
                  icon: const Icon(Icons.copy_all),
                  label: Text('chat_view.copy_all'.tr()),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    final navigator = Navigator.of(context);
                    await Clipboard.setData(ClipboardData(text: text));
                    navigator.pop();
                    messenger?.showSnackBar(
                      SnackBar(content: Text('chat_view.copied'.tr())),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
