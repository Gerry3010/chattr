// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/utils/app_time.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

/// Guards the core promise of AppTime: every formatter converts to local time
/// internally, so a UTC `DateTime` (as produced by parsing a Supabase
/// `timestamptz`) is never rendered as UTC wall-clock time.
void main() {
  setUpAll(() async {
    await initializeDateFormatting();
  });

  test('local() returns the same instant as local (non-UTC) DateTime', () {
    final utc = DateTime.utc(2026, 7, 13, 22, 15);
    final local = AppTime.local(utc);
    expect(local.isUtc, isFalse);
    expect(local.isAtSameMomentAs(utc), isTrue);
  });

  test('hm/dayHm/ymd/ymdHm format the LOCAL time, not the raw UTC value', () {
    final utc = DateTime.utc(2026, 7, 13, 22, 15);
    expect(AppTime.hm(utc, 'en_US'), DateFormat.Hm('en_US').format(utc.toLocal()));
    expect(AppTime.dayHm(utc, 'en_US'),
        DateFormat.MMMd('en_US').add_Hm().format(utc.toLocal()));
    expect(AppTime.ymd(utc, 'en_US'), DateFormat.yMd('en_US').format(utc.toLocal()));
    expect(AppTime.ymdHm(utc, 'en_US'),
        DateFormat.yMd('en_US').add_Hm().format(utc.toLocal()));
  });

  test('in a non-UTC host zone, hm differs from formatting the raw UTC', () {
    final utc = DateTime.utc(2026, 7, 13, 22, 15);
    // Only meaningful where the host offset is non-zero (e.g. CEST). On a UTC
    // runner the two are legitimately identical, so we skip the assertion there.
    if (utc.toLocal().hour != utc.hour || utc.toLocal().day != utc.day) {
      expect(AppTime.hm(utc, 'en_US'),
          isNot(DateFormat.Hm('en_US').format(utc)));
    }
  });

  test('ymd follows the locale order (de: dd.MM.yyyy, en: M/d/yyyy)', () {
    final dt = DateTime.utc(2026, 7, 13, 10);
    final de = AppTime.ymd(dt, 'de_DE');
    final en = AppTime.ymd(dt, 'en_US');
    expect(de, contains('.'));
    expect(en, contains('/'));
    expect(de, isNot(en));
  });

  test('isSameDayAsNow: now is same day, three days ago is not', () {
    expect(AppTime.isSameDayAsNow(DateTime.now().toUtc()), isTrue);
    expect(
      AppTime.isSameDayAsNow(
        DateTime.now().toUtc().subtract(const Duration(days: 3)),
      ),
      isFalse,
    );
  });

  test('daysAgo/minutesAgo/hoursAgo count the absolute duration', () {
    final now = DateTime.now();
    expect(AppTime.daysAgo(now.subtract(const Duration(days: 3))), 3);
    expect(AppTime.hoursAgo(now.subtract(const Duration(hours: 5))), 5);
    expect(AppTime.minutesAgo(now.subtract(const Duration(minutes: 42))), 42);
  });

  group('calendarDaysAgo buckets by LOCAL calendar day, not a rolling 24h', () {
    // Local wall-clock dates (toLocal() is a no-op on them), so the assertions
    // are TZ-independent.
    final now = DateTime(2026, 7, 26, 1, 52); // small hours — the bug window

    test('yesterday 22:00 reads as 1 day even at 01:52 (the reported bug)', () {
      // Only ~4h ago → rolling daysAgo would say 0 ("today"); calendar says 1.
      expect(AppTime.calendarDaysAgo(DateTime(2026, 7, 25, 22, 0), now: now), 1);
    });

    test('same calendar day is 0 regardless of hour gap', () {
      expect(AppTime.calendarDaysAgo(DateTime(2026, 7, 26, 0, 5), now: now), 0);
      expect(AppTime.calendarDaysAgo(now, now: now), 0);
    });

    test('two calendar days back is 2', () {
      expect(AppTime.calendarDaysAgo(DateTime(2026, 7, 24, 23, 0), now: now), 2);
    });

    test('a UTC timestamp is converted to local before bucketing', () {
      // 2026-07-25 20:00 UTC = 22:00 CEST (yesterday) → still 1 day on a CEST
      // host; on a UTC host it is 2026-07-25 as well → also 1. Either way not 0.
      expect(
        AppTime.calendarDaysAgo(DateTime.utc(2026, 7, 25, 20, 0), now: now),
        greaterThanOrEqualTo(1),
      );
    });
  });
}
