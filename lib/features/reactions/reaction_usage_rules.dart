// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The rule behind the quick-reaction row: which six emoji it shows, and in
/// which order.
///
/// Kept as pure functions with no storage and no Flutter, next to
/// `unread_rules.dart`, for the same reason: the interesting part is the
/// *decision*, and a decision that can only be observed through a database and
/// a widget tree is one nobody checks.
library;

import 'dart:math' as math;

/// The row everyone STARTS with. These are the exact code points chatview's
/// reaction popup used before, so tapping the same emoji again toggles
/// reactions that were stored earlier.
///
/// What is actually rendered comes from `quickReactionRowProvider`: the row
/// re-orders itself by how often each emoji is used. This list is its seed, so
/// nothing looks different until one's own reactions say otherwise.
const List<String> quickReactionEmojis = [
  '\u{2764}', // ❤ heart
  '\u{1F602}', // 😂 face with tears
  '\u{1F632}', // 😲 astonished
  '\u{1F625}', // 😥 disappointed
  '\u{1F621}', // 😡 angry
  '\u{1F44D}', // 👍 thumbs up
];

/// How many emoji the row holds. The "+" button beside them is not one of them.
const int reactionRowLength = 6;

/// How much better a lower emoji has to be to overtake the one above it.
///
/// This is the whole point of the feature's calm: strict frequency order would
/// re-sort the row mid-conversation, and the row is muscle memory — whoever
/// reaches for the second slot without looking has to find the same emoji
/// there. A tie, or a narrow lead, moves nothing.
const double reactionSwapFactor = 1.5;

/// A lower emoji also needs this much absolute weight before it may overtake.
///
/// Without it the factor alone decides once [ageCounts] has made the numbers
/// small — at 0.4 against 0.2 a single tap would reshuffle the row, which is
/// exactly the twitchiness the factor exists to prevent.
const double reactionSwapFloor = 3;

/// How far below [reactionSwapFloor] the weight may sit and still count.
///
/// The floor means "three uses", but uses age from the moment they happen
/// (see [reactionHalfLifeDays]). Three taps an hour apart added up to 2.997,
/// so in real use it took FOUR reactions before a newcomer showed up at all;
/// the tests never saw it because all their taps happened at the same
/// instant (Gerry, 2026-10-22: "mehrmals mit 🙂 reagiert", nothing moved).
/// 0.1 lets three uses within about four days through, and two uses never.
const double _floorSlack = 0.1;

/// After this many days a use counts half as much.
///
/// This is how "the last few weeks" is expressed. The alternative — keeping a
/// timestamp per use and counting inside a window — stores an ever-growing list
/// to answer the same question, and answers it with a hard edge: an emoji drops
/// out of the ranking the moment its last use turns 29 days old.
const double reactionHalfLifeDays = 30;

/// Upper bound on the counter map, so a curious afternoon in the picker does
/// not leave a few hundred entries behind forever. The row itself is always
/// kept, whatever its weight.
const int reactionMaxTracked = 40;

/// Weights below this are indistinguishable from "never used" and are dropped —
/// unless they are currently ON the row, which is what keeps a long pause from
/// emptying it.
const double _forgetBelow = 0.05;

/// Spacing of the starting weights (see [ReactionUsage.seed]). No adjacent
/// pair is within [reactionSwapFactor] of the other, so the seed never
/// re-sorts itself before anybody has reacted at all.
const double _seedStep = 2;

/// The five skin-tone modifiers. They only ever appear as modifiers, so
/// removing them from a string is unambiguous.
const List<int> _skinToneModifiers = [
  0x1F3FB,
  0x1F3FC,
  0x1F3FD,
  0x1F3FE,
  0x1F3FF,
];

/// The key an emoji is counted under: its skin-tone-free base form.
///
/// 👍 and 👍🏽 are the same preference and must not keep two counters — the
/// package's own history does the same (`removeSkinTone` before storing).
/// This does NOT change what the row sends; see [ReactionUsage.order].
String reactionCountKey(String emoji) {
  if (!emoji.runes.any(_skinToneModifiers.contains)) return emoji;
  return String.fromCharCodes(
    emoji.runes.where((r) => !_skinToneModifiers.contains(r)),
  );
}

/// The row plus the weights behind it.
///
/// [order] is what the sheet renders, and it is stored rather than derived:
/// a derived order would re-sort itself the moment two weights crossed, and
/// "calm" is precisely the property that cannot be derived from the weights
/// alone. The weights only ever *propose* a move; [settleOrder] decides.
class ReactionUsage {
  /// Exactly [reactionRowLength] emoji, in the order they are shown.
  final List<String> order;

  /// Weight per skin-tone-free emoji (see [reactionCountKey]).
  final Map<String, double> counts;

  /// When [counts] was last aged. Ageing is lazy — it happens on read and on
  /// use, so nothing has to run while the app is closed.
  final DateTime agedAt;

  const ReactionUsage({
    required this.order,
    required this.counts,
    required this.agedAt,
  });

