// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../network/device_connectivity.dart';
import '../supabase/supabase_client_provider.dart';
import '../../features/auth/auth_controller.dart';
import 'event_bus_service.dart';

/// Provider for the central event bus
/// 
/// Returns null if user is not logged in
final eventBusProvider = Provider<EventBusService?>((ref) {
  final client = ref.read(supabaseClientProvider);
  final userId = ref.watch(authControllerProvider);

  if (userId == null) {
    return null;
  }

  final eventBus = EventBusService(client, userId);
  
  // Subscribe on creation
  eventBus.subscribe();

  // The network came back, or changed under a dead channel: reconnect now
  // instead of waiting out the backoff (CHAT-63). The re-join then runs the
  // usual catch-up.
  ref.listen<AsyncValue<List<ConnectivityResult>>>(
    connectivityResultsProvider,
    (previous, next) {
      final results = next.value;
      if (results == null) return;
      if (reconnectOnNetworkChange(
        previous: previous?.value,
        next: results,
        channelConnected:
            eventBus.connectionState == ServerConnection.connected,
      )) {
        unawaited(eventBus.reconnect());
      }
    },
  );

  // Cleanup on dispose
  ref.onDispose(() {
    eventBus.dispose();
  });

  return eventBus;
});

/// Whether the server is reachable, for the offline banner.
///
/// Reads the realtime channel's own reconnect state rather than adding a
/// separate health poll: that channel is already a permanently-open connection
/// to the same host, so it notices an outage first and costs nothing extra. Its
/// backoff decides when a drop stops being a blip and becomes an outage
/// ([EventBusService.unreachableAfterAttempts]).
///
/// Defaults to [ServerConnection.connected] while logged out — there is no
/// channel then, and a login screen must not accuse the server of being down.
final serverConnectionProvider = StreamProvider<ServerConnection>((ref) async* {
  final bus = ref.watch(eventBusProvider);
  if (bus == null) {
    yield ServerConnection.connected;
    return;
  }
  // Seed with the current value so a widget that mounts mid-outage shows the
  // banner immediately instead of waiting for the next state change.
  yield bus.connectionState;
  yield* bus.connectionStream;
});
