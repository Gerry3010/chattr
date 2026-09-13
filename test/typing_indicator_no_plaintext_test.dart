// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Roadmap, block "finish privacy": the typing indicator should manage without
// plaintext usernames.
//
// The presence payload carried `username` until now. The channel is called
// `chat:<chatId>:typing` — so its name follows from the chat id, and the server
// sees what stands on it. That meant it stated in the clear WHO is typing,
// while every message in the same chat is encrypted.
//
// The most important test here is the first: it pins down that no name stands
// in the payload. Whoever adds one in future breaks it — and that is exactly
// what is needed, because an extra field does not stand out when reading the
// code.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/typing_indicator/typing_indicator_service.dart';

void main() {
  final now = DateTime.utc(2026, 8, 8, 3);

  group('what is sent', () {
    test('the payload contains NO display name', () {
      final p = TypingIndicatorService.presencePayload('user-1', now);
      expect(p.containsKey('username'), isFalse);
      // Nothing name-like on another key either.
      expect(
        p.values.whereType<String>(),
        isNot(contains(matches(RegExp(r'^[A-ZÄÖÜ][a-zäöüß]+')))),
        reason: 'nothing that looks like a display name',
      );
    });

    test('it contains exactly what is needed: id, state, time', () {
      final p = TypingIndicatorService.presencePayload('user-1', now);
      expect(p.keys.toSet(), {'user_id', 'typing', 'timestamp'});
      expect(p['user_id'], 'user-1');
      expect(p['typing'], isTrue);
      expect(DateTime.parse(p['timestamp'] as String), now);
    });
  });

  group('what is read out of it', () {
    Map<String, dynamic> tippt(String id, DateTime seit) => {
          'user_id': id,
          'typing': true,
          'timestamp': seit.toIso8601String(),
        };

    test('fresh entries count', () {
      final ids = TypingIndicatorService.typingIdsFrom(
        [tippt('a', now.subtract(const Duration(seconds: 1)))],
        now,
      );
      expect(ids, ['a']);
    });

    test('expired entries do not count — otherwise the indicator would stick',
        () {
      final ids = TypingIndicatorService.typingIdsFrom(
        [tippt('a', now.subtract(const Duration(seconds: 4)))],
        now,
      );
      expect(ids, isEmpty);
    });

    test('exactly at the limit (3 s) counts as expired', () {
      final ids = TypingIndicatorService.typingIdsFrom(
        [tippt('a', now.subtract(const Duration(seconds: 3)))],
        now,
      );
      expect(ids, isEmpty);
    });

    test('typing:false is passed over', () {
      final ids = TypingIndicatorService.typingIdsFrom(
        [
          {'user_id': 'a', 'typing': false, 'timestamp': now.toIso8601String()}
        ],
        now,
      );
      expect(ids, isEmpty);
    });

    test('the same user on two devices appears only once', () {
      // Otherwise the header would read "Sebi and Sebi are typing".
      final ids = TypingIndicatorService.typingIdsFrom(
        [
          tippt('a', now.subtract(const Duration(seconds: 1))),
          tippt('a', now.subtract(const Duration(seconds: 2))),
        ],
        now,
      );
      expect(ids, ['a']);
    });

    test('several people typing keep their order', () {
      final ids = TypingIndicatorService.typingIdsFrom(
        [
          tippt('a', now.subtract(const Duration(seconds: 1))),
          tippt('b', now.subtract(const Duration(seconds: 1))),
        ],
        now,
      );
      expect(ids, ['a', 'b']);
    });

    test('broken entries do not throw, they drop out', () {
      final ids = TypingIndicatorService.typingIdsFrom(
        [
          {'typing': true, 'timestamp': now.toIso8601String()}, // ohne Id
          {'user_id': 'b', 'typing': true}, // ohne Zeit
          {'user_id': 'c', 'typing': true, 'timestamp': 'kein Datum'},
          const <String, dynamic>{},
        ],
        now,
      );
      expect(ids, isEmpty);
    });

    test('what is read are ids, not names', () {
      // The counter-check to the rework: what comes out is the id — the display
      // name only arises at the recipient.
      final ids = TypingIndicatorService.typingIdsFrom(
        [tippt('4f6dbce8-453f-47bf-b625-4868be77388f', now)],
        now,
      );
      expect(ids.single, '4f6dbce8-453f-47bf-b625-4868be77388f');
    });
  });
}
