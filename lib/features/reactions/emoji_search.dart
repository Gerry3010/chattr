// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

/// Searches emoji by their keywords.
///
/// Why not `EmojiPickerUtils.searchEmoji`: that is a **singleton with a cache
/// that is never cleared**. On the first search it memorises the emoji set of
/// that moment and goes on serving it until the app quits. So whoever searches,
/// then changes their skin tone and searches again would get the hits in the
/// **old** tone — and would send a reaction that matches no other one in the
/// chat. The same trap on a language change.
///
/// The matching rule is deliberately the same as in the package, so searching
/// does not feel different from usual: every word entered must be the **start**
/// of a keyword ("grav" finds gravestone), and all words must match. In
/// addition, a directly pasted emoji matches itself.
List<Emoji> findEmoji(String input, List<CategoryEmoji> emojiSet) {
  final words = input
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];

  final literal = input.trim();
  final matches = <Emoji>[];
  // The package set carries a good dozen emoji twice (🧵 three times over);
  // without this set they would stand twice in the hits as well.
  final seen = <String>{};

  for (final category in emojiSet) {
    // The history is a selection out of the other categories, not one of its
    // own.
    if (category.category == Category.RECENT) continue;
    for (final emoji in category.emoji) {
      if (!seen.add(emoji.emoji)) continue;
      if (emoji.emoji == literal) {
        matches.add(emoji);
        continue;
      }
      final keywords =
          emoji.keywords.map((k) => k.toLowerCase()).toList();
      if (words.every((w) => keywords.any((s) => s.startsWith(w)))) {
        matches.add(emoji);
      }
    }
  }
  return matches;
}
