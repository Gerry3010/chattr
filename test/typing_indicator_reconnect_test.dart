// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-53: the typing channel was subscribed once and kept for the whole app
// session. After a WebSocket drop (iOS backgrounding, a network switch, a Kong
// restart on the server) nothing rebuilt it, and the indicator stayed dead
// until the app was killed. These tests pin down the rebuild.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chattr/features/typing_indicator/typing_indicator_service.dart';

class FakeTransport implements TypingTransport {
  FakeTransport(this.topic);

  final String topic;
  void Function()? sync;
  void Function(RealtimeSubscribeStatus, Object?)? status;
  List<Map<String, dynamic>> current = [];
  final tracked = <Map<String, dynamic>>[];
  bool removed = false;

  @override
  void onPresenceSync(void Function() callback) => sync = callback;

  @override
  List<Map<String, dynamic>> presences() => current;

  @override
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  ) =>
      status = callback;

  @override
  Future<void> track(Map<String, dynamic> payload) async =>
      tracked.add(payload);

  void typingBy(String userId) {
    current = [TypingIndicatorService.presencePayload(userId, DateTime.now())];
    sync!();
  }
}

Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late List<FakeTransport> opened;
  late TypingIndicatorService service;

  setUp(() {
    opened = [];
    service = TypingIndicatorService.withTransport(
      (topic) {
        final t = FakeTransport(topic);
        opened.add(t);
        return t;
      },
      (transport) async {
        final t = transport as FakeTransport;
        t.removed = true;
        // Removing a channel fires its own `closed`. That must not start yet
        // another rebuild.
        t.status?.call(RealtimeSubscribeStatus.closed, null);
      },
      retryDelay: (_) => Duration.zero,
    );
  });

  tearDown(() => service.dispose());

  test('ein Abbruch baut den Kanal neu auf, der Stream bleibt derselbe',
      () async {
    final seen = <List<String>>[];
    service.subscribeToTypingIndicators('chat-1').listen(seen.add);

    expect(opened, hasLength(1));
    expect(opened.first.topic, 'chat:chat-1:typing');
    opened.first.status!(RealtimeSubscribeStatus.subscribed, null);
    opened.first.typingBy('bob');
    await settle();
    expect(seen.last, ['bob']);

    // The socket drops under the channel.
    opened.first.status!(RealtimeSubscribeStatus.closed, null);
    await settle();

    expect(opened, hasLength(2), reason: 'genau ein neuer Kanal');
    expect(opened.first.removed, isTrue);
    expect(seen.last, isEmpty,
        reason: 'wer auf dem toten Kanal tippte, ist unbekannt');

    opened[1].status!(RealtimeSubscribeStatus.subscribed, null);
    opened[1].typingBy('bob');
    await settle();
    expect(seen.last, ['bob'], reason: 'der neue Kanal speist denselben Stream');
  });

  test('channelError und timedOut bauen ebenfalls neu auf', () async {
    service.subscribeToTypingIndicators('chat-1').listen((_) {});
    opened.last.status!(RealtimeSubscribeStatus.channelError, 'boom');
    await settle();
    expect(opened, hasLength(2));
    opened.last.status!(RealtimeSubscribeStatus.timedOut, null);
    await settle();
    expect(opened, hasLength(3));
  });

  test('ein alter Kanal kann nach dem Ersetzen nichts mehr auslösen',
      () async {
    final seen = <List<String>>[];
    service.subscribeToTypingIndicators('chat-1').listen(seen.add);
    final first = opened.first;
    first.status!(RealtimeSubscribeStatus.closed, null);
    await settle();
    expect(opened, hasLength(2));

    first.status!(RealtimeSubscribeStatus.closed, null);
    first.typingBy('ghost');
    await settle();
    expect(opened, hasLength(2), reason: 'kein Neuaufbau durch Alt-Rückrufe');
    expect(seen.where((ids) => ids.contains('ghost')), isEmpty);
  });

  test('rebuildAll (Bus wieder verbunden) erneuert jeden offenen Kanal',
      () async {
    service.subscribeToTypingIndicators('chat-1').listen((_) {});
    service.subscribeToTypingIndicators('chat-2').listen((_) {});
    expect(opened, hasLength(2));

    await service.rebuildAll();

    expect(opened, hasLength(4));
    expect(opened.take(2).every((t) => t.removed), isTrue);
    expect(opened.skip(2).map((t) => t.topic),
        ['chat:chat-1:typing', 'chat:chat-2:typing']);
  });

  test('Tippen nach dem Neuaufbau geht über den neuen Kanal', () async {
    service.subscribeToTypingIndicators('chat-1').listen((_) {});
    opened.first.status!(RealtimeSubscribeStatus.closed, null);
    await settle();

    await service.startTyping(chatId: 'chat-1', userId: 'me');
    expect(opened.first.tracked, isEmpty);
    expect(opened.last.tracked.single['user_id'], 'me');
  });

  test('nach unsubscribe kein Neuaufbau, Stream ist zu', () async {
    var done = false;
    service
        .subscribeToTypingIndicators('chat-1')
        .listen((_) {}, onDone: () => done = true);
    final first = opened.first;

    await service.unsubscribe('chat-1');
    await settle();

    expect(first.removed, isTrue);
    expect(done, isTrue);
    first.status!(RealtimeSubscribeStatus.closed, null);
    await settle();
    expect(opened, hasLength(1));
  });
}
