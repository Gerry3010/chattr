// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/events/event_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BusEvent.fromJson dispatch', () {
    test('parses a reactionChanged event from the server payload', () {
      final event = BusEvent.fromJson({
        'type': 'reactionChanged',
        'chat_id': 'chat-1',
        'message_id': 'msg-1',
        'user_id': 'user-1',
        'reaction': '👍',
        'action': 'added',
        'timestamp': '2026-06-21T10:00:00.000Z',
      });

      expect(event, isA<ReactionChangedEvent>());
      final r = event as ReactionChangedEvent;
      expect(r.type, EventType.reactionChanged);
      expect(r.chatId, 'chat-1');
      expect(r.messageId, 'msg-1');
      expect(r.userId, 'user-1');
      expect(r.reaction, '👍');
      expect(r.isAdded, isTrue);
    });

    test('parses a memberKeyRegistered event from the server payload (#116)', () {
      final event = BusEvent.fromJson({
        'type': 'memberKeyRegistered',
        'chat_id': 'chat-1',
        'user_id': 'peer-1',
        'timestamp': '2026-07-18T10:00:00.000Z',
      });

      expect(event, isA<MemberKeyRegisteredEvent>());
      final e = event as MemberKeyRegisteredEvent;
      expect(e.type, EventType.memberKeyRegistered);
      expect(e.chatId, 'chat-1');
      expect(e.userId, 'peer-1');
    });

    test('parses a profileChanged (deleted) event with null username', () {
      final event = BusEvent.fromJson({
        'type': 'profileChanged',
        'user_id': 'user-9',
        'username': null,
        'action': 'deleted',
      });

      expect(event, isA<ProfileChangedEvent>());
      final p = event as ProfileChangedEvent;
      expect(p.userId, 'user-9');
      expect(p.username, isNull);
      expect(p.isDeleted, isTrue);
    });

    test('throws on an unknown event type', () {
      expect(
        () => BusEvent.fromJson({'type': 'totallyUnknown'}),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('round-trip toJson -> fromJson', () {
    test('ReactionChangedEvent', () {
      final original = ReactionChangedEvent(
        chatId: 'c',
        messageId: 'm',
        userId: 'u',
        reaction: '🎉',
        action: 'removed',
      );
      final restored =
          BusEvent.fromJson(original.toJson()) as ReactionChangedEvent;
      expect(restored.reaction, '🎉');
      expect(restored.action, 'removed');
      expect(restored.isAdded, isFalse);
    });

    test('MemberKeyRegisteredEvent', () {
      final original = MemberKeyRegisteredEvent(
        chatId: 'chat-9',
        userId: 'peer-9',
        timestamp: DateTime.parse('2026-07-18T12:00:00.000Z'),
      );
      final restored =
          BusEvent.fromJson(original.toJson()) as MemberKeyRegisteredEvent;
      expect(restored.chatId, 'chat-9');
      expect(restored.userId, 'peer-9');
      expect(restored.type, EventType.memberKeyRegistered);
    });

    test('ProfileChangedEvent', () {
      final original = ProfileChangedEvent(
        userId: 'u',
        username: 'alice',
        action: 'updated',
      );
      final restored =
          BusEvent.fromJson(original.toJson()) as ProfileChangedEvent;
      expect(restored.username, 'alice');
      expect(restored.action, 'updated');
      expect(restored.isDeleted, isFalse);
    });

    test('NewMessageEvent carries reply metadata (00029 payload)', () {
      final event = BusEvent.fromJson({
        'type': 'newMessage',
        'chat_id': 'chat-1',
        'message_id': 'msg-2',
        'sender_id': 'user-1',
        'content': 'cipher',
        'message_type': 'user',
        'reply_to_message_id': 'msg-1',
        'reply_to_sender_id': 'user-2',
        'reply_to_sender_name': 'bob',
        'reply_to_preview': 'cipher-preview',
        'timestamp': '2026-07-11T10:00:00.000Z',
      }) as NewMessageEvent;

      expect(event.replyToMessageId, 'msg-1');
      expect(event.replyToSenderId, 'user-2');
      expect(event.replyToSenderName, 'bob');
      expect(event.replyToPreview, 'cipher-preview');

      // Round-trips through toJson (the persistence/replay path).
      final restored = BusEvent.fromJson(event.toJson()) as NewMessageEvent;
      expect(restored.replyToMessageId, 'msg-1');
      expect(restored.replyToPreview, 'cipher-preview');

      // copyWith with the decrypted-preview convention ('' = not decryptable).
      final decrypted =
          event.copyWith(decrypted: true, content: 'plain', replyToPreview: '');
      expect(decrypted.replyToPreview, isEmpty);
      expect(decrypted.replyToSenderName, 'bob');
    });

    test('NewMessageEvent without reply metadata (pre-00029 payload)', () {
      final event = BusEvent.fromJson({
        'type': 'newMessage',
        'chat_id': 'chat-1',
        'message_id': 'msg-3',
        'sender_id': 'user-1',
        'content': 'cipher',
        'message_type': 'user',
      }) as NewMessageEvent;

      expect(event.replyToMessageId, isNull);
      expect(event.replyToPreview, isNull);
    });
  });
}
