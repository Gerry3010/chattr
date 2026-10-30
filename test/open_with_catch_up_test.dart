// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chattr/features/messages/open_with_catch_up.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Chat öffnen ohne auf einen stummen Server zu warten (CHAT-63)', () {
    late List<String> log;
    late Completer<void> server;
    late bool open;

    setUp(() {
      log = [];
      open = true;
    });

    // The completer is made HERE, inside the fake zone: one made in setUp
    // completes into the real microtask queue, which fakeAsync never runs.
    void start(FakeAsync async, {Duration grace = catchUpGrace}) {
      server = Completer<void>();
      unawaited(openWithCatchUp(
        catchUp: () async {
          log.add('catchUp');
          await server.future;
          log.add('catchUp fertig');
        },
        showLocal: () async => log.add('lokal'),
        mounted: () => open,
        grace: grace,
      ));
      async.flushMicrotasks();
    }

    test('Server antwortet rasch: lokal genau einmal, NACH dem Abgleich', () {
      fakeAsync((async) {
        start(async);
        async.elapse(const Duration(milliseconds: 300));
        server.complete();
        async.flushMicrotasks();
        expect(log, ['catchUp', 'catchUp fertig', 'lokal'],
            reason: 'der Trenner braucht die abgeholten Nachrichten '
                'im ersten Stapel');
      });
    });

    test('Server schweigt: lokal nach der Frist, nochmal nach dem Abgleich', () {
      fakeAsync((async) {
        start(async);
        async.elapse(catchUpGrace - const Duration(milliseconds: 1));
        expect(log, ['catchUp'], reason: 'vor der Frist wird noch gewartet');

        async.elapse(const Duration(milliseconds: 1));
        expect(log, ['catchUp', 'lokal'],
            reason: 'nach 1,5 s steht, was das Gerät hat');

        async.elapse(const Duration(seconds: 20));
        server.complete();
        async.flushMicrotasks();
        expect(log, ['catchUp', 'lokal', 'catchUp fertig', 'lokal']);
      });
    });

    test('Gerät weiß, dass es offline ist: lokal sofort', () {
      fakeAsync((async) {
        start(async, grace: Duration.zero);
        async.elapse(Duration.zero);
        expect(log, ['catchUp', 'lokal']);
      });
    });

    test('Chat während des Wartens geschlossen: nichts mehr anfassen', () {
      fakeAsync((async) {
        start(async);
        open = false;
        async.elapse(catchUpGrace);
        server.complete();
        async.flushMicrotasks();
        expect(log, ['catchUp', 'catchUp fertig']);
      });
    });
  });
}
