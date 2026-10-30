// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// `isIncomingMessage` is the whole rule behind the local unread count: it fills
// the indexed `is_incoming` column that the count filters on. Getting it wrong
// is silent — the app keeps working, the badge just lies.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/messages_local_repository.dart';

void main() {
  const me = 'user-me';
  const peer = 'user-peer';
  final now = DateTime.utc(2026, 8, 6, 12);

  Message message(String senderId) => Message(
        id: 'm-$senderId',
        chatId: 'c1',
        senderId: senderId,
        recipientId: me,
        createdAt: now,
      );

  SystemMessage systemMessage() => SystemMessage(
        id: 'sys1',
        chatId: 'c1',
        recipientId: me,
        createdAt: now,
        action: 'joined',
      );

  test('a message from someone else is incoming', () {
    expect(isIncomingMessage(message(peer), me), isTrue);
  });

  test('my own message is not', () {
    expect(isIncomingMessage(message(me), me), isFalse);
  });

  test('a system message counts as incoming — it has no human sender, and the '
      'server-side count included system rows too', () {
    final sys = systemMessage();
    expect(sys.senderId, systemId);
    expect(isIncomingMessage(sys, me), isTrue);
  });

  group('without a signed-in user we err towards NOT incoming', () {
    // A wrong `false` costs a badge that should have shown. A wrong `true`
    // invents unread messages — including, at sign-out, every message the user
    // ever sent themselves.
    test('null user id', () {
      expect(isIncomingMessage(message(peer), null), isFalse);
      expect(isIncomingMessage(message(me), null), isFalse);
    });

    test('empty user id', () {
      expect(isIncomingMessage(message(peer), ''), isFalse);
    });
  });
}
