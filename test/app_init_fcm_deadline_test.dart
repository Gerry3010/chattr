// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Startup must not hang on the push registration.
//
// Measured on 2026-08-25 in the browser: `Notification.requestPermission()`
// does NOT resolve its promise while the permission dialog is unanswered — six
// seconds of nothing, and arbitrarily longer after. `FCMService.initialize()`
// asks exactly that, startup waited on it, so `initialize()` never returned,
// `runApp` never ran, and the page stayed in the loading screen forever.
//
// This long counted as a quirk of staging. It hit every origin without a stored
// answer, production included — it just went unseen there, because our own
// browsers had long since answered. So what is checked is not "FCM works" but:
// an answer that never comes does not hold up the start.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/init/app_init.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => AppInit.fcmStarterForTest = null);

  test('a registration that never answers does not hold up the start', () async {
    // Exactly the browser case: a promise that is never fulfilled.
    AppInit.fcmStarterForTest = () => Completer<void>().future;

    final uhr = Stopwatch()..start();
    final dienst = await AppInit.initializeFcm();
    uhr.stop();

    expect(dienst, isNull, reason: 'carry on without push rather than wait');
    expect(
      uhr.elapsed,
      lessThan(AppInit.fcmInitDeadline + const Duration(seconds: 3)),
      reason: 'the deadline has to bite, not end by itself at some point',
    );
  });

  test('an error during registration stays without consequence', () async {
    AppInit.fcmStarterForTest = () async => throw StateError('kein Firebase');

    expect(await AppInit.initializeFcm(), isNull);
  });

  test('the deadline is set and not absurdly long', () async {
    // A deadline of one minute would formally be a fix and practically the same
    // fault — nobody watches a page load for a minute.
    expect(AppInit.fcmInitDeadline.inSeconds, greaterThan(0));
    expect(AppInit.fcmInitDeadline.inSeconds, lessThanOrEqualTo(15));
  });
}
