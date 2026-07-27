// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// M2 (username impersonation cue): the avatar color is bound to the peer's
// cryptographic identity, deterministically and independent of the (mutable,
// non-unique) username.

import 'package:chattr/features/identity/identity_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same seed → same color; different seed → different color', () {
    expect(IdentityColor.forSeed('idkey-A'), IdentityColor.forSeed('idkey-A'));
    expect(IdentityColor.forSeed('idkey-A'),
        isNot(IdentityColor.forSeed('idkey-B')));
  });

  test('color is bound to the identity key, NOT the username', () {
    // Two impersonators sharing a display name but with distinct identity keys
    // must get visibly different avatars.
    final a = IdentityColor.forKeyOrId('identity-key-alice', 'user-1');
    final b = IdentityColor.forKeyOrId('identity-key-mallory', 'user-2');
    expect(a, isNot(b));
    // And the SAME identity always yields the SAME color regardless of user_id
    // passed as fallback (the key wins when present).
    expect(
      IdentityColor.forKeyOrId('identity-key-alice', 'user-1'),
      IdentityColor.forKeyOrId('identity-key-alice', 'user-DIFFERENT'),
    );
  });

  test('falls back to user_id when no identity key is published', () {
    expect(IdentityColor.forKeyOrId(null, 'user-x'),
        IdentityColor.forSeed('user-x'));
    expect(IdentityColor.forKeyOrId('', 'user-x'),
        IdentityColor.forSeed('user-x'));
    // Distinct users still differ.
    expect(IdentityColor.forKeyOrId(null, 'user-x'),
        isNot(IdentityColor.forKeyOrId(null, 'user-y')));
  });

  test('foregroundOn picks a readable contrast', () {
    expect(IdentityColor.foregroundOn(Colors.white), Colors.black);
    expect(IdentityColor.foregroundOn(Colors.black), Colors.white);
  });

  test('the chosen foreground clears WCAG AA on every generated hue', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    // Sweep many identities → many hues; the initial letter must always be
    // legible (AA large-text threshold 3.0, comfortably cleared).
    for (var i = 0; i < 200; i++) {
      final bg = IdentityColor.forSeed('identity-$i');
      final fg = IdentityColor.foregroundOn(bg);
      expect(contrast(bg, fg), greaterThan(3.0),
          reason: 'low contrast for seed identity-$i');
    }
  });
}
