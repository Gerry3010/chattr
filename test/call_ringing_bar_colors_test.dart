// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The bar of a minimized ringing call takes the theme's accent (Gerry,
// 2026-10-24: in Forest the ochre). Two things must hold in every theme: it
// never looks like the green bar of a running call, and its text stays
// readable across the whole pulse.

import 'dart:async';

import 'package:chattr/core/theme/app_theme.dart';
import 'package:chattr/screens/call/call_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

double _contrast(Color fg, Color bg) {
  final a = fg.computeLuminance();
  final b = bg.computeLuminance();
  final (light, dark) = a > b ? (a, b) : (b, a);
  return (light + 0.05) / (dark + 0.05);
}

final List<(String, ColorScheme)> _schemes = [];

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    GoogleFonts.config.allowRuntimeFetching = false;
    runZonedGuarded(() {
      for (final theme in AppTheme.values) {
        final config = theme.config;
        _schemes.add(('${theme.name}/light', config.light.colorScheme));
        _schemes.add(('${theme.name}/dark', config.dark.colorScheme));
      }
    }, (_, _) {});
  });

  test('Forest: die Leiste ist der Ockerton der Akzentfarbe', () {
    final forest = AppTheme.forest.config.dark.colorScheme;
    expect(ringingBarColors(forest).background, const Color(0xFFE8B06A));
  });

  test('in keinem Theme grün wie ein laufendes Gespräch', () {
    for (final (name, scheme) in _schemes) {
      final hsv = HSVColor.fromColor(ringingBarColors(scheme).background);
      final greenish = hsv.saturation > 0.25 && hsv.hue >= 75 && hsv.hue <= 165;
      expect(greenish, isFalse, reason: '$name: ${hsv.hue.round()}°');
    }
  });

  test('der Text bleibt über den ganzen Puls lesbar', () {
    for (final (name, scheme) in _schemes) {
      final colors = ringingBarColors(scheme);
      for (final bg in [colors.background, pulseFarEnd(colors)]) {
        expect(_contrast(colors.foreground, bg), greaterThanOrEqualTo(4.5),
            reason: name);
      }
    }
  });
}
