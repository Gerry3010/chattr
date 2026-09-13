// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Cross-package parity guard for the avatar initials (1.11.1).
//
// The chatview fork draws the in-chat circles (app bar, message circles,
// reaction pills/sheet) while the app draws the rest (chat list, profile sheet,
// chat details). Until p21 they picked the letter colour by different rules —
// the fork with `luminance > 0.5`, the app with the WCAG crossover (~0.179) —
// so the SAME user showed a white letter in the chat header and a black one in
// the chat list. These tests pin both sides to one rule.
//
//   flutter test test/avatar_contrast_parity_test.dart

import 'package:chatview/chatview.dart' show ProfileImageWidget;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/identity/identity_color.dart';

Color _letterColorOf(WidgetTester tester) =>
    tester.widget<Text>(find.byType(Text)).style!.color!;

Future<void> _pumpForkAvatar(
  WidgetTester tester, {
  required Color background,
  double circleRadius = 20,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProfileImageWidget(
          userName: 'Bob Builder',
          fallbackBackgroundColor: background,
          circleRadius: circleRadius,
          networkImageProgressIndicatorBuilder: null,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    ProfileImageWidget.fallbackForegroundResolver = null;
  });
  tearDown(() {
    ProfileImageWidget.fallbackForegroundResolver = null;
  });

  group('fork ↔ app parity', () {
    testWidgets('same letter colour on every palette hue', (tester) async {
      // Sample the palette widely; every hue must agree across both renderers.
      for (var seed = 0; seed < 60; seed++) {
        final bg = IdentityColor.forSeed('parity-$seed');
        await _pumpForkAvatar(tester, background: bg);
        expect(
          _letterColorOf(tester),
          IdentityColor.foregroundOn(bg),
          reason: 'hue seed $seed (bg $bg) diverged between fork and app',
        );
      }
    });

    testWidgets('mid-luminance hue: both pick black (old fork said white)',
        (tester) async {
      const amber = Color(0xFFCBCB4D); // HSL(60°, .55, .55)
      await _pumpForkAvatar(tester, background: amber);
      expect(_letterColorOf(tester), Colors.black);
      expect(IdentityColor.foregroundOn(amber), Colors.black);
    });

    testWidgets('dark hue: both pick white', (tester) async {
      const indigo = Color(0xFF4D4DCB); // HSL(240°, .55, .55)
      await _pumpForkAvatar(tester, background: indigo);
      expect(_letterColorOf(tester), Colors.white);
      expect(IdentityColor.foregroundOn(indigo), Colors.white);
    });

    testWidgets('the app-injected resolver wins over the built-in rule',
        (tester) async {
      ProfileImageWidget.fallbackForegroundResolver = (_) => Colors.red;
      await _pumpForkAvatar(tester, background: const Color(0xFF4D4DCB));
      expect(_letterColorOf(tester), Colors.red);
    });

    testWidgets('letter scales identically on both sides (0.8 × radius)',
        (tester) async {
      const bg = Color(0xFF4D4DCB);
      for (final radius in <double>[8, 16, 20, 44, 56]) {
        await _pumpForkAvatar(tester, background: bg, circleRadius: radius);
        final forkSize = tester.widget<Text>(find.byType(Text)).style!.fontSize;
        expect(
          forkSize,
          closeTo(IdentityColor.initialsTextStyle(radius, bg).fontSize!, 0.01),
          reason: 'radius $radius: fork and app initials sizes differ',
        );
      }
    });
  });
}
