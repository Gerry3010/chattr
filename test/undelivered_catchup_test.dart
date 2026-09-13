// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Messages that arrived while the app was closed (1.22.1).
//
// Since the unread counter became local (1.15.0) the device counts what it HAS
// — but nothing fetched messages for chats the user does not open. Demonstrated
// on the server: a message from 15:40 with `received_at IS NULL`, while the
// read mark stood at 15:22. It could never reach the counter, and on opening
// the chat the mark moved past it in the same move.
//
// What is tested is the conversion of server rows into events — the part that
// is checkable without a network and without keys.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/events/event_types.dart' show NewMessageEvent;
import 'package:chattr/features/messages/global_message_handler.dart';
import 'package:chattr/features/messages/message_model.dart';

Message _message({
  String? encrypted = 'ciphertext',
  String? replyTo,
  String? replyPreview,
}) =>
    Message(
      id: 'm1',
      chatId: 'c1',
      senderId: 'other',
      recipientId: 'me',
      createdAt: DateTime.utc(2026, 8, 13, 15, 40),
      encryptedContent: encrypted,
      replyToMessageId: replyTo,
      replyToPreview: replyPreview,
    );

void main() {
  group('translating stragglers into events', () {
    test('an ordinary message becomes a newMessage event', () {
      final event = catchUpEventFor(_message())!;

      expect(event.chatId, 'c1');
      expect(event.messageId, 'm1');
      expect(event.senderId, 'other');
      expect(event.content, 'ciphertext');
      expect(event.messageType, MessageType.user);
      // The timestamp has to be the server's, not "now" — otherwise a caught-up
      // message sorts to the end of the history.
      expect(event.timestamp, DateTime.utc(2026, 8, 13, 15, 40));
      // A straggler is NOT processed: otherwise handleNewMessage bails out
      // again immediately.
      expect(event.processed, isFalse);
      expect(event.decrypted, isFalse);
    });

    test('the reply metadata travels along', () {
      // Without it a caught-up reply would lose its quote forever — the server
      // deletes the ciphertext as soon as it counts as received.
      final event = catchUpEventFor(
        _message(replyTo: 'm0', replyPreview: 'ciphertext-preview'),
      )!;

      expect(event.replyToMessageId, 'm0');
      expect(event.replyToPreview, 'ciphertext-preview');
    });

    test('a system message comes without a sender', () {
      // handleNewMessage entscheidet genau daran, ob es eine SystemMessage
      // baut.
      final system = SystemMessage(
        id: 's1',
        chatId: 'c1',
        recipientId: 'me',
        createdAt: DateTime.utc(2026, 8, 13),
        encryptedContent: 'ciphertext',
      );

      final event = catchUpEventFor(system)!;

      expect(event.senderId, isNull);
      expect(event.messageType, MessageType.system);
    });

    test('an already cleared row is skipped', () {
      // `mark_message_received` sets the ciphertext to '' — nothing can be
      // decrypted from that any more, and an event for it would be mere noise.
      expect(catchUpEventFor(_message(encrypted: '')), isNull);
      expect(catchUpEventFor(_message(encrypted: null)), isNull);
    });
  });
}
