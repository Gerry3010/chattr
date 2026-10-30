// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';

/// The part of a realtime channel the typing indicator uses.
///
/// A seam, so the reconnect behaviour below can be tested without a socket:
/// it is exactly the part that broke silently (CHAT-53).
abstract class TypingTransport {
  void onPresenceSync(void Function() callback);

  /// Every presence payload currently on the channel, flattened.
  List<Map<String, dynamic>> presences();

  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  );

  Future<void> track(Map<String, dynamic> payload);
}

class _RealtimeTypingTransport implements TypingTransport {
  _RealtimeTypingTransport(this.channel);

  final RealtimeChannel channel;

  @override
  void onPresenceSync(void Function() callback) =>
      channel.onPresenceSync((_) => callback());

  @override
  List<Map<String, dynamic>> presences() => [
        for (final item in channel.presenceState())
          for (final presence in item.presences) presence.payload,
      ];

  @override
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  ) =>
      channel.subscribe(callback);

  @override
  Future<void> track(Map<String, dynamic> payload) => channel.track(payload);
}

/// One chat's typing channel plus what is needed to rebuild it.
class _TypingRoom {
  _TypingRoom(this.chatId);

  final String chatId;
  final StreamController<List<String>> updates =
      StreamController<List<String>>.broadcast();
  TypingTransport? transport;
  Timer? retry;
  int attempts = 0;
  bool closed = false;
}

/// Service for managing typing indicators using Supabase Presence
///
/// **The plaintext name does NOT travel along.** The presence payload used to
/// carry `username` — on a channel the server sees and whose name follows from
/// the chat id. So it stated in the clear who was typing, although every
/// message in the same chat is encrypted. What is transmitted now is only the
/// user id; the recipient resolves the display name from the profile data they
/// have anyway ([ChatViewController]).
///
/// The ids stay — they are in every message record regardless, and without them
/// the recipient would not know whom to show.
///
/// **A channel does not outlive its socket (CHAT-53).** The channel used to be
/// subscribed once, without a status callback, and then kept for the whole app
/// session. When the WebSocket dropped (iOS backgrounding, a network switch, a
/// server-side Kong restart) nothing rebuilt it, and the indicator stayed dead
/// until the app was killed: reported 2026-10-25, confirmed by "works again
/// after a restart". Same failure the event bus had before #121, fixed the same
/// way: watch the subscribe status, tear the channel down and open a fresh one
/// with capped backoff, and also rebuild whenever the bus reports a re-join
/// ([rebuildAll]), which covers the return from the background.
class TypingIndicatorService {
  TypingIndicatorService(SupabaseClient supabase)
      : _open = ((topic) => _RealtimeTypingTransport(supabase.channel(topic))),
        _close = ((transport) async {
          if (transport is _RealtimeTypingTransport) {
            await supabase.removeChannel(transport.channel);
          }
        }),
        _retryDelayOverride = null;

  /// [_open] makes the transport for a topic, [_close] removes one.
  @visibleForTesting
  TypingIndicatorService.withTransport(
    this._open,
    this._close, {
    Duration Function(int attempt)? retryDelay,
  }) : _retryDelayOverride = retryDelay;

  final TypingTransport Function(String topic) _open;
  final Future<void> Function(TypingTransport transport) _close;
  final Duration Function(int attempt)? _retryDelayOverride;

  final Map<String, _TypingRoom> _rooms = {};
  final Map<String, Timer?> _typingTimers = {};

  // Typing indicator expires after 3 seconds
  static const Duration _typingTimeout = Duration(seconds: 3);

  /// ~1 s, 2 s, 4 s … capped at 30 s, like the event bus.
  Duration _retryDelay(int attempt) =>
      _retryDelayOverride?.call(attempt) ??
      Duration(seconds: min(30, 1 << min(attempt, 5)));

  /// What actually goes over the presence channel.
  ///
  /// A function of its own so a test can pin down that **no** display name
  /// stands here. Whoever adds one in future breaks the test — and that is the
  /// point: an extra field does not stand out when reading the code, but on a
  /// server-visible channel it reveals who is typing.
  @visibleForTesting
  static Map<String, dynamic> presencePayload(String userId, DateTime now) => {
        'user_id': userId,
        'typing': true,
        'timestamp': now.toIso8601String(),
      };

  /// The ids that emerge from the presence states as "currently typing".
  ///
  /// Extracted as well: the freshness check is the place where a stuck
  /// indicator comes from when it goes wrong.
  @visibleForTesting
  static List<String> typingIdsFrom(
    Iterable<Map<String, dynamic>> presences,
    DateTime now,
  ) {
    final ids = <String>[];
    for (final state in presences) {
      if (state['typing'] != true) continue;
      final userId = state['user_id'] as String?;
      final timestamp = state['timestamp'] as String?;
      if (userId == null || timestamp == null) continue;
      final typingTime = DateTime.tryParse(timestamp);
      if (typingTime == null) continue;
      if (now.difference(typingTime) >= _typingTimeout) continue;
      if (!ids.contains(userId)) ids.add(userId);
    }
    return ids;
  }

