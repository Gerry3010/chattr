// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../logging/logger_service.dart';
import 'event_types.dart';

/// Central Event Bus ("Main Bus").
///
/// Owns the single user-specific Supabase Realtime channel (`user:<userId>`) and
/// exposes **one** typed in-process [Stream] of [BusEvent]s. Consumers subscribe
/// via [eventStream] / [eventStreamOf] and cancel their subscription on dispose,
/// so there is no manual handler (un)registration to leak.
///
/// **Realtime liveness (#121).** The single channel can go stale while the app
/// stays foregrounded — a network blip, a Supabase idle timeout, a VPN/interface
/// switch, or laptop sleep/wake drops the underlying WebSocket, and Supabase does
/// **not** replay broadcasts sent during the dead window. Previously nothing
/// noticed: `subscribe()` was called without a status callback, and the only
/// rejoin path was an explicit app-resume. So an in-place drop (no lifecycle
/// `resumed`) froze live delivery until the chat was reopened. Now we watch the
/// subscribe status, actively reconnect with capped backoff, and fire
/// [onResubscribed] after a re-join so controllers can run the same catch-up they
/// do on resume (re-fetch whatever was missed).
/// How the app is doing at reaching the server, as far as the realtime channel
/// can tell. Drives the offline banner — see [EventBusService.connectionStream].
enum ServerConnection {
  /// Channel is subscribed. Broadcasts flow.
  connected,

  /// The channel dropped and a reconnect is pending. Deliberately NOT shown to
  /// the user: a blip that heals in a second must not flash a scary banner.
  reconnecting,

  /// Repeated reconnects have failed. This is the state worth telling the user
  /// about — it is what an outage looks like from inside the app.
  unreachable,
}

class EventBusService {
  final SupabaseClient _client;
  final String _userId;

  RealtimeChannel? _channel;
  final StreamController<BusEvent> _eventStream =
      StreamController<BusEvent>.broadcast();

  /// Failed reconnects before we call it an outage rather than a blip.
  ///
  /// Two attempts land at roughly 1s + 2s of backoff, so the banner shows after
  /// ~3 seconds of genuinely not getting through — long enough that a tunnel or
  /// a Wi-Fi handover stays invisible, short enough to answer "is it me or
  /// them?" before the user starts doubting their own data.
  static const int unreachableAfterAttempts = 2;

  final StreamController<ServerConnection> _connection =
      StreamController<ServerConnection>.broadcast();
  ServerConnection _connectionState = ServerConnection.connected;

  /// Fires after the realtime channel re-subscribes following a drop (not on the
  /// very first subscribe). Controllers listen to backfill missed broadcasts.
  final StreamController<void> _resubscribed =
      StreamController<void>.broadcast();

  bool _everSubscribed = false; // has become `subscribed` at least once
  bool _intentionalClose = false; // an app-driven unsubscribe (not a fault)
  bool _disposed = false;
  int _reconnectAttempts = 0;
  Timer? _reconnectTimer;
  final Random _rng = Random();

  EventBusService(this._client, this._userId);

  /// Emitted after a re-subscribe that follows a drop. Use it to catch up on
  /// broadcasts missed during the dead window (mirrors app-resume catch-up).
  Stream<void> get onResubscribed => _resubscribed.stream;

  /// Server reachability, for the UI. Broadcast + [connectionState] as the
  /// current value, so a widget that subscribes late still knows where it
  /// stands instead of waiting for the next change.
  Stream<ServerConnection> get connectionStream => _connection.stream;
  ServerConnection get connectionState => _connectionState;

  void _setConnection(ServerConnection next) {
    if (_connectionState == next) return;
    _connectionState = next;
    if (!_connection.isClosed) _connection.add(next);
  }

  /// Subscribe to the user's event channel.
  void subscribe() {
    if (_channel != null) return; // Already subscribed
    _intentionalClose = false;

    // PRIVATE topic (metadata audit C1). The old `user:<id>` topic was public
    // and had no RLS: any signed-in account — an anonymous one was enough —
    // could subscribe to a stranger's channel and read their whole metadata
    // feed live (chat ids, sender ids, message ids, timestamps, reactions,
    // membership changes). Reproduced against a real stack, not theoretical;
    // user ids are enumerable through the public avatar buckets.
    //
    // `p:` + the old name is guarded by an RLS policy on `realtime.messages`
    // (migration 00063) that ties the topic to auth.uid(). The server sends to
    // The public twin `user:<id>` is GONE (00080, 2026-08-20) — during the
    // transition the server sent to both so clients older than 00063 kept
    // working. Anything still listening on the bare topic now waits forever.
    //
    // A private channel authorizes against the access token. SupabaseClient
    // already pushes it on initialSession/signedIn/tokenRefreshed, so refreshes
    // take care of themselves; this explicit call only closes the startup race
    // where subscribe() runs before that first auth event has propagated.
    final token = _client.auth.currentSession?.accessToken;
    if (token != null) _client.realtime.setAuth(token);

    final channel = _client.channel(
      'p:user:$_userId',
      opts: const RealtimeChannelConfig(private: true),
    );
    _channel = channel;
    channel.onBroadcast(
      event: 'event',
      callback: (payload) {
        try {
          // Triggers send the event payload directly.
          final payloadData =
              (payload['payload'] ?? payload) as Map<String, dynamic>;
          _emit(BusEvent.fromJson(payloadData));
        } catch (e, stackTrace) {
          logger.error('Error parsing event: $e', stackTrace: stackTrace);
          logger.error('Payload: $payload', stackTrace: stackTrace);
        }
      },
    );
    channel.subscribe((status, error) {
      // Ignore late callbacks from a channel we've already torn down/replaced.
      if (channel != _channel) return;
      _onSubscribeStatus(status, error);
    });
  }

