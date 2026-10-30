// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Die Verträglichkeitsprüfung misst die Breite des gesetzten Emoji gegen zwei
// Bezugsgrößen und lässt weg, was als Kästchen oder als zerfallene Folge
// herauskommt. Die Zahlen hier sind KEINE Erfindung: 1,00× / 0,36× / 2,00×
// sind am API-36-Emulator gemessen (2026-09-14, alle 43 jungen Emoji, ohne
// Graubereich). Die Tests halten die Einstufung an genau diesen Werten fest —
// und vor allem die Richtung, in die ein Zweifel fällt: zeigen, nicht
// verstecken.

import 'package:chattr/features/reactions/chattr_emoji_set.dart';
import 'package:chattr/features/reactions/emoji_compatibility.dart';
import 'package:chattr/features/reactions/emoji_supplement.g.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:emoji_picker_flutter/locales/default_emoji_set_locale.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _de = Locale('de', 'DE');

/// Am Gerät gemessen, bezogen auf ein gezeichnetes Emoji.
const double _gezeichnet = 39.8; // 1,00×
const double _kaestchen = 14.2; // 0,36×
const double _zerfallen = 79.6; // 2,00× — 🧑‍🩰 als 🧑 + 🩰

/// Ein Messgerät, das jedem Emoji eine feste Breite zuweist.
double Function(String) _lineal(Map<String, double> besonders) => (s) {
      if (s == '\u{10FFFF}') return _kaestchen; // Bezug: notdef
      if (s == '\u{1F600}') return _gezeichnet; // Bezug: 😀
      return besonders[s] ?? _gezeichnet;
    };

void main() {
  setUp(EmojiCompatibility.resetForTest);
  tearDown(EmojiCompatibility.resetForTest);

  group('Messung', () {
    test('zeichnet das Gerät alles, wird nichts versteckt', () {
      EmojiCompatibility.measure = _lineal(const {});
      EmojiCompatibility.probe(youngEmoji);
      expect(EmojiCompatibility.unsupported, isEmpty);
      expect(EmojiCompatibility.generation, 0);
    });

    test('ein Kästchen wird erkannt (0,36×)', () {
      EmojiCompatibility.measure =
          _lineal(const {'\u{1FAE9}': _kaestchen}); // 🫩
      EmojiCompatibility.probe(youngEmoji);
      expect(EmojiCompatibility.unsupported, {'\u{1FAE9}'});
    });

    test('eine zerfallene Folge wird erkannt (2,00×) — das kann nur die Breite',
        () {
      // 🧑‍🩰 ist am Emulator KEIN Kästchen: die Schrift zeichnet 🧑 und 🩰
      // nebeneinander. Ein Pixelvergleich gegen das Kästchen sieht das nicht,
      // die Breite schon.
      EmojiCompatibility.measure =
          _lineal(const {'\u{1F9D1}\u{200D}\u{1FA70}': _zerfallen});
      EmojiCompatibility.probe(youngEmoji);
      expect(EmojiCompatibility.unsupported, {'\u{1F9D1}\u{200D}\u{1FA70}'});
    });

    test('gar nichts gezeichnet (Breite 0) zählt auch als fehlend', () {
      EmojiCompatibility.measure = _lineal(const {'\u{1FAE9}': 0});
      EmojiCompatibility.probe(youngEmoji);
      expect(EmojiCompatibility.unsupported, {'\u{1FAE9}'});
    });

    test('FALLE: taugt das Lineal nichts, wird NICHTS versteckt', () {
      // Eine Schrift mit einer einzigen Laufweite (Testumgebungen haben so
      // eine) liefert für Kästchen und Emoji dieselbe Zahl. Dann ist die
      // Messung bedeutungslos — und bedeutungslos heißt zeigen.
      EmojiCompatibility.measure = (_) => 20;
      EmojiCompatibility.probe(youngEmoji);
      expect(EmojiCompatibility.unsupported, isEmpty);
    });

    test('FALLE: misst gar nichts (Breite 0 überall) → nichts versteckt', () {
      EmojiCompatibility.measure = (_) => 0;
      EmojiCompatibility.probe(youngEmoji);
      expect(EmojiCompatibility.unsupported, isEmpty);
    });

    test('gemessen wird einmal pro Lauf, auch bei mehreren Aufrufen', () async {
      var aufrufe = 0;
      final lineal = _lineal(const {});
      EmojiCompatibility.measure = (s) {
        aufrufe++;
        return lineal(s);
      };
      await Future.wait([
        EmojiCompatibility.warmUp(),
        EmojiCompatibility.warmUp(),
        EmojiCompatibility.warmUp(),
      ]);
      // 43 Kandidaten + 2 Bezugsgrößen, genau einmal.
      expect(aufrufe, youngEmoji.length + 2);
    });

    test('gefragt wird nur nach den jungen, nicht nach dem ganzen Satz', () {
      final gefragt = <String>[];
      final lineal = _lineal(const {});
      EmojiCompatibility.measure = (s) {
        gefragt.add(s);
        return lineal(s);
      };
      EmojiCompatibility.probe(youngEmoji);
      expect(gefragt.length, lessThan(supplementEmoji.length));
      expect(youngEmoji.length, lessThan(supplementEmoji.length));
    });
  });

  group('Satz', () {
    List<String> allEmoji(List<CategoryEmoji> set) =>
        [for (final c in set) ...c.emoji.map((e) => e.emoji)];

    test('ein unzeichenbares Emoji fehlt im Satz, der Rest bleibt', () {
      const opfer = '\u{1FAE9}'; // 🫩
      final ohne = allEmoji(supplementEmojiSet(
        getDefaultEmojiLocale(_de),
        _de,
        unsupported: const {opfer},
      ));
      final mit = allEmoji(supplementEmojiSet(getDefaultEmojiLocale(_de), _de));
      expect(mit, contains(opfer));
      expect(ohne, isNot(contains(opfer)));
      expect(ohne.length, mit.length - 1);
    });

    test('der Anker selbst bleibt stehen, nur der Nachtrag fällt weg', () {
      final eintrag =
          supplementEmoji.firstWhere((e) => e.character == '\u{1FAE9}');
      final ohne = allEmoji(supplementEmojiSet(
        getDefaultEmojiLocale(_de),
        _de,
        unsupported: {eintrag.character},
      ));
      expect(ohne, contains(eintrag.anchor.replaceAll('️', '')));
    });

    test('die Antwort verwirft den gemerkten Satz (Generation im Schlüssel)',
        () {
      final vorher = chattrEmojiSet(_de);
      expect(allEmoji(vorher), contains('\u{1FAE9}'));
      EmojiCompatibility.setUnsupportedForTest(const {'\u{1FAE9}'});
      final nachher = chattrEmojiSet(_de);
      expect(allEmoji(nachher), isNot(contains('\u{1FAE9}')));
    });
  });
}
