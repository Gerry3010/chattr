// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Waits until the channel has **really** joined — instead of hoping.
///
/// **Why this is needed.** A broadcast is a shout, not a queue: whoever is not
/// yet in the room when it falls never hears it, and there is nothing to catch
/// up on. The tests here called `subscribe()` without a status callback and
/// then slept for two seconds — a stopwatch where a signal is available. On a
/// machine running twelve Dart VMs at once (`flutter test` takes one process
/// per core) that is sometimes enough and sometimes not: the websocket
/// handshake plus the RLS check on `realtime.messages` for the private topic
/// take longer under load. Then the insert happens, the shout falls into an
/// empty room, and the test waits eight seconds for something that no longer
/// exists — green at `-j1`, red in a full run.
///
/// The app does it right at this point (`event_bus_service.dart`,
/// `RealtimeSubscribeStatus.subscribed`); the tests had simply never been told.
///
/// Calls [RealtimeChannel.subscribe] itself — so the caller only attaches their
/// `onBroadcast` callbacks and hands the channel over here.
Future<void> awaitJoined(
  RealtimeChannel channel, {
  Duration timeout = const Duration(seconds: 30),
}) {
  final joined = Completer<void>();
  channel.subscribe((status, error) {
    if (joined.isCompleted) return; // spaete Rueckrufe beim Abbau ignorieren
    switch (status) {
      case RealtimeSubscribeStatus.subscribed:
        joined.complete();
      case RealtimeSubscribeStatus.channelError:
      case RealtimeSubscribeStatus.timedOut:
      case RealtimeSubscribeStatus.closed:
        joined.completeError(
          StateError('Kanal-Beitritt fehlgeschlagen: $status (${error ?? '—'})'),
        );
    }
  });
  return joined.future.timeout(
    timeout,
    onTimeout: () => throw TimeoutException(
      'Kanal ${channel.topic} war nach $timeout nicht beigetreten',
    ),
  );
}

/// Sends until the shout arrives — at most [attempts] times.
///
/// **Why a second attempt is not papering over.** The local realtime tenant
/// shuts down when idle (`idle_shutdown reached`) and comes up cold on the next
/// connect: "Tenant is initializing", "Creating partitions for
/// realtime.messages", "Starting replication for Broadcast Changes".
/// `realtime.send()` from the trigger writes into `realtime.messages`; the row
/// is **delivered** by the replication connection. If that is not up yet, the
/// row sits there and nobody calls it out — the shout then does not come late
/// but **never**. Waiting longer therefore does not help; that was the fallacy
/// of the 45-second deadline.
///
/// Nor is it stricter than the app itself: nowhere does it rely on a single
/// shout arriving. After every re-join a catch-up run happens (#121,
/// `onResubscribed`), and what was never fetched is found by the `received_at
/// IS NULL` pass. A test insisting on EXACTLY ONE shout checks a promise that
/// does not exist.
///
/// What SHOULD still fail here: realtime not delivering at all — then the
/// fourth shout does not arrive either.
Future<bool> sendUntilReceived({
  required Future<void> Function() send,
  required Completer<Map<String, dynamic>> empfangen,
  int attempts = 4,
  Duration perAttempt = const Duration(seconds: 12),
}) async {
  for (var i = 0; i < attempts; i++) {
    await send();
    try {
      await empfangen.future.timeout(perAttempt);
      return true;
    } on TimeoutException {
      // Again. The first shout fell into a tenant that was just coming up.
    }
  }
  return empfangen.isCompleted;
}