  void _onSubscribeStatus(RealtimeSubscribeStatus status, Object? error) {
    switch (status) {
      case RealtimeSubscribeStatus.subscribed:
        _reconnectAttempts = 0;
        _setConnection(ServerConnection.connected);
        _cancelScheduledReconnect();
        if (_everSubscribed) {
          logger.info(
            'Realtime channel re-subscribed — catching up',
            tag: 'EventBus',
          );
          if (!_resubscribed.isClosed) _resubscribed.add(null);
        }
        _everSubscribed = true;
        break;
      case RealtimeSubscribeStatus.channelError:
      case RealtimeSubscribeStatus.timedOut:
        logger.warning(
          'Realtime channel ${status.name} ($error) — scheduling reconnect',
          tag: 'EventBus',
        );
        _scheduleReconnect();
        break;
      case RealtimeSubscribeStatus.closed:
        // A `closed` we didn't ask for means the socket dropped under us.
        if (!_intentionalClose) {
          logger.warning(
            'Realtime channel closed unexpectedly — scheduling reconnect',
            tag: 'EventBus',
          );
          _scheduleReconnect();
        }
        break;
    }
  }

  /// Schedule a single reconnect with capped exponential backoff + jitter
  /// (~1s, 2s, 4s … 30s). Guarded so a flapping channel can't storm reconnects.
  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectTimer?.isActive ?? false) return; // one in-flight
    final seconds = min(30, 1 << min(_reconnectAttempts, 5));
    final delay = Duration(seconds: seconds, milliseconds: _rng.nextInt(1000));
    _setConnection(_reconnectAttempts >= unreachableAfterAttempts
        ? ServerConnection.unreachable
        : ServerConnection.reconnecting);
    _reconnectTimer = Timer(delay, () async {
      _reconnectTimer = null;
      if (_disposed) return;
      _reconnectAttempts++; // escalate until a `subscribed` resets it to 0
      await reconnect();
    });
  }

  void _cancelScheduledReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Rebuild the realtime channel after the socket may have gone stale.
  ///
  /// A plain [subscribe] would early-return on the `_channel != null` guard and
  /// never re-join. Tear the channel down and re-subscribe so future broadcasts
  /// flow again. The in-process [_eventStream] is untouched, so existing consumer
  /// subscriptions survive — only the transport is re-established. Called from
  /// app-resume and from the automatic backoff on an in-place drop.
  Future<void> reconnect() async {
    await unsubscribe();
    if (_disposed) return;
    subscribe();
  }

  /// Unsubscribe from the channel (an intentional, app-driven close).
  Future<void> unsubscribe() async {
    _cancelScheduledReconnect();
    final channel = _channel;
    if (channel != null) {
      _intentionalClose = true;
      // Clear first so the (async) status callback sees a stale channel and the
      // resulting `closed` is not mistaken for a fault.
      _channel = null;
      await channel.unsubscribe();
    }
  }

  /// The single broadcast stream of all events.
  Stream<BusEvent> get eventStream => _eventStream.stream;

  /// Filtered stream for a specific event subtype.
  Stream<T> eventStreamOf<T extends BusEvent>() =>
      _eventStream.stream.where((event) => event is T).cast<T>();

  /// Emit an event **in-process** (e.g. a decrypted message produced locally).
  /// Unlike the old `send(local: true)`, this does NOT re-inject through the
  /// realtime channel, avoiding the broadcast→handler feedback loop.
  void emit(BusEvent event) => _emit(event);

  void _emit(BusEvent event) {
    if (!_eventStream.isClosed) {
      _eventStream.add(event);
    }
  }

  /// Dispose resources: tear down the channel first, then close the streams.
  Future<void> dispose() async {
    _disposed = true;
    _cancelScheduledReconnect();
    await unsubscribe();
    if (!_eventStream.isClosed) {
      await _eventStream.close();
    }
    if (!_resubscribed.isClosed) {
      await _resubscribed.close();
    }
    if (!_connection.isClosed) {
      await _connection.close();
    }
  }
}
