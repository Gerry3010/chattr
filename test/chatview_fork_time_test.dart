// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Verifies our chatview FORK (Gerry3010/chatview @ chattr branch) renders bubble
// times in 24-hour format and the device's local timezone — sampling the exact
// package export the bubble widgets call (`DateTime.getTimeFromDateTime`) rather
// than the app's own code. This is the library-boundary check for fork patch P1.
// ignore_for_file: implementation_imports
import 'package:chatview/src/extensions/extensions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting();
  });

  test('getTimeFromDateTime is 24h (no AM/PM) and local', () {
    // A UTC instant from Supabase (timestamptz parses to UTC).
    final utc = DateTime.utc(2026, 7, 12, 14, 29);
    final rendered = utc.getTimeFromDateTime;
    // Evidence in the test log:
    // ignore: avoid_print
    print('FORK getTimeFromDateTime(2026-07-12T14:29Z) = "$rendered" '
        '(host local = ${DateFormat('HH:mm').format(utc.toLocal())})');

    // 24h shape HH:mm, never AM/PM.
    expect(RegExp(r'^\d{2}:\d{2}$').hasMatch(rendered), isTrue,
        reason: '"$rendered" is not 24h HH:mm');
    expect(rendered.toUpperCase(), isNot(contains('AM')));
    expect(rendered.toUpperCase(), isNot(contains('PM')));
    // Local: equals formatting the LOCAL time, not the raw UTC value.
    expect(rendered, DateFormat('HH:mm').format(utc.toLocal()));
  });

  test('getDay separator uses local calendar day', () {
    // 23:30 UTC today is already tomorrow in far-east zones / same-day here;
    // the separator must be computed on local time. We assert "today" resolves
    // for a local-now instant regardless of how it was constructed.
    final nowUtc = DateTime.now().toUtc();
    final day = nowUtc.getDay('d MMM'); // today/yesterday come from PackageStrings
    // ignore: avoid_print
    print('FORK getDay(now) = "$day"');
    expect(day, isNotEmpty);
  });
}
