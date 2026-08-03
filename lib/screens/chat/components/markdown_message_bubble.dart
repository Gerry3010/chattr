// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'safe_markdown.dart';

/// Bubble for text messages that contain markdown (bold/italic/lists/code/…).
///
/// Rendered via chatview's `customMessageBuilder` because the package's
/// built-in text bubble hard-wires plain-text rendering (same reason as
/// [LinkMessageBubble]). Mirrors that bubble's chrome so a markdown message
/// looks identical to a normal one, just with the formatting applied.
class MarkdownMessageBubble extends StatelessWidget {
  const MarkdownMessageBubble({
    super.key,
    required this.message,
    required this.isOwn,
    this.mentionUsernames = const {},
  });

  final chatview.Message message;
  final bool isOwn;

  /// Member usernames to highlight as `@mentions` in the text (1.10).
  final Set<String> mentionUsernames;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = isOwn
        ? scheme.primaryContainer
        : scheme.surfaceContainerHigh;
    final textColor = isOwn ? scheme.onPrimaryContainer : scheme.onSurface;
    // On the tinted own-bubble the primary link color has too little contrast —
    // reuse the text color there (the underline still marks the link).
    final linkColor = isOwn ? scheme.onPrimaryContainer : scheme.primary;

    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.75,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SafeMarkdown(
            data: message.message,
            textColor: textColor,
            linkColor: linkColor,
            mentionUsernames: mentionUsernames,
          ),
          // chatview draws its "Edited" label only for MessageType.text, so
          // custom bubbles have to bring their own.
          if (message.updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'chat_view.edited'.tr(),
                style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
