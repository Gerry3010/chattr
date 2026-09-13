// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The invitation card's "open" button was unreadable in the Forest theme
// (Gerry, 2026-08-09): the card paints itself `primaryContainer` (beige) while
// the button took Material's default foreground `primary` — Forest's gold
// accent. Gold on beige is roughly 1.5:1. The title had the same shape of bug
// from the other direction: it inherited the chat bubble's white.
//
// The palette was never at fault, so tuning Forest would have been the wrong
// fix. What was wrong is that the card mixed colours from TWO surfaces. These
// tests pin the rule instead: every foreground on the card comes from the `on…`
// role belonging to the card's OWN background — which is why the fix holds for
// all fourteen themes rather than the one that happened to break.
//
// flutter test test/invite_card_contrast_test.dart

import 'dart:async';

import 'package:chattr/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// WCAG 2.1 relative-contrast ratio, 1.0 (invisible) … 21.0 (black on white).
double _contrast(Color fg, Color bg) {
  final a = fg.computeLuminance();
  final b = bg.computeLuminance();
  final (light, dark) = a > b ? (a, b) : (b, a);
  return (light + 0.05) / (dark + 0.05);
}

/// Every scheme the app can actually render — both brightnesses of all themes.
///
/// Built once, inside a guarded zone: Matrix and Forest pull their text theme
/// from Google Fonts, which cannot download a face in a test run and reports
/// the failure through a Future nobody awaits. The colours we care about are
/// already on the ThemeData by then, so the error is genuinely irrelevant here
/// — but left unguarded it fails whichever test happens to build first.
final List<(String, ColorScheme)> _schemes = [];

void _buildSchemes() {
  // Without the binding, google_fonts fails on the asset lookup and prints a
  // page of "there is likely something wrong with your test" — there isn't;
  // it just cannot fetch a webfont offline. Quiet it down to one line.
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  runZonedGuarded(() {
    for (final theme in AppTheme.values) {
      final config = theme.config;
      _schemes.add(('${theme.name}/light', config.light.colorScheme));
      _schemes.add(('${theme.name}/dark', config.dark.colorScheme));
    }
  }, (_, _) {});
}

void main() {
  setUpAll(_buildSchemes);

  // WCAG AA for normal text. The card's label and subtitle are body-sized, so
  // the large-text allowance (3:1) does not apply.
  const aa = 4.5;

  group('invite card — foregrounds match the card they sit on', () {
    test('own card: onPrimaryContainer is readable on primaryContainer', () {
      for (final (name, scheme) in _schemes) {
        expect(
          _contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
          greaterThanOrEqualTo(aa),
          reason: '$name: card title/button on the own-message card',
        );
      }
    });

    test('other card: onSurface is readable on surfaceContainerHighest', () {
      for (final (name, scheme) in _schemes) {
        expect(
          _contrast(scheme.onSurface, scheme.surfaceContainerHighest),
          greaterThanOrEqualTo(aa),
          reason: '$name: card title/button on the received card',
        );
      }
    });

    test('the join button keeps its own contrast pair', () {
      // FilledButton is painted primary/onPrimary explicitly, so it stays
      // legible whichever of the two card backgrounds is underneath.
      for (final (name, scheme) in _schemes) {
        expect(
          _contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(aa),
          reason: '$name: "Beitreten" label',
        );
      }
    });

    test('the muted subtitle still clears AA', () {
      // The subtitle is the card foreground at 85% — the weakest text on the
      // card, and the one an alpha tweak would silently push under the line.
      // The habitual 0.7 does exactly that: it lands at 3.7:1 on meadow and
      // system/light, which is why the card carries an unusual-looking 0.85.
      for (final (name, scheme) in _schemes) {
        final muted = Color.alphaBlend(
          scheme.onPrimaryContainer.withValues(alpha: 0.85),
          scheme.primaryContainer,
        );
        expect(
          _contrast(muted, scheme.primaryContainer),
          greaterThanOrEqualTo(aa),
          reason: '$name: "Gruppen-Einladung" subtitle',
        );
      }
    });
  });

  test('the OLD pairing really was the bug, not the palette', () {
    // Mutation guard: the previous code used `primary` (Material's default
    // button foreground) on `primaryContainer`. If that combination passed
    // everywhere, the tests above would prove nothing about the fix.
    final broken = [
      for (final (name, scheme) in _schemes)
        if (_contrast(scheme.primary, scheme.primaryContainer) < 3.0) name,
    ];
    expect(
      broken,
      contains('forest/dark'),
      reason: 'Forest is the theme Gerry reported; it must fail the old rule',
    );
  });
}
