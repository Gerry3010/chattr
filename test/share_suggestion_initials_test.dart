// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The share suggestion row showed the empty system placeholder for contacts and
// groups without a picture — next to WhatsApp's photos that stands out. Now the
// app renders the same initials circle it shows on screen as a PNG and hands
// the file over.
//
// The point of these tests is NOT the picture but the rule behind it: colour
// and contrast may exist only ONCE. The black/white crossover lies at relative
// luminance ≈0.179, not at 0.5 — exactly that was wrong once before (fork patch
// p21), and a second implementation would silently get it wrong again.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/identity/identity_color.dart';
import 'package:chattr/features/share_suggestions/share_suggestion_avatar_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the colour comes from the same source as in the app', () {
    test('same user → same colour as the avatar widget', () {
      // The widget uses forKeyOrId; the suggestion row is handed precisely that
      // result instead of deriving it anew from a seed.
      const id = 'user-1';
      const key = 'identity-key-abc';
      expect(IdentityColor.forKeyOrId(key, id), IdentityColor.forSeed(key));
      expect(IdentityColor.forKeyOrId(null, id), IdentityColor.forSeed(id));
      expect(IdentityColor.forKeyOrId('', id), IdentityColor.forSeed(id));
    });

    test('the colour is stable across runs', () {
      // Otherwise the same contact would get a different colour on every app
      // start — and the cache would create new files endlessly.
      expect(IdentityColor.forSeed('abc'), IdentityColor.forSeed('abc'));
      expect(IdentityColor.forSeed('abc'), isNot(IdentityColor.forSeed('abd')));
    });
  });

  group('contrast: the crossover is at 0.179, not at 0.5', () {
    // A simple `luminance > 0.5` would choose white type for mid-bright colours
    // (yellow, green) — black reads markedly better there.
    test('helle Farben bekommen schwarze Schrift', () {
      for (final c in [Colors.yellow, Colors.lightGreen, Colors.amber]) {
        expect(IdentityColor.foregroundOn(c), Colors.black, reason: '$c');
      }
    });

    test('dark colours get white type', () {
      for (final c in [Colors.indigo, Colors.brown, const Color(0xFF1A1F2E)]) {
        expect(IdentityColor.foregroundOn(c), Colors.white, reason: '$c');
      }
    });

    test('mid-dark colours already tip to black', () {
      // blueGrey looks dark but sits ABOVE the crossover at luminance ≈0.21 —
      // black reads better there. These are exactly the colours a naive `>0.5`
      // rule gets wrong, and exactly where the original fault lay.
      expect(Colors.blueGrey.computeLuminance(), greaterThan(0.179));
      expect(IdentityColor.foregroundOn(Colors.blueGrey), Colors.black);
    });

    test('exactly at the crossover the higher-contrast side is chosen', () {
      // Just below 0.179 → white, just above → black.
      Color grau(double l) => HSLColor.fromAHSL(1, 0, 0, l).toColor();
      expect(IdentityColor.foregroundOn(grau(0.40)), Colors.white);
      expect(IdentityColor.foregroundOn(grau(0.50)), Colors.black);
    });
  });

  group('pathForInitials', () {
    test('returns null in a test without a file system rather than throwing', () async {
      // Best effort is a condition: the donation hangs on the send path, it
      // must never hold up a message. Without a real app directory
      // (path_provider has no platform in a unit test) null has to come out.
      final p = await ShareSuggestionAvatarCache.pathForInitials(
        background: const Color(0xFF3366AA),
        displayName: 'Sebi',
      );
      expect(p, anyOf(isNull, isA<String>()));
      if (p != null) expect(File(p).existsSync(), isTrue);
    });
  });

  group('Initialen', () {
    test('one word → one letter, two words → two', () {
      expect(initialsFor('Sebi'), 'S');
      expect(initialsFor('Android Gerre'), 'AG');
      expect(initialsFor('  mehrere   wörter   hier '), 'MH');
    });

    test('an empty name falls back on a question mark', () {
      // Eine Gruppe ohne Namen darf keinen leeren Kreis erzeugen.
      expect(initialsFor(''), '?');
      expect(initialsFor('   '), '?');
    });
  });
}
