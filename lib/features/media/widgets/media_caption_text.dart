// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' show emojiUpscaledSpans;
import 'package:flutter/material.dart';

import '../../../screens/chat/components/safe_markdown.dart';
import '../../mentions/mention_spans.dart';
import '../../messages/inline_emoji.dart';
import '../../messages/message_links.dart';
import '../../messages/message_markdown.dart';

/// The caption under a media message or album.
///
/// One widget for both, because the two used to carry identical copies of this
/// — and a copy is where the next difference hides. Sits inside the
/// sender-coloured bubble (#27), so the on-bubble colour is the readable one.
class MediaCaptionText extends StatelessWidget {
  const MediaCaptionText({
    super.key,
    required this.caption,
    required this.isOwn,
    this.mentionUsernames = const {},
    this.selfMentionTokens = const {},
  });

  final String caption;
  final bool isOwn;

  /// Member usernames highlighted as `@mentions`, and the subset that means the
  /// reader (tinted ground). Both empty → caption renders as before.
  final Set<String> mentionUsernames;
  final Set<String> selfMentionTokens;

  static const double _fontSize = 15;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textColor = isOwn ? scheme.onPrimaryContainer : scheme.onSurface;
    // On the tinted own bubble the primary link color has too little contrast —
    // reuse the text color there (the underline still marks the link).
    final linkColor = isOwn ? scheme.onPrimaryContainer : scheme.primary;

    // A bare link is not markdown, so it used to end up as plain text: not
    // coloured, not tappable (Gerry, 2026-10-23). SafeMarkdown links bare
    // URLs and addresses the same way a text bubble does.
    if (hasMarkdown(caption) ||
        extractUrls(caption).isNotEmpty ||
        extractEmails(caption).isNotEmpty) {
      return SafeMarkdown(
        data: caption,
        textColor: textColor,
        linkColor: linkColor,
        fontSize: _fontSize,
        mentionUsernames: mentionUsernames,
        selfMentionTokens: selfMentionTokens,
      );
    }

    final style = TextStyle(color: textColor, fontSize: _fontSize);
    if (mentionUsernames.isEmpty || !caption.contains('@')) {
      // Emoji runs get the platform's gap correction, as in the composer.
      final emoji = plainEmojiStyle(_fontSize);
      if (emoji == null) return SelectableText(caption, style: style);
      return SelectableText.rich(TextSpan(
        style: style,
        children: emojiUpscaledSpans(caption, emojiStyle: emoji),
      ));
    }
    // Selectable stays selectable: the mention highlight is a style on the
    // spans, not a different widget.
    return SelectableText.rich(
      TextSpan(
        style: style,
        children: mentionSpans(
          caption,
          style,
          usernames: mentionUsernames,
          mentionColor: linkColor,
          selfTokens: selfMentionTokens,
        ),
      ),
    );
  }
}
