// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The package's emoji set has holes — 🪦 and roughly 285 others are missing —
// and we add them via anchors: "this emoji belongs behind that one". The
// dangerous case is a package update that renames or removes an anchor: then
// the addition would no longer find its place and the emoji would disappear
// SILENTLY. That is exactly what the first test checks.

import 'package:chattr/features/reactions/chattr_emoji_set.dart';
import 'package:chattr/features/reactions/emoji_search.dart';
import 'package:chattr/features/reactions/emoji_supplement.g.dart';
import 'package:chattr/features/reactions/skin_tone_controller.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _de = Locale('de');
const _en = Locale('en');

/// Catches everything via noSuchMethod; `read` returns the value that was set.
class _FakeSecureStorage implements FlutterSecureStorage {
  final String? stored;
  _FakeSecureStorage(this.stored);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value(stored);
    if (invocation.memberName == #write) return Future<void>.value();
    throw UnimplementedError('${invocation.memberName}');
  }
}

Iterable<String> _allCharacters(List<CategoryEmoji> emojiSet) sync* {
  for (final k in emojiSet) {
    for (final e in k.emoji) {
      yield e.emoji;
    }
  }
}

void main() {
  group('Nachtrag', () {
    test('every anchor finds its emoji in the package set', () {
      // If this fails, an emoji has silently disappeared after a package update
      // → re-run scripts/gen-emoji-supplement.py.
      expect(anchorsWithoutMatch(getDefaultEmojiLocale(_de)), isEmpty);
    });

    test('adds exactly the missing emoji, without duplicates', () {
      final basis = getDefaultEmojiLocale(_de);
      final supplemented = supplementEmojiSet(basis, _de);

      final before = _allCharacters(basis).toList();
      final after = _allCharacters(supplemented).toList();

      expect(after.length, before.length + supplementEmoji.length);
      expect(after.toSet().containsAll(before), isTrue,
          reason: 'the package set stays complete');

      // Uniqueness across the WHOLE grid cannot be checked: the package set
      // itself carries a good dozen emoji twice (🧵 three times). What is
      // checkable — and the only part that is ours — is that the addition
      // brings in nothing that already existed and inserts nothing twice.
      final added = supplementEmoji.map((n) => n.character).toList();
      expect(added.toSet().length, added.length);
      expect(before.toSet().intersection(added.toSet()), isEmpty);
    });

    test('🪦 stands in the same category as its anchor ⚰️', () {
      final supplemented = supplementEmojiSet(getDefaultEmojiLocale(_de), _de);

      Category? categoryOf(String character) {
        for (final k in supplemented) {
          if (k.emoji.any((e) => e.emoji == character)) return k.category;
        }
        return null;
      }

      expect(categoryOf('🪦'), isNotNull);
      expect(categoryOf('🪦'), categoryOf('⚰️'));
    });

    test('added emoji are searchable in both languages', () {
      final de = supplementEmojiSet(getDefaultEmojiLocale(_de), _de);
      expect(findEmoji('Grabstein', de).map((e) => e.emoji), contains('🪦'));
      // The start of a word suffices — that is how the package searches too.
      expect(findEmoji('grab', de).map((e) => e.emoji), contains('🪦'));

      final en = supplementEmojiSet(getDefaultEmojiLocale(_en), _en);
      expect(findEmoji('headstone', en).map((e) => e.emoji), contains('🪦'));
    });

    test('the language decides the keywords', () {
      String keywordsOf(List<CategoryEmoji> emojiSet, String character) => emojiSet
          .expand((k) => k.emoji)
          .firstWhere((e) => e.emoji == '🪦')
          .name;

      expect(
        keywordsOf(supplementEmojiSet(getDefaultEmojiLocale(_de), _de), '🪦'),
        contains('Grabstein'),
      );
      expect(
        keywordsOf(supplementEmojiSet(getDefaultEmojiLocale(_en), _en), '🪦'),
        contains('headstone'),
      );
    });
  });

  group('Suche', () {
    List<CategoryEmoji> emojiSet() =>
        supplementEmojiSet(getDefaultEmojiLocale(_de), _de);

    test('empty input yields nothing', () {
      expect(findEmoji('', emojiSet()), isEmpty);
      expect(findEmoji('   ', emojiSet()), isEmpty);
    });

    test('all words have to match', () {
      // "laugh" alone matches a lot; together with "tear" less remains.
      final eines = findEmoji('lachen', emojiSet());
      final two = findEmoji('lachen träne', emojiSet());
      expect(two.length, lessThan(eines.length));
      expect(two, isNotEmpty);
    });

    test('a pasted emoji finds itself', () {
      expect(findEmoji('🪦', emojiSet()).map((e) => e.emoji), contains('🪦'));
    });

    test('no duplicates, although the package set contains some', () {
      // 🧵 stands in the package three times — the hits may still show it only
      // once.
      final matches = findEmoji('faden', emojiSet()).map((e) => e.emoji).toList();
      expect(matches.toSet().length, matches.length);
    });

    test('searches the current set, not a memorised one', () {
      // The reason we do not use `EmojiPickerUtils.searchEmoji`: its singleton
      // memorises the first set forever. Here a skin-tone change has to come
      // through at once.
      final ohne = findEmoji('Daumen', emojiSet());
      final mit = findEmoji('Daumen', applySkinTones(emojiSet(), SkinTone.dark));
      expect(ohne.map((e) => e.emoji), contains('👍'));
      expect(mit.map((e) => e.emoji), contains('👍🏿'));
      expect(mit.map((e) => e.emoji), isNot(contains('👍')));
    });
  });

  group('Hautton', () {
    test('tints only what knows skin tones — and does it the way the package does', () {
      final basis = supplementEmojiSet(getDefaultEmojiLocale(_de), _de);
      final gefaerbt = applySkinTones(basis, SkinTone.medium);
      final werkzeug = EmojiPickerUtils();

      var checked = 0;
      for (var k = 0; k < basis.length; k++) {
        for (var i = 0; i < basis[k].emoji.length; i++) {
          final before = basis[k].emoji[i];
          final after = gefaerbt[k].emoji[i];
          if (before.hasSkinTone) {
            // Has to match character for character what the long press produces
            // — otherwise the same reaction could no longer be taken back.
            expect(after.emoji,
                werkzeug.applySkinTone(before, SkinTone.medium).emoji);
            checked++;
          } else {
            expect(after.emoji, before.emoji);
          }
        }
      }
      expect(checked, greaterThan(100),
          reason: 'otherwise the test checks nothing at all');
    });

    test('without a skin tone the set stays untouched', () {
      final basis = supplementEmojiSet(getDefaultEmojiLocale(_de), _de);
      expect(identical(applySkinTones(basis, ''), basis), isTrue);
    });

    test('👍 comes in the chosen tone', () {
      final gefaerbt = applySkinTones(
          supplementEmojiSet(getDefaultEmojiLocale(_de), _de), SkinTone.dark);
      expect(_allCharacters(gefaerbt), contains('👍🏿'));
    });
  });

  group('SkinToneController', () {
    test('starts without a skin tone', () async {
      final c = SkinToneController(_FakeSecureStorage(null));
      await Future<void>.delayed(Duration.zero);
      expect(c.state, '');
    });

    test('loads a stored tone', () async {
      final c = SkinToneController(_FakeSecureStorage(SkinTone.medium));
      await Future<void>.delayed(Duration.zero);
      expect(c.state, SkinTone.medium);
    });

    test('discards an unknown stored value', () async {
      // Would otherwise be appended as a character to EVERY emoji and produce
      // nothing but broken reactions.
      final c = SkinToneController(_FakeSecureStorage('🦄'));
      await Future<void>.delayed(Duration.zero);
      expect(c.state, '');
    });

    test('setTone accepts only known tones', () async {
      final c = SkinToneController(_FakeSecureStorage(null));
      await c.setTone(SkinTone.light);
      expect(c.state, SkinTone.light);
      await c.setTone('unsinn');
      expect(c.state, '');
    });
  });
}
