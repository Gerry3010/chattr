// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Regression: the "create a new identity key" button shipped in 1.14.0 was
// UNREACHABLE in the exact state it exists for.
//
// The verification screen renders `_unknownInfo` — which holds the button —
// only when safetyNumberProvider resolves to `null`. A device whose identity
// key is present but unreadable made that provider THROW, so the screen fell
// into its error branch, printed `Error: IdentityKeyLockedException: …` and
// offered nothing. Found on a real device (SeB) on 2026-08-07; my own 1.14.0
// device check ran on a phone with a healthy identity, where the failing branch
// cannot occur.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/security/key_locked_exception.dart';
import 'package:chattr/features/identity/identity_verification_controller.dart';

void main() {
  group('identityRemedyFor', () {
    test('a locked identity offers REGENERATE, not publish', () {
      // Publishing cannot succeed — ensureKeyPair() throws forever — so the
      // old "publish now" button was a dead end that looked like a remedy.
      expect(
        identityRemedyFor(IdentityKeyLockedException('unreadable')),
        IdentityRemedy.regenerate,
      );
    });

    test('any other failure offers PUBLISH', () {
      // "Not published yet" must never re-mint: that flips every peer's safety
      // number for no reason.
      expect(identityRemedyFor(StateError('no key')), IdentityRemedy.publish);
      expect(identityRemedyFor(Exception('offline')), IdentityRemedy.publish);
    });

    test('no error means no remedy is offered at all', () {
      expect(identityRemedyFor(null), IdentityRemedy.none);
    });
  });

  group('the locked case must reach the remedy UI', () {
    // safetyNumberProvider needs a container and a real key manager to drive
    // end-to-end, so this asserts the contract the screen depends on: the
    // button lives behind `data(null)`, never behind `error`. If a future
    // change lets IdentityKeyLockedException escape the provider again, the
    // screen goes back to printing a raw exception with no way out.
    test('a locked key is classified as "offer the regenerate button"', () {
      final remedy = identityRemedyFor(
        IdentityKeyLockedException('identity key present but unreadable'),
      );
      expect(remedy, IdentityRemedy.regenerate);
      expect(
        remedy,
        isNot(IdentityRemedy.none),
        reason: 'none would leave the user stuck with unsigned messages',
      );
    });
  });
}