  /// The starting state: the row as it has always been, and weights that put it
  /// in exactly that order. Gerry's wording — "the current selection is simply
  /// defined as last used, so everyone starts with this order".
  ///
  /// **The size of these numbers is the row's patience.** They decide nothing
  /// about the order — any descending series produces the same row — but they
  /// decide how much evidence it takes to change it. Spaced by
  /// [_seedStep], the top seat needs 18 uses before anything overtakes it and
  /// the bottom one needs 3; a tighter series had the row flipping after nine
  /// taps, which is not "the last few weeks", it is "this afternoon". Against
  /// the weights that regular use settles at (a single reaction a day levels
  /// out around 40, given [reactionHalfLifeDays]) these are small on purpose —
  /// they shape the first days, not the steady state.
  factory ReactionUsage.seed(List<String> row, DateTime now) {
    final counts = <String, double>{};
    for (var i = 0; i < row.length; i++) {
      counts[reactionCountKey(row[i])] = (row.length - i) * _seedStep;
    }
    return ReactionUsage(
      order: List<String>.unmodifiable(row),
      counts: counts,
      agedAt: now,
    );
  }

  double weightOf(String emoji) => counts[reactionCountKey(emoji)] ?? 0;
}

/// Lets every weight decay towards zero by half per [reactionHalfLifeDays].
///
/// Going backwards in time (a clock correction, a device that travelled) must
/// not *raise* anything, so a negative span is treated as no time at all.
ReactionUsage ageCounts(ReactionUsage usage, DateTime now) {
  final tage = now.difference(usage.agedAt).inMilliseconds /
      Duration.millisecondsPerDay;
  if (tage <= 0) return usage;

  final faktor = math.pow(0.5, tage / reactionHalfLifeDays).toDouble();
  final aufDerReihe = usage.order.map(reactionCountKey).toSet();
  final neu = <String, double>{};
  for (final e in usage.counts.entries) {
    final wert = e.value * faktor;
    if (wert < _forgetBelow && !aufDerReihe.contains(e.key)) continue;
    neu[e.key] = wert;
  }
  return ReactionUsage(order: usage.order, counts: neu, agedAt: now);
}

/// One use of [emoji] — called only when a reaction was ADDED, never when one
/// was taken back.
ReactionUsage noteReaction(
  ReactionUsage usage,
  String emoji,
  DateTime now,
) {
  final gealtert = ageCounts(usage, now);
  final key = reactionCountKey(emoji);
  final counts = Map<String, double>.from(gealtert.counts);
  counts[key] = (counts[key] ?? 0) + 1;

  return ReactionUsage(
    order: settleOrder(gealtert.order, counts),
    counts: _capped(counts, gealtert.order),
    agedAt: now,
  );
}

/// Moves the row towards the weights — but only where the lead is clear.
///
/// Two rules, both using the same threshold:
///
/// * **Overtaking inside the row.** A lower emoji swaps with the one above it
///   when it beats it by [reactionSwapFactor] *and* carries at least
///   [reactionSwapFloor]. Repeated until nothing moves, so a genuinely dominant
///   emoji reaches the front in one go instead of creeping up one slot per tap.
/// * **Getting in.** An emoji from outside takes the LAST slot, by the same
///   measure against the emoji sitting there — and only that slot. It may then
///   climb by the first rule like everybody else. Nothing is ever inserted at
///   the front, however popular: the top of the row is the part that is reached
///   for blindly.
///
/// Each swap strictly lifts a heavier emoji above a lighter one, so the passes
/// terminate; the bound below is a belt-and-braces guard, not a live limit.
List<String> settleOrder(List<String> order, Map<String, double> counts) {
  double gewicht(String e) => counts[reactionCountKey(e)] ?? 0;
  bool schlaegt(double unten, double oben) =>
      unten >= reactionSwapFloor - _floorSlack &&
      unten >= oben * reactionSwapFactor;

  final reihe = List<String>.from(order);

  // Getting in: the strongest outsider, measured against the last slot.
  if (reihe.isNotEmpty) {
    final drin = reihe.map(reactionCountKey).toSet();
    String? bester;
    var bestesGewicht = 0.0;
    for (final e in counts.entries) {
      if (drin.contains(e.key)) continue;
      if (e.value > bestesGewicht) {
        bester = e.key;
        bestesGewicht = e.value;
      }
    }
    if (bester != null && schlaegt(bestesGewicht, gewicht(reihe.last))) {
      reihe[reihe.length - 1] = bester;
    }
  }

  // Overtaking: bubble the clear leads upwards.
  for (var runde = 0; runde < reihe.length; runde++) {
    var bewegt = false;
    for (var i = reihe.length - 1; i > 0; i--) {
      if (schlaegt(gewicht(reihe[i]), gewicht(reihe[i - 1]))) {
        final h = reihe[i - 1];
        reihe[i - 1] = reihe[i];
        reihe[i] = h;
        bewegt = true;
      }
    }
    if (!bewegt) break;
  }

  return List<String>.unmodifiable(reihe);
}

/// Keeps [reactionMaxTracked] entries — the row always, then the heaviest.
Map<String, double> _capped(Map<String, double> counts, List<String> order) {
  if (counts.length <= reactionMaxTracked) return counts;
  final behalten = order.map(reactionCountKey).toSet();
  final rest = counts.entries
      .where((e) => !behalten.contains(e.key))
      .toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final platz = math.max(0, reactionMaxTracked - behalten.length);
  for (final e in rest.take(platz)) {
    behalten.add(e.key);
  }
  return {
    for (final e in counts.entries)
      if (behalten.contains(e.key)) e.key: e.value,
  };
}
