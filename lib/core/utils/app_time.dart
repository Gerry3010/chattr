// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:intl/intl.dart';

/// Central time-formatting helper.
///
/// Supabase `timestamptz` columns serialize with a UTC offset (`…Z`/`+00:00`),
/// so `DateTime.parse(...)` on them yields a **UTC** `DateTime`. Rendering such
/// a value without `.toLocal()` shows UTC wall-clock time — the exact bug this
/// helper prevents: every method here converts to the device's local timezone
/// internally, so a UTC input can never leak into the UI as UTC.
///
/// Only DISPLAY goes through here. Transport & storage stay UTC (models keep
/// parsing to UTC; writes use `.toUtc().toIso8601String()`).
class AppTime {
  const AppTime._();

  /// Raw local conversion — for handing a value to a widget/package that
  /// formats it itself (e.g. the `chatview` package's bubble time and date
  /// separators, which call `DateFormat(...).format(createdAt)` internally
  /// without converting the zone).
  static DateTime local(DateTime dt) => dt.toLocal();

  /// `HH:mm` in the given locale, local time.
  static String hm(DateTime dt, [String? locale]) =>
      DateFormat.Hm(locale).format(dt.toLocal());

  /// `MMM d, HH:mm` (localized), local time.
  static String dayHm(DateTime dt, [String? locale]) =>
      DateFormat.MMMd(locale).add_Hm().format(dt.toLocal());

  /// Locale-aware short date (element order follows the locale), local time.
  static String ymd(DateTime dt, [String? locale]) =>
      DateFormat.yMd(locale).format(dt.toLocal());

  /// Locale-aware short date + time, local time.
  static String ymdHm(DateTime dt, [String? locale]) =>
      DateFormat.yMd(locale).add_Hm().format(dt.toLocal());

  /// True if [dt] falls on the same calendar day as now — both in local time,
  /// so day-boundary checks (today vs. yesterday) don't flip near midnight.
  static bool isSameDayAsNow(DateTime dt) {
    final l = dt.toLocal();
    final now = DateTime.now();
    return l.year == now.year && l.month == now.month && l.day == now.day;
  }

  /// Whole days between now and [dt] as a rolling 24h duration (zone-independent
  /// instant difference). Use for "X hours/days ago" relative time — NOT for
  /// Today/Yesterday calendar labels (see [calendarDaysAgo]).
  static int daysAgo(DateTime dt) => DateTime.now().difference(dt).inDays;

  /// Whole CALENDAR days between [dt]'s local day and today (0 = today,
  /// 1 = yesterday, …). Buckets by the LOCAL calendar date, so a message late
  /// yesterday evening still reads "yesterday" in the small hours after local
  /// midnight — unlike [daysAgo], whose rolling 24h window would call anything
  /// less than a day old "today". Negative for future dates (clamped by callers).
  static int calendarDaysAgo(DateTime dt, {DateTime? now}) {
    final l = dt.toLocal();
    final ref = (now ?? DateTime.now()).toLocal();
    final thatDay = DateTime(l.year, l.month, l.day);
    final today = DateTime(ref.year, ref.month, ref.day);
    return today.difference(thatDay).inDays;
  }

  /// Whole minutes between now and [dt] (absolute duration).
  static int minutesAgo(DateTime dt) => DateTime.now().difference(dt).inMinutes;

  /// Whole hours between now and [dt] (absolute duration).
  static int hoursAgo(DateTime dt) => DateTime.now().difference(dt).inHours;
}
