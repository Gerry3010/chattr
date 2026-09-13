// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../screens/chat/components/safe_markdown.dart';
import '../../mentions/mention_spans.dart';
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

    if (hasMarkdown(caption)) {
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
      return SelectableText(caption, style: style);
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