  /// Subscribe to typing indicators for a chat.
  ///
  /// Supplies the **user ids** of those currently typing — not their names. The
  /// caller adds the display name from their profile data. The stream survives
  /// channel rebuilds; it ends only with [unsubscribe] or [dispose].
  Stream<List<String>> subscribeToTypingIndicators(String chatId) =>
      _roomFor(chatId).updates.stream;

  _TypingRoom _roomFor(String chatId) {
    final existing = _rooms[chatId];
    if (existing != null) return existing;
    final room = _TypingRoom(chatId);
    _rooms[chatId] = room;
    _connect(room);
    return room;
  }

  void _connect(_TypingRoom room) {
    final transport = _open('chat:${room.chatId}:typing');
    room.transport = transport;
    transport.onPresenceSync(() {
      if (room.transport != transport || room.closed) return;
      if (room.updates.isClosed) return;
      room.updates.add(typingIdsFrom(transport.presences(), DateTime.now()));
    });
    transport.subscribe((status, error) {
      // A callback from a channel we already replaced or removed — including
      // the `closed` that removing it fires — is not news.
      if (room.transport != transport || room.closed) return;
      switch (status) {
        case RealtimeSubscribeStatus.subscribed:
          room.attempts = 0;
          logger.info('Typing channel joined for chat ${room.chatId}',
              tag: 'Typing');
        case RealtimeSubscribeStatus.closed:
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.timedOut:
          logger.warning(
            'Typing channel ${status.name} for chat ${room.chatId} '
            '($error) — rebuilding',
            tag: 'Typing',
          );
          _scheduleRebuild(room);
      }
    });
  }

  void _scheduleRebuild(_TypingRoom room) {
    if (room.closed || (room.retry?.isActive ?? false)) return;
    final delay = _retryDelay(room.attempts);
    room.attempts++;
    room.retry = Timer(delay, () {
      room.retry = null;
      unawaited(_rebuild(room));
    });
  }

  Future<void> _rebuild(_TypingRoom room) async {
    if (room.closed) return;
    final old = room.transport;
    // Detach first, so the `closed` that removing it fires is ignored.
    room.transport = null;
    // Whoever was typing on the dead channel is unknown now; a stale "typing"
    // would otherwise stick until the next presence sync.
    if (!room.updates.isClosed) room.updates.add(const []);
    if (old != null) {
      try {
        await _close(old);
      } catch (e) {
        logger.warning('Removing a dead typing channel failed: $e',
            tag: 'Typing');
      }
    }
    if (room.closed) return;
    _connect(room);
  }

  /// Rebuild every open typing channel now. Called when the event bus has
  /// re-joined after a drop or a return from the background: the socket under
  /// all channels was new then, and a typing channel may not have noticed.
  Future<void> rebuildAll() async {
    for (final room in _rooms.values.toList()) {
      room.retry?.cancel();
      room.retry = null;
      room.attempts = 0;
      await _rebuild(room);
    }
  }

  /// Start typing - updates presence to show user is typing.
  ///
  /// No `username` in the payload: the channel name follows from the chat id,
  /// and the server sees what stands here. A display name at this point would
  /// be plaintext beside nothing but encrypted messages.
  Future<void> startTyping({
    required String chatId,
    required String userId,
  }) async {
    try {
      final transport = _roomFor(chatId).transport;
      if (transport == null) return; // mid-rebuild; the next keystroke retries
      await transport.track(presencePayload(userId, DateTime.now()));

      // Cancel any existing timer
      _typingTimers[chatId]?.cancel();

      // Auto-stop typing after timeout
      _typingTimers[chatId] = Timer(_typingTimeout, () {
        stopTyping(chatId: chatId);
      });

      logger.info('Typing started in chat $chatId');
    } catch (e) {
      logger.error('Failed to start typing indicator', error: e);
    }
  }

  /// Stop typing - removes typing status from presence
  Future<void> stopTyping({required String chatId}) async {
    try {
      _typingTimers[chatId]?.cancel();
      _typingTimers[chatId] = null;

      final transport = _rooms[chatId]?.transport;
      if (transport != null) {
        await transport.track({
          'typing': false,
        });
        logger.info('Stopped typing in chat $chatId');
      }
    } catch (e) {
      logger.error('Failed to stop typing indicator', error: e);
    }
  }

  /// Unsubscribe from a chat's typing indicators
  Future<void> unsubscribe(String chatId) async {
    _typingTimers[chatId]?.cancel();
    _typingTimers.remove(chatId);
    final room = _rooms.remove(chatId);
    if (room == null) return;
    await _shut(room);
    logger.info('Unsubscribed from typing indicators for chat $chatId');
  }

  Future<void> _shut(_TypingRoom room) async {
    room.closed = true;
    room.retry?.cancel();
    room.retry = null;
    final transport = room.transport;
    room.transport = null;
    await room.updates.close();
    if (transport != null) {
      try {
        await _close(transport);
      } catch (e) {
        logger.error('Failed to remove typing channel', error: e);
      }
    }
  }

  /// Cleanup all channels
  Future<void> dispose() async {
    for (final timer in _typingTimers.values) {
      timer?.cancel();
    }
    _typingTimers.clear();
    final rooms = _rooms.values.toList();
    _rooms.clear();
    for (final room in rooms) {
      await _shut(room);
    }
  }
}
