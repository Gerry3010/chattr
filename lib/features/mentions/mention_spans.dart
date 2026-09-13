// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'mention_utils.dart';

/// How prominent a mention is drawn.
///
/// The distinction is the whole point: in a group with traffic, every mention
/// looking the same means the reader has to *read* each one to find out whether
/// it concerns them. A mention that means them gets a tinted ground behind it,
/// everyone else's stays a coloured word.
enum _MentionEmphasis { other, me }

/// Alpha of the ground behind a mention that means the reader.
///
/// Low enough that the bubble colour still shows through (so it reads as a
/// marker, not as a second bubble), high enough to be findable when scrolling
/// past. Applied to the mention colour itself, so it stays in key with whatever
/// accent the theme sets and works on light and dark ground alike.
const double _kSelfMentionGroundAlpha = 0.22;

/// Splits a plain-text run into spans, highlighting standalone `@username`
/// mentions of [usernames] and setting apart those in [selfTokens].
///
/// Shared by every bubble that renders prose ([SafeMarkdown] and the link
/// bubble) — both grew their own copy of this, and a highlight that differs by
/// bubble type is a bug the reader gets to find.
///
/// Pass [selfTokens] empty to disable the self-emphasis (own messages: a
/// message the reader wrote themselves never „means" them, even when it says
/// `@all`).
List<InlineSpan> mentionSpans(
  String text,
  TextStyle style, {
  required Set<String> usernames,
  required Color mentionColor,
  Set<String> selfTokens = const {},
}) {
  if (usernames.isEmpty || !text.contains('@')) {
    return [TextSpan(text: text, style: style)];
  }
  TextStyle styleFor(_MentionEmphasis e) => style.copyWith(
    color: mentionColor,
    fontWeight: FontWeight.w600,
    backgroundColor: e == _MentionEmphasis.me
        ? mentionColor.withValues(alpha: _kSelfMentionGroundAlpha)
        : null,
  );

  final mine = styleFor(_MentionEmphasis.me);
  final others = styleFor(_MentionEmphasis.other);
  return [
    for (final seg in splitMentions(text, usernames, selfTokens: selfTokens))
      TextSpan(
        text: seg.text,
        style: seg.isMention ? (seg.targetsMe ? mine : others) : style,
      ),
  ];
}
