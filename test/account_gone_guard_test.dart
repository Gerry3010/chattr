// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The brake in front of the only remaining self-deletion (Gerry, 2026-08-31: "a
// maintenance mode where the devices do not delete themselves even if their
// user were deleted by a bug").
//
// What is at stake here: the server clears the ciphertext away as soon as the
// device has fetched it — the local database is the ONLY readable copy of read
// messages. A wrong "delete" is restorable nowhere, not even from a server
// backup.
//
// So these tests check above all the direction doubt falls in: everything that
// is not unambiguously "final" has to yield `false`.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/init/account_gone_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 8, 31, 12);
  AccountGoneRecord rec(DateTime seit, int starts) =>
      AccountGoneRecord(firstSeen: seit, launches: starts);

  group('accountGoneIsFinal', () {
    test('without a mark nothing is ever deleted', () {
      expect(accountGoneIsFinal(null, t0), isFalse);
    });

    test('too few launches are not enough, however long ago it was', () {
      // The device lay in a drawer for a year and was asked ONCE.
      expect(
        accountGoneIsFinal(rec(t0, 1), t0.add(const Duration(days: 365))),
        isFalse,
      );
    });

    test('many launches are not enough when the time is missing', () {
      // Drei schnelle Neustarts mitten in einem Vorfall.
      expect(
        accountGoneIsFinal(rec(t0, 9), t0.add(const Duration(minutes: 10))),
        isFalse,
      );
    });

    test('only both together are final', () {
      expect(
        accountGoneIsFinal(rec(t0, 3), t0.add(const Duration(hours: 72))),
        isTrue,
      );
    });

    test('one second before it is up, not yet', () {
      expect(
        accountGoneIsFinal(
            rec(t0, 3), t0.add(const Duration(hours: 72) - const Duration(seconds: 1))),
        isFalse,
      );
    });
  });

  group('AccountGoneRecord.tryParse — broken means knowing nothing', () {
    test('empty and null yield nothing', () {
      expect(AccountGoneRecord.tryParse(null), isNull);
      expect(AccountGoneRecord.tryParse(''), isNull);
    });

    test('garbage yields nothing — and therefore NO deletion', () {
      for (final kaputt in ['{', 'null', '[]', '{"launches":3}', '"text"']) {
        expect(AccountGoneRecord.tryParse(kaputt), isNull, reason: kaputt);
        expect(accountGoneIsFinal(AccountGoneRecord.tryParse(kaputt), t0),
            isFalse);
      }
    });

    test('a negative counter is no counter', () {
      expect(
        AccountGoneRecord.tryParse(
            '{"first_seen":"2026-08-31T12:00:00Z","launches":-5}'),
        isNull,
      );
    });

    test('what was written comes back out', () {
      final r = rec(t0, 2);
      final back = AccountGoneRecord.tryParse(
          '{"first_seen":"${t0.toIso8601String()}","launches":2}');
      expect(back!.firstSeen, r.firstSeen);
      expect(back.launches, 2);
    });
  });

  group('carrying it forward in memory', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('the first launch sets the start, later ones only count up', () async {
      const storage = FlutterSecureStorage();
      final a = await recordAccountGone(storage, t0);
      expect(a.launches, 1);
      expect(a.firstSeen, t0);

      final b = await recordAccountGone(storage, t0.add(const Duration(days: 5)));
      expect(b.launches, 2);
      expect(b.firstSeen, t0,
          reason: 'the start must not move along — otherwise the grace period never runs out');
    });

    test('three launches over four days are final', () async {
      const storage = FlutterSecureStorage();
      await recordAccountGone(storage, t0);
      await recordAccountGone(storage, t0.add(const Duration(days: 2)));
      final dritter =
          await recordAccountGone(storage, t0.add(const Duration(days: 4)));
      expect(accountGoneIsFinal(dritter, t0.add(const Duration(days: 4))),
          isTrue);
    });

    test('a valid session forgets the mark completely', () async {
      const storage = FlutterSecureStorage();
      await recordAccountGone(storage, t0);
      await recordAccountGone(storage, t0.add(const Duration(days: 2)));
      await clearAccountGone(storage);

      // Not only the counter, the start has to go too: otherwise a single blip
      // weeks later would tear straight through the time threshold.
      final after =
          await recordAccountGone(storage, t0.add(const Duration(days: 30)));
      expect(after.launches, 1);
      expect(after.firstSeen, t0.add(const Duration(days: 30)));
      expect(accountGoneIsFinal(after, t0.add(const Duration(days: 30))),
          isFalse);
    });
  });
}
