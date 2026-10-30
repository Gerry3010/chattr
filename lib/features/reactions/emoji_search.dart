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
/// The matching rule follows the package — every word entered must be the
/// **start** of a keyword ("grav" finds gravestone), all words must match, and
/// a directly pasted emoji matches itself — with one deliberate difference: a
/// keyword may be a PHRASE, and the words inside it count too.
///
/// The package compares against the whole phrase, so only its first word ever
/// matched. That left about a third of the additions half-findable: 😶‍🌫️ hid
/// behind "Gesicht in Wolken" and could not be reached by "Nebel", 🧑‍🦰 not by
/// "Haar", ❤️‍🩹 not by "Verband". Nobody types the beginning of a phrase; they
/// type the word they have in mind.
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
      final tokens = _tokensOf(emoji);
      if (words.every((w) => tokens.any((t) => t.startsWith(w)))) {
        matches.add(emoji);
      }
    }
  }
  return matches;
}

/// Everything a keyword offers to match against: the whole phrase plus each
/// word in it, lowercased.
///
/// Memoised on the keyword string itself, which is also what makes it correct
/// across languages and skin tones — a different language is a different string
/// and gets its own entry, while the same emoji in six tones shares one. Without
/// it this would re-split some 1900 keyword lists on every keystroke.
final Map<String, List<String>> _tokenCache = {};

/// Word boundaries: anything that is neither letter nor digit. Keeps umlauts
/// (\p{L}), and splits "Orang-Utan" into "orang" and "utan" as well as keeping
/// the whole "orang-utan".
final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

List<String> _tokensOf(Emoji emoji) => _tokenCache.putIfAbsent(emoji.name, () {
      final out = <String>{};
      for (final keyword in emoji.keywords) {
        final phrase = keyword.toLowerCase().trim();
        if (phrase.isEmpty) continue;
        out.add(phrase);
        for (final word in phrase.split(_nonWord)) {
          if (word.isNotEmpty) out.add(word);
        }
      }
      return out.toList(growable: false);
    });
