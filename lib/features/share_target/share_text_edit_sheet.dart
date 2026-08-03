// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Edit step for a shared text/URL before it is sent: the shared content
/// arrives prefilled and editable (comment before/after the link, trim it, …).
/// Returns the text to send, or null when the user backs out.
Future<String?> showShareTextEditSheet(
  BuildContext context, {
  required String initialText,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: _ShareTextEditSheet(initialText: initialText),
    ),
  );
}

class _ShareTextEditSheet extends StatefulWidget {
  final String initialText;

  const _ShareTextEditSheet({required this.initialText});

  @override
  State<_ShareTextEditSheet> createState() => _ShareTextEditSheetState();
}

class _ShareTextEditSheetState extends State<_ShareTextEditSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + viewInsets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'share_target.edit_before_send'.tr(),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('share_text_edit_field'),
            controller: _controller,
            autofocus: true,
            minLines: 1,
            maxLines: 6,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) => FilledButton.icon(
                icon: const Icon(Icons.send),
                label: Text('share_target.send'.tr()),
                onPressed: value.text.trim().isEmpty ? null : _send,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
