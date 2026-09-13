// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/events/event_bus_service.dart';

/// The rule the offline banner hangs on: a blip must stay silent, a real
/// outage must speak up. Getting this wrong in either direction is bad — a
/// banner on every Wi-Fi handover trains people to ignore it, and no banner at
/// all is what made the 2026-08-04 outage look like data loss.
///
/// [EventBusService] itself needs a live Supabase client, so what is pinned
/// here is the decision the reconnect path makes, expressed the same way.
ServerConnection stateFor(int failedAttempts) =>
    failedAttempts >= EventBusService.unreachableAfterAttempts
        ? ServerConnection.unreachable
        : ServerConnection.reconnecting;

void main() {
  test('a single drop is a blip, not an outage', () {
    expect(stateFor(0), ServerConnection.reconnecting);
    expect(stateFor(1), ServerConnection.reconnecting);
  });

  test('repeated failures are reported as unreachable', () {
    expect(stateFor(2), ServerConnection.unreachable);
    expect(stateFor(7), ServerConnection.unreachable);
  });

  test('the threshold stays low enough to answer "is it me or them?"', () {
    // Backoff is ~1s, 2s, 4s … so the threshold in attempts translates to the
    // seconds a user waits before the app explains itself. Two attempts ≈ 3s.
    // If someone raises this, the banner starts arriving after the user has
    // already begun doubting their own data — which is the failure it exists
    // to prevent.
    expect(EventBusService.unreachableAfterAttempts, lessThanOrEqualTo(3));
    // And not zero: the very first drop must not paint the screen red.
    expect(EventBusService.unreachableAfterAttempts, greaterThan(0));
  });

  test('connected is the only state the banner stays quiet for by default', () {
    // The banner renders for `unreachable` alone. Pin the enum so a future
    // state can't silently start (or stop) triggering it.
    expect(ServerConnection.values, [
      ServerConnection.connected,
      ServerConnection.reconnecting,
      ServerConnection.unreachable,
    ]);
  });
}
