// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Before the rebuild, the mapping trust state → icon and colour stood in the
// code THREE times (header, profile sheet, member list). These tests pin down
// the one remaining version — with a trust indicator, "two surfaces claim
// different things" is the dangerous kind of fault.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/identity/identity_verification_controller.dart';
import 'package:chattr/features/identity/identity_verification_repository.dart';
import 'package:chattr/features/identity/widgets/trust_shield.dart';

void main() {
  group('trustAppearanceFor', () {
    test('verified is green with a filled shield', () {
      final look = trustAppearanceFor(IdentityVerificationState.verified);
      expect(look.icon, Icons.verified_user);
      expect(look.color, Colors.green);
    });

    test('a changed key is red and warns', () {
      final look = trustAppearanceFor(IdentityVerificationState.changed);
      expect(look.icon, Icons.gpp_bad);
      expect(look.color, Colors.red);
    });

    test('unverified and unknown are both a neutral grey', () {
      for (final state in const [
        IdentityVerificationState.unverified,
        IdentityVerificationState.unknown,
      ]) {
        final look = trustAppearanceFor(state);
        expect(look.icon, Icons.shield_outlined, reason: '$state');
        expect(look.color, Colors.grey, reason: '$state');
      }
    });
  });

  group('trustAppearanceForSummary', () {
    ChatVerificationSummary summary({
      required bool anyChanged,
      required bool allVerified,
    }) {
      return ChatVerificationSummary({
          'p': anyChanged
              ? IdentityVerificationState.changed
              : allVerified
                  ? IdentityVerificationState.verified
                  : IdentityVerificationState.unverified,
      });
    }

    test('all verified colours the whole chat green', () {
      final look = trustAppearanceForSummary(
        summary(anyChanged: false, allVerified: true),
      );
      expect(look.color, Colors.green);
    });

    test('nobody verified stays grey', () {
      final look = trustAppearanceForSummary(
        summary(anyChanged: false, allVerified: false),
      );
      expect(look.color, Colors.grey);
    });

    test(
      'a single changed key beats the verified majority',
      () {
        // Otherwise the warning disappears behind nineteen green ticks — and
        // the one row that counts is seen by nobody.
        final look = trustAppearanceForSummary(
          ChatVerificationSummary({
            'a': IdentityVerificationState.verified,
            'b': IdentityVerificationState.verified,
            'c': IdentityVerificationState.changed,
          }),
        );
        expect(look.icon, Icons.gpp_bad);
        expect(look.color, Colors.red);
      },
    );
  });
}
