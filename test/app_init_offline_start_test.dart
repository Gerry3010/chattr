// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-63: the splash screen stood ~12.5 s on every start without network,
// because the session check waited out gotrue's retries (measured
// 2026-10-29). The check now has a deadline. What must not change: an
// explicit answer from the server still reaches the "account gone" logic.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/core/init/app_init.dart';

void main() {
  test('ohne Antwort geht der Start nach der Frist weiter', () async {
    final uhr = Stopwatch()..start();
    final antwort = await AppInit.refreshWithDeadline(
      () => Completer<AuthResponse>().future,
      deadline: const Duration(milliseconds: 200),
    );
    expect(antwort, isNull);
    expect(uhr.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('eine Ablehnung des Servers kommt weiter durch', () async {
    await expectLater(
      AppInit.refreshWithDeadline(
        () async => throw AuthApiException('User not found', code: 'user_not_found'),
      ),
      throwsA(isA<AuthApiException>()),
    );
  });

  test('eine schnelle Antwort wird durchgereicht', () async {
    final antwort =
        await AppInit.refreshWithDeadline(() async => AuthResponse());
    expect(antwort, isNotNull);
  });

  test('die Frist liegt deutlich unter den gemessenen 12,5 s', () {
    expect(AppInit.authCheckDeadline.inSeconds, inInclusiveRange(2, 6));
  });
}
