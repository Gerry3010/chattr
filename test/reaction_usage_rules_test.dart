// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The quick-reaction row is muscle memory: whoever reaches for the second slot
// without looking has to find the same emoji there. So the property worth
// pinning down is not "sorted by frequency" — that part is trivial — but the
// RELUCTANCE: a single tap must move nothing, a tie must move nothing, and a
// newcomer must not appear at the front however popular it gets.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/reactions/reaction_usage_rules.dart';

const _herz = '\u{2764}';
const _lachen = '\u{1F602}';
const _daumen = '\u{1F44D}';
const _beten = '\u{1F64F}';
const _daumenTon = '\u{1F44D}\u{1F3FD}'; // 👍🏽

final _start = DateTime.utc(2026, 9, 24);

/// Uses [emoji] [mal] times in a row, without any time passing.
ReactionUsage _benutze(ReactionUsage u, String emoji, int mal) {
  for (var i = 0; i < mal; i++) {
    u = noteReaction(u, emoji, _start);
  }
  return u;
}

void main() {
  group('Startzustand', () {
    test('die Reihe ist die gewohnte, in der gewohnten Reihenfolge', () {
      final u = ReactionUsage.seed(quickReactionEmojis, _start);
      expect(u.order, quickReactionEmojis);
      expect(u.order.length, reactionRowLength);
    });

    test('die Gewichte tragen genau diese Reihenfolge', () {
      // Sonst sortierte sich die Reihe beim allerersten Tippen um, obwohl
      // niemand etwas getan hat, das eine Umsortierung rechtfertigt.
      final u = ReactionUsage.seed(quickReactionEmojis, _start);
      expect(settleOrder(u.order, u.counts), quickReactionEmojis);
    });
  });

  group('Traegheit', () {
    test('ein einzelner Tap sortiert nicht um', () {
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = noteReaction(u, _daumen, _start);
      expect(u.order, quickReactionEmojis);
    });

    test('Gleichstand tauscht nicht', () {
      // Direkt an der Regel gemessen, nicht ueber einen Umweg: zwei benachbarte
      // Emoji mit demselben Gewicht bleiben, wie sie stehen.
      final reihe = settleOrder(
        quickReactionEmojis,
        {for (final e in quickReactionEmojis) e: 10},
      );
      expect(reihe, quickReactionEmojis);
    });

    test('ein knapper Vorsprung tauscht nicht', () {
      final reihe = settleOrder(quickReactionEmojis, {
        for (final e in quickReactionEmojis) e: 10.0,
        _daumen: 14, // mehr als 10, aber unter dem 1,5-fachen
      });
      expect(reihe, quickReactionEmojis);
    });

    test('der deutliche Vorsprung tauscht', () {
      final reihe = settleOrder(quickReactionEmojis, {
        for (final e in quickReactionEmojis) e: 10.0,
        _daumen: 15, // genau das 1,5-fache
      });
      expect(reihe.first, _daumen);
      // ❤ rueckt EINEN Platz nach hinten, es faellt nicht ans Ende.
      expect(reihe[1], _herz);
      expect(reihe.length, reactionRowLength);
    });

    test('die Startreihe haelt neun Benutzungen aus', () {
      // Mit engeren Startgewichten kippte die Spitze schon nach neun Taps.
      // Das ist nicht „die letzten Wochen", das ist dieser Nachmittag.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _daumen, 9);
      expect(u.order.first, _herz);
    });

    test('nach genug Benutzung kippt sie dann doch', () {
      // 👍 startet bei 2 und muss ❤ (12) um das 1,5-fache schlagen: 18.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _daumen, 16);
      expect(u.weightOf(_daumen), 18);
      expect(u.order.first, _daumen);
      expect(u.order[1], _herz);
    });

    test('die uebrige Reihenfolge bleibt, wo sie war', () {
      final vorher = ReactionUsage.seed(quickReactionEmojis, _start);
      final nachher = _benutze(vorher, _daumen, 16);
      final ohneDaumen = nachher.order.where((e) => e != _daumen).toList();
      expect(ohneDaumen, quickReactionEmojis.where((e) => e != _daumen));
    });
  });

  group('Hereinkommen', () {
    test('ein neues Emoji betritt die Reihe ganz hinten', () {
      // 🙏 kommt aus dem Picker. Es darf die Reihe nicht von vorne aufrollen,
      // sondern muss sich von hinten hocharbeiten wie jedes andere auch.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _beten, 3); // 3 gegen 👍 auf Platz 6 mit Gewicht 2
      expect(u.order.last, _beten);
      expect(u.order.first, _herz);
      expect(u.order.length, reactionRowLength);
    });

    test('es steigt nur Platz um Platz, nie in einem Satz nach vorne', () {
      // Selbst mit weit mehr Gewicht als alles andere klettert es genau so
      // weit, wie die 1,5-fach-Regel es an jedem Nachbarn vorbeilaesst.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _beten, 9); // 9: schlaegt 2, 4 und 6, aber nicht 8
      expect(u.order, [_herz, _lachen, '\u{1F632}', _beten, '\u{1F625}', '\u{1F621}']);
    });

    test('drei Reaktionen über einen Tag verteilt reichen auch', () {
      // 2026-10-22: Die Taps altern ab dem Moment, in dem sie passieren. Drei
      // Taps im Abstand von Stunden ergaben 2,99 statt 3, und 🙂 kam erst nach
      // der vierten Reaktion in die Reihe.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      for (final stunde in [0, 9, 20]) {
        u = noteReaction(u, _beten, _start.add(Duration(hours: stunde)));
      }
      expect(u.order.last, _beten);
    });

    test('zwei Reaktionen reichen auch über Tage verteilt nicht', () {
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = noteReaction(u, _beten, _start);
      u = noteReaction(u, _beten, _start.add(const Duration(days: 1)));
      expect(u.order, quickReactionEmojis);
    });

    test('zu wenig Benutzung kommt gar nicht herein', () {
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _beten, 2); // unter der absoluten Untergrenze von 3
      expect(u.order, quickReactionEmojis);
    });

    test('der letzte Platz flackert nicht zwischen zweien hin und her', () {
      // Das Verdraengte behaelt sein Gewicht. Zurueck kommt es nur, wenn es den
      // Neuling seinerseits deutlich schlaegt — sonst tauschten die beiden bei
      // jeder Benutzung die Plaetze.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _beten, 3);
      expect(u.order.last, _beten);
      u = _benutze(u, _daumen, 1); // 👍 auf 3, 🙏 auf 3 — Gleichstand
      expect(u.order.last, _beten);
    });
  });

  group('Alterung', () {
    test('nach 30 Tagen wiegt alles halb so viel', () {
      final u = ReactionUsage.seed(quickReactionEmojis, _start);
      final spaeter = ageCounts(u, _start.add(const Duration(days: 30)));
      expect(spaeter.weightOf(_herz), closeTo(6, 0.001));
      expect(spaeter.weightOf(_lachen), closeTo(5, 0.001));
    });

    test('die Reihe ueberlebt eine lange Pause', () {
      // Alles schrumpft gleichmaessig, also aendert reines Warten die
      // Reihenfolge nicht — und die sechs verschwinden auch nicht aus der
      // Zaehlung, wenn ihr Gewicht winzig wird.
      final u = ReactionUsage.seed(quickReactionEmojis, _start);
      final spaeter = ageCounts(u, _start.add(const Duration(days: 3650)));
      expect(spaeter.order, quickReactionEmojis);
      expect(settleOrder(spaeter.order, spaeter.counts), quickReactionEmojis);
    });

    test('eine Uhr, die zurueckspringt, hebt nichts an', () {
      final u = ReactionUsage.seed(quickReactionEmojis, _start);
      final zurueck = ageCounts(u, _start.subtract(const Duration(days: 40)));
      expect(zurueck.weightOf(_herz), 12);
    });

    test('die absolute Untergrenze bremst auch geschrumpfte Zaehler', () {
      // Nach langer Pause stehen alle Gewichte weit unter 3. Ein einzelner Tap
      // ist dann rechnerisch ein Vielfaches von allem anderen — und darf die
      // Reihe trotzdem nicht umwerfen.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      final spaet = _start.add(const Duration(days: 365));
      u = noteReaction(u, _daumen, spaet);
      expect(u.order, quickReactionEmojis);
    });
  });

  group('Hautton', () {
    test('👍 und 👍🏽 teilen sich einen Zaehler', () {
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _daumenTon, 4);
      // 2 aus dem Start + 4 — haette der Hautton einen eigenen Zaehler, stuende
      // hier 4 und dort 2, und keiner von beiden kaeme je nach vorne.
      expect(u.weightOf(_daumen), 6);
      expect(u.weightOf(_daumenTon), 6);
    });

    test('was in der Reihe steht, bleibt das blanke Zeichen', () {
      // Die Reihe wird ueber ihren Text mit den eigenen Reaktionen verglichen;
      // ein anders zusammengesetztes 👍🏽 liesse sich nicht mehr durch Antippen
      // zuruecknehmen.
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      u = _benutze(u, _daumenTon, 16);
      expect(u.order, contains(_daumen));
      expect(u.order, isNot(contains(_daumenTon)));
    });
  });

  group('Buchfuehrung', () {
    test('die Zaehlerkarte bleibt gedeckelt', () {
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      for (var i = 0; i < 200; i++) {
        u = noteReaction(u, String.fromCharCode(0x1F600 + i), _start);
      }
      expect(u.counts.length, lessThanOrEqualTo(reactionMaxTracked));
    });

    test('die Reihe selbst faellt nie aus der Zaehlung', () {
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      for (var i = 0; i < 200; i++) {
        u = noteReaction(u, String.fromCharCode(0x1F600 + i), _start);
      }
      for (final e in u.order) {
        expect(u.counts.containsKey(reactionCountKey(e)), isTrue,
            reason: 'sonst verliert ein sichtbares Emoji sein Gewicht und '
                'wird beim naechsten Tap sofort verdraengt');
      }
    });

    test('die Reihe hat immer genau sechs Plaetze', () {
      var u = ReactionUsage.seed(quickReactionEmojis, _start);
      for (var i = 0; i < 50; i++) {
        u = noteReaction(u, String.fromCharCode(0x1F600 + i % 7), _start);
        expect(u.order.length, reactionRowLength);
        expect(u.order.toSet().length, reactionRowLength,
            reason: 'ein Emoji darf nicht zweimal in der Reihe stehen');
      }
    });
  });
}
