// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../features/mentions/mention_utils.dart';
import '../../../features/messages/message_links.dart';
import 'compact_link_preview.dart';

/// Bubble for text messages that contain URLs.
///
/// Rendered via chatview's `customMessageBuilder` because the package's
/// built-in text bubble hard-wires the AnyLinkPreview card (the big empty
/// white block). Shows the message text with tappable links plus a compact
/// favicon+title preview of the first URL.
class LinkMessageBubble extends StatefulWidget {
  final chatview.Message message;
  final bool isOwn;

  /// The chat this message lives in — threaded to [CompactLinkPreview] so an
  /// inline link video can dock back into this bubble from the PiP window.
  final String chatId;

  /// Member usernames (plus group keywords) whose standalone `@username`
  /// occurrences get the mention highlight — same set the markdown bubble uses.
  final Set<String> mentionUsernames;

  const LinkMessageBubble({
    super.key,
    required this.message,
    required this.isOwn,
    required this.chatId,
    this.mentionUsernames = const {},
  });

  @override
  State<LinkMessageBubble> createState() => _LinkMessageBubbleState();
}

class _LinkMessageBubbleState extends State<LinkMessageBubble> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  /// Plain text between links, with standalone `@username` runs highlighted
  /// (bold, link color) like [SafeMarkdown] does.
  List<InlineSpan> _plainWithMentions(String text, Color linkColor) {
    if (widget.mentionUsernames.isEmpty || !text.contains('@')) {
      return [TextSpan(text: text)];
    }
    final mentionStyle = TextStyle(
      color: linkColor,
      fontWeight: FontWeight.w600,
    );
    return [
      for (final seg in splitMentions(text, widget.mentionUsernames))
        seg.isMention
            ? TextSpan(text: seg.text, style: mentionStyle)
            : TextSpan(text: seg.text),
    ];
  }

  TextSpan _linkified(String text, Color textColor, Color linkColor) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    var index = 0;
    for (final match in urlPattern.allMatches(text)) {
      if (match.start > index) {
        spans.addAll(
          _plainWithMentions(text.substring(index, match.start), linkColor),
        );
      }
      // Trailing sentence punctuation stays plain text (same trimming as
      // extractUrls).
      final raw = match.group(0)!;
      final url = raw.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
      final uri = normalizeUrl(url);
      final recognizer = TapGestureRecognizer()
        ..onTap = uri == null
            ? null
            : () => launchUrl(uri, mode: LaunchMode.externalApplication);
      _recognizers.add(recognizer);
      spans.add(TextSpan(
        text: url,
        recognizer: recognizer,
        style: TextStyle(
          color: linkColor,
          decoration: TextDecoration.underline,
          decorationColor: linkColor,
        ),
      ));
      if (url.length < raw.length) {
        spans.add(TextSpan(text: raw.substring(url.length)));
      }
      index = match.end;
    }
    if (index < text.length) {
      spans.addAll(_plainWithMentions(text.substring(index), linkColor));
    }
    return TextSpan(
      style: TextStyle(color: textColor, fontSize: 16),
      children: spans,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor =
        widget.isOwn ? scheme.primaryContainer : scheme.surfaceContainerHigh;
    final textColor =
        widget.isOwn ? scheme.onPrimaryContainer : scheme.onSurface;
    // On the tinted own-bubble the primary link color has too little
    // contrast — reuse the text color there (underline marks the link).
    final linkColor =
        widget.isOwn ? scheme.onPrimaryContainer : scheme.primary;
    final urls = extractUrls(widget.message.message);

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
          Text.rich(
            _linkified(widget.message.message, textColor, linkColor),
          ),
          if (urls.isNotEmpty)
            CompactLinkPreview(
              url: urls.first,
              textColor: textColor,
              chatId: widget.chatId,
              messageId: widget.message.id,
            ),
          // chatview draws its "Edited" label only for MessageType.text, so
          // custom bubbles have to bring their own.
          if (widget.message.updatedAt != null)
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
