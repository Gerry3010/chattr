// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// "Unread messages" divider (#108): the boundary is the earliest INCOMING
// message the current user hasn't read (local readAt is source of truth). Own
// messages and already-read ones never count; list order is irrelevant (the
// rule compares createdAt).

import 'package:chattr/features/chat_view/chat_view_controller.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 15, 9);
  DateTime at(int min) => t0.add(Duration(minutes: min));

  Message m(String id, String sender, DateTime created, {DateTime? myRead}) =>
      Message(
        id: id,
        chatId: 'c',
        senderId: sender,
        recipientId: 'me',
        createdAt: created,
        readAt: {'me': myRead},
        decryptedContent: 'x',
      );

  test('picks the earliest unread incoming message', () {
    final msgs = [
      m('a', 'other', at(0), myRead: t0), // read → skip
      m('b', 'other', at(1)), // unread ← oldest unread
      m('c', 'other', at(2)), // unread (later)
      m('d', 'me', at(3)), // own → skip
    ];
    expect(oldestUnreadIncoming(msgs, 'me')?.id, 'b');
  });

  test('null when everything is read or own', () {
    final msgs = [
      m('a', 'other', at(0), myRead: t0),
      m('b', 'me', at(1)),
    ];
    expect(oldestUnreadIncoming(msgs, 'me'), isNull);
  });

  test('ignores list order — compares createdAt', () {
    final msgs = [
      m('late', 'other', at(5)),
      m('early', 'other', at(1)),
    ];
    expect(oldestUnreadIncoming(msgs, 'me')?.id, 'early');
  });

  test('own unread messages never count', () {
    expect(oldestUnreadIncoming([m('mine', 'me', at(0))], 'me'), isNull);
  });
}
