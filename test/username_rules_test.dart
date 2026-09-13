// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/profile/username_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an ordinary name passes', () {
    expect(isValidUsername('Gerry'), isTrue);
  });

  test('empty and whitespace-only do not', () {
    expect(isValidUsername(''), isFalse);
    expect(isValidUsername('   '), isFalse);
  });

  test('exactly on the limit still passes, one over does not', () {
    expect(isValidUsername('a' * kMaxUsernameLength), isTrue);
    expect(isValidUsername('a' * (kMaxUsernameLength + 1)), isFalse);
  });

  test('surrounding whitespace does not count', () {
    expect(isValidUsername('  ${'a' * kMaxUsernameLength}  '), isTrue);
  });

  test('it is measured in characters, not in code units', () {
    // An emoji outside the basic plane occupies TWO code units in Dart. If
    // `length` counted, the limit would hit a name made of emoji twice as hard
    // as one made of letters — the same rule, differently strict depending on
    // the alphabet.
    final name = '🙂' * kMaxUsernameLength;
    expect(name.length, kMaxUsernameLength * 2);
    expect(isValidUsername(name), isTrue);
    expect(isValidUsername('🙂' * (kMaxUsernameLength + 1)), isFalse);
  });

  test('the documentation-page accident of 2026-08-29 would have been refused', () {
    expect(isValidUsername('# About remote repositories' * 200),
        isFalse);
  });
}
