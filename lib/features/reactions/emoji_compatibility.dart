// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'emoji_supplement.g.dart';

/// Finds out once per app run which of the YOUNGEST emoji this device cannot
/// draw, so the picker does not offer empty boxes.
///
/// The set carries the whole Unicode catalogue since 2026-09-14, and the picker
/// runs with `checkPlatformCompatibility: false` — that flag makes the package
/// render every one of the ~1925 emoji as a probe **each time the sheet opens**,
/// and the opening visibly stutters. Off, an emoji without a glyph shows as a
/// hollow rectangle instead of being left out.
///
/// So the question is asked here instead, and asked about [youngEmoji] — the 43
/// entries from E15.1 on — rather than all of them. Everything older has been
/// drawn for years; asking about it would be spent breath.
///
/// ## Why not the package's own check
///
/// The package asks Android's `PaintCompat.hasGlyph` over a method channel.
/// Measured on an API-36 emulator (2026-09-14) that answer is **worthless
/// here**: it reported all 43 as supported while seven of them visibly rendered
/// as boxes. Android answers for the font stack *it* would use; Flutter draws
/// through Skia and does not necessarily reach the same fonts. An agreement
/// about a different renderer is not an answer about ours.
///
/// ## What is measured instead
///
/// The width of the laid-out glyph, against two references measured the same
/// way: a noncharacter that no font can have ([_tofuProbe]) and an emoji every
/// emoji font has ([_drawnProbe]). On that emulator the three outcomes
/// separated without any grey zone — drawn emoji **1.00×**, boxes **0.36×**,
/// and 🧑‍🩰, whose ZWJ sequence the font does not know and therefore drew as its
/// two parts side by side, **2.00×**.
///
/// That last case is why width beats a pixel comparison, which was measured too
/// and agreed on the boxes: a sequence that falls apart is not a box, it is a
/// *wrong picture* — 🧑 next to 🩰 instead of a dancer. It is only visible as
/// width, and it is exactly the breakage that started this ([emojiUpscaledSpans]
/// tore joined emoji apart the same way until p27).
///
/// ## Failure means showing, not hiding
///
/// The measurement checks ITSELF first: if the box and the known-good emoji
/// come out the same width, the ruler is broken (a test environment with a
/// single-metric font, say) and nothing is hidden. Every uncertainty resolves
/// towards showing — a probe that cannot run is a reason to lose the filter,
/// never the emoji.
class EmojiCompatibility {
  EmojiCompatibility._();

  /// A noncharacter — permanently unassigned, so no font may have a glyph.
  static const String _tofuProbe = '\u{10FFFF}';

  /// 😀 — in every emoji font since 2010.
  static const String _drawnProbe = '\u{1F600}';

  /// Big enough that rounding does not blur the three cases into each other.
  static const double _probeFontSize = 32;

  static Set<String> _unsupported = const {};
  static int _generation = 0;
  static Future<void>? _running;

  /// The young emoji this device cannot draw. Empty until [warmUp] has run.
  static Set<String> get unsupported => _unsupported;

  /// Counts up once an answer has landed.
  ///
  /// The built set is memoised per language and skin tone, so without this the
  /// first set built would be kept — boxes included. It belongs in that cache
  /// key so a set built before the answer is superseded rather than frozen.
  static int get generation => _generation;

  /// How a string is measured. Overridable so a test can feed measurements
  /// instead of depending on whatever font the test environment loads.
  @visibleForTesting
  static double Function(String) measure = _width;

  static double _width(String s) {
    final painter = TextPainter(
      text: TextSpan(
        text: s,
        style: const TextStyle(fontSize: _probeFontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// Measures once per app run. Repeat calls join the first.
  ///
  /// Kicked off at startup ([AppInit]) and deliberately not awaited. Whoever is
  /// faster than the measurement sees the boxes once, and the next build of the
  /// set has them gone.
  static Future<void> warmUp({List<String> candidates = youngEmoji}) =>
      _running ??= Future<void>.sync(() => probe(candidates));

  /// The measurement itself — synchronous, no rasterising, no channel.
  @visibleForTesting
  static void probe(List<String> candidates) {
    if (candidates.isEmpty) return;
    final tofu = measure(_tofuProbe);
    final drawn = measure(_drawnProbe);
    // Check the ruler before reading anything off it: if a box and a real
    // emoji measure the same, this environment cannot tell them apart.
    if (drawn <= 0 || (drawn - tofu).abs() < drawn * 0.1) return;

    final missing = <String>{
      for (final emoji in candidates)
        if (_isBroken(measure(emoji), tofu: tofu, drawn: drawn)) emoji,
    };
    if (missing.isEmpty) return;
    _unsupported = missing;
    _generation++;
  }

  /// Three ways a young emoji comes out wrong, all visible in one number.
  static bool _isBroken(double width, {required double tofu, required double drawn}) =>
      // Nothing at all — some stacks draw an unknown glyph as empty.
      width <= drawn * 0.1 ||
      // A hollow box: the width of the notdef glyph (measured 0.36×).
      (width - tofu).abs() <= drawn * 0.05 ||
      // Wider than one emoji can be: the joined sequence fell into its parts
      // (measured 2.00× for 🧑‍🩰 on a font that does not know it).
      width >= drawn * 1.5;

  /// Puts the probe back to its untouched state. Tests only.
  @visibleForTesting
  static void resetForTest() {
    _unsupported = const {};
    _generation = 0;
    _running = null;
    measure = _width;
  }

  /// Sets an answer without measuring. Tests only.
  @visibleForTesting
  static void setUnsupportedForTest(Set<String> value) {
    _unsupported = value;
    _generation++;
    _running = Future<void>.value();
  }
}
