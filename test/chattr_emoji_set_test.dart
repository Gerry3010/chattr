// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The package's emoji set has holes — 🪦 and roughly 285 others are missing —
// and we add them via anchors: "this emoji belongs behind that one". The
// dangerous case is a package update that renames or removes an anchor: then
// the addition would no longer find its place and the emoji would disappear
// SILENTLY. That is exactly what the first test checks.

import 'package:chattr/features/reactions/chattr_emoji_set.dart';
import 'package:chattr/features/reactions/emoji_search.dart';
import 'package:chattr/features/reactions/reaction_usage_rules.dart';
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

  group('Suche: Wörter in Wortgruppen', () {
    // Ein Stichwort darf eine Wortgruppe sein. Das Paket vergleicht gegen die
    // GANZE Gruppe, damit war nur ihr erstes Wort je auffindbar — ein Drittel
    // der Nachträge war so nur halb erreichbar. Gemeldet von Gerry (2026-09-14):
    // „man findet diese emojis noch nicht in der suche".
    List<String> treffer(String eingabe, {Locale locale = _de}) => [
          for (final e in findEmoji(
              eingabe, supplementEmojiSet(getDefaultEmojiLocale(locale), locale)))
            e.emoji,
        ];

    test('ein Wort MITTEN in der Wortgruppe findet (Nebel → Gesicht in Wolken)',
        () {
      expect(treffer('nebel'), contains('\u{1F636}\u{200D}\u{1F32B}\u{FE0F}'));
    });

    test('Baum findet den kahlen Baum', () {
      expect(treffer('baum'), contains('\u{1FABE}'));
    });

    test('Punkt findet den grünen Punkt — nicht nur „grüner"', () {
      expect(treffer('punkt'), contains('\u{1F7E2}'));
      expect(treffer('grün'), contains('\u{1F7E2}'));
    });

    test('der Bindestrich trennt auch (Utan → Orang-Utan)', () {
      expect(treffer('utan'), contains('\u{1F9A7}'));
      expect(treffer('orang'), contains('\u{1F9A7}'));
    });

    test('alle Wörter müssen weiterhin passen', () {
      expect(treffer('kahler baum'), contains('\u{1FABE}'));
      expect(treffer('kahler auster'), isEmpty);
    });

    test('die jüngsten sind auf Deutsch auffindbar (CLDR-Attribut-Falle)', () {
      // Diese Zeilen tragen in CLDR ein `draft`-Attribut; das alte Muster im
      // Generator übersah sie stumm und der Eintrag fiel auf den englischen
      // Unicode-Namen zurück.
      expect(treffer('posaune'), contains('\u{1FA8A}'));
      expect(treffer('schatztruhe'), contains('\u{1FA8E}'));
      expect(treffer('erdrutsch'), contains('\u{1F6D8}'));
      expect(treffer('orca'), contains('\u{1FACD}'));
      expect(treffer('fingerabdruck'), contains('\u{1FAC6}'));
      expect(treffer('augenringe'), contains('\u{1FAE9}'));
    });

    test('kein Nachtrag hat nur ein einziges Stichwort', () {
      final duenn = [
        for (final e in supplementEmoji)
          if (!e.de.contains(' | ')) e.character,
      ];
      expect(duenn, isEmpty,
          reason: 'CLDR liefert für jeden eine Stichwortliste — steht hier nur '
              'ein Name, hat der Generator sie wieder verschluckt');
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

  group('tintEmoji', () {
    const daumen = '\u{1F44D}';
    const mittel = '\u{1F3FD}';

    test('ohne Hautton bleibt alles, wie es ist', () {
      expect(tintEmoji(daumen, '', locale: _de), daumen);
    });

    test('faerbt genau so wie der Picker', () {
      // Nicht "sieht richtig aus", sondern zeichengleich mit dem Weg ueber den
      // Emoji-Satz: Reaktionen werden ueber ihren Text verglichen, und ein
      // anders zusammengesetztes 👍🏽 liesse sich nicht mehr zuruecknehmen.
      final ausDemSatz = chattrEmojiSet(_de, skinTone: mittel)
          .expand((c) => c.emoji)
          .firstWhere((e) => e.emoji.startsWith(daumen))
          .emoji;
      expect(tintEmoji(daumen, mittel, locale: _de), ausDemSatz);
    });

    test('ein Emoji ohne Hauttoene bleibt unangetastet', () {
      // Ein angehaengter Modifikator scheitert hier nicht, er malt ein zweites
      // Zeichen daneben — deshalb wird nachgeschlagen statt angenommen.
      for (final e in ['\u{1F602}', '\u{1F621}', '\u{2764}']) {
        expect(tintEmoji(e, mittel, locale: _de), e);
      }
    });

    test('ein unbekanntes Zeichen bleibt unangetastet', () {
      expect(tintEmoji('nix', mittel, locale: _de), 'nix');
    });

    test('gefaerbt bleibt es derselbe Zaehler', () {
      // Das Band zwischen den beiden Haelften: Die Reihe speichert die blanke
      // Form, zeigt die gefaerbte — und gezaehlt wird beides gemeinsam.
      final gefaerbt = tintEmoji(daumen, mittel, locale: _de);
      expect(gefaerbt, isNot(daumen));
      expect(reactionCountKey(gefaerbt), daumen);
    });

    test('jedes Emoji der Startreihe uebersteht das Faerben', () {
      for (final e in quickReactionEmojis) {
        final t = tintEmoji(e, mittel, locale: _de);
        expect(reactionCountKey(t), e,
            reason: 'sonst faende die Reihe ihren eigenen Zaehler nicht mehr');
      }
    });
  });
}
