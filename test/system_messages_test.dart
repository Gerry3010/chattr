// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/messages/message_model.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageType', () {
    test('has user and system types', () {
      expect(MessageType.values.length, 2);
      expect(MessageType.values, contains(MessageType.user));
      expect(MessageType.values, contains(MessageType.system));
    });
  });

  group('Message Model - System Messages', () {
    test('can create system message without sender', () {
      final message = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        encryptedContent: null,
        createdAt: DateTime.now(),
        decryptedContent: 'Alice joined',
      );

      expect(message.id, 'msg-123');
      expect(message.chatId, 'chat-456');
      expect(message.senderId, systemId);
      expect(message.recipientId, 'user-abc');
      expect(message.encryptedContent, null);
      expect(message.messageType, MessageType.system);
      expect(message.decryptedContent, 'Alice joined');
    });

    test('can create user message with all fields', () {
      final message = Message(
        id: 'msg-123',
        chatId: 'chat-456',
        senderId: 'user-789',
        recipientId: 'user-abc',
        encryptedContent: 'encrypted-text',
        messageType: MessageType.user,
        createdAt: DateTime.now(),
        decryptedContent: 'Hello',
      );

      expect(message.senderId, 'user-789');
      expect(message.recipientId, 'user-abc');
      expect(message.encryptedContent, 'encrypted-text');
      expect(message.messageType, MessageType.user);
      expect(message.decryptedContent, 'Hello');
    });

    test('isSystemMessage returns true for system messages', () {
      final message = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        createdAt: DateTime.now(),
        decryptedContent: 'System message',
      );

      expect(message.isSystemMessage, true);
      expect(message.isUserMessage, false);
    });

    test('isUserMessage returns true for user messages', () {
      final message = Message(
        id: 'msg-123',
        chatId: 'chat-456',
        senderId: 'user-789',
        recipientId: 'user-abc',
        messageType: MessageType.user,
        createdAt: DateTime.now(),
      );

      expect(message.isSystemMessage, false);
      expect(message.isUserMessage, true);
    });

    test('defaults to user message type', () {
      final message = Message(
        id: 'msg-123',
        chatId: 'chat-456',
        senderId: 'user-789',
        recipientId: 'user-abc',
        encryptedContent: 'encrypted-text',
        createdAt: DateTime.now(),
      );

      expect(message.messageType, MessageType.user);
    });

    test('serializes system message to JSON correctly', () {
      final now = DateTime.now();
      final message = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        createdAt: now,
        decryptedContent: 'Alice joined',
      );

      final json = message.toJson();

      expect(json['id'], 'msg-123');
      expect(json['chat_id'], 'chat-456');
      expect(json['sender_id'], systemId);
      expect(json['recipient_id'], 'user-abc');
      expect(json['encrypted_content'], null);
      expect(json['message_type'], 'system');
      expect(json['created_at'], now.toIso8601String());
      expect(json['decrypted_content'], 'Alice joined');
    });

    test('serializes user message to JSON correctly', () {
      final now = DateTime.now();
      final message = Message(
        id: 'msg-123',
        chatId: 'chat-456',
        senderId: 'user-789',
        recipientId: 'user-abc',
        encryptedContent: 'encrypted-text',
        messageType: MessageType.user,
        createdAt: now,
        decryptedContent: 'Hello',
      );

      final json = message.toJson();

      expect(json['sender_id'], 'user-789');
      expect(json['recipient_id'], 'user-abc');
      expect(json['encrypted_content'], 'encrypted-text');
      expect(json['message_type'], 'user');
    });

    test('deserializes system message from JSON correctly', () {
      final now = DateTime.now();
      final json = {
        'id': 'msg-123',
        'chat_id': 'chat-456',
        'sender_id': null,
        'recipient_id': 'user-abc',
        'encrypted_content': null,
        'message_type': 'system',
        'created_at': now.toIso8601String(),
        'decrypted_content': 'Bob left the chat',
        'action': 'member_left',
      };

      final message = MessageInterface.fromJson(json);

      expect(message.runtimeType, SystemMessage);
      expect(message.id, 'msg-123');
      expect(message.chatId, 'chat-456');
      expect(message.senderId, systemId);
      expect(message.recipientId, 'user-abc');
      expect(message.encryptedContent, null);
      expect(message.messageType, MessageType.system);
      expect(message.isSystemMessage, true);
      expect(message.decryptedContent, 'Bob left the chat');
      expect((message as SystemMessage).action, 'member_left');
    });

    test('deserializes user message from JSON correctly', () {
      final now = DateTime.now();
      final json = {
        'id': 'msg-123',
        'chat_id': 'chat-456',
        'sender_id': 'user-789',
        'recipient_id': 'user-abc',
        'encrypted_content': 'encrypted-text',
        'message_type': 'user',
        'created_at': now.toIso8601String(),
        'decrypted_content': 'Hello World',
      };

      final message = Message.fromJson(json);

      expect(message.senderId, 'user-789');
      expect(message.recipientId, 'user-abc');
      expect(message.encryptedContent, 'encrypted-text');
      expect(message.messageType, MessageType.user);
      expect(message.isUserMessage, true);
    });

    test('deserializes server row with SCALAR received_at/read_at (regression)',
        () {
      // The server stores one row per recipient, so received_at/read_at come
      // back as scalar timestamp strings — NOT the Map<String,DateTime?> the
      // model uses internally. The json_serializable converter must tolerate
      // this (decode to an empty map) instead of throwing
      // "String is not a subtype of Map". This crashed real message loading
      // until DateTimeMapConverter was made defensive.
      final json = {
        'id': 'msg-123',
        'chat_id': 'chat-456',
        'sender_id': 'user-789',
        'recipient_id': 'user-abc',
        'encrypted_content': '',
        'message_type': 'user',
        'created_at': '2026-06-21T13:58:27.350+00:00',
        'received_at': '2026-06-21T13:58:27.504844+00:00',
        'read_at': '2026-06-21T14:11:49.955834+00:00',
        'updated_at': '2026-06-21T14:11:49.955834+00:00',
      };

      final message = Message.fromJson(json);

      expect(message.recipientId, 'user-abc');
      // Scalar timestamps are not per-recipient maps -> decode to empty.
      expect(message.receivedAt, isEmpty);
      expect(message.readAt, isEmpty);
    });

    test('deserializes MAP received_at/read_at from the local store', () {
      // Round-tripped through the local store, the same fields are real maps.
      final json = {
        'id': 'msg-123',
        'chat_id': 'chat-456',
        'sender_id': 'user-789',
        'recipient_id': 'user-abc',
        'message_type': 'user',
        'created_at': '2026-06-21T13:58:27.350+00:00',
        'received_at': {'user-abc': '2026-06-21T13:58:27.504844+00:00'},
        'read_at': <String, dynamic>{'user-abc': null},
      };

      final message = Message.fromJson(json);

      expect(message.receivedAt['user-abc'], isNotNull);
      expect(message.readAt.containsKey('user-abc'), true);
      expect(message.readAt['user-abc'], isNull);
    });

    test('defaults to user type when message_type is missing', () {
      final now = DateTime.now();
      final json = {
        'id': 'msg-123',
        'chat_id': 'chat-456',
        'sender_id': 'user-789',
        'recipient_id': 'user-abc',
        'encrypted_content': 'encrypted-text',
        'created_at': now.toIso8601String(),
      };

      final message = Message.fromJson(json);

      expect(message.messageType, MessageType.user);
    });

    test('withDecryptedContent preserves message type', () {
      final original = Message(
        id: 'msg-123',
        chatId: 'chat-456',
        senderId: 'user-789',
        recipientId: 'user-abc',
        messageType: MessageType.system,
        createdAt: DateTime.now(),
      );

      final updated = original.withDecryptedContent('New content');

      expect(updated.messageType, MessageType.system);
      expect(updated.decryptedContent, 'New content');
      expect(updated.id, 'msg-123');
      expect(updated.chatId, 'chat-456');
    });

    test('system message can have content in encryptedContent field', () {
      // For system messages, we store plain text in encryptedContent
      // since they don't need encryption
      final message = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        encryptedContent: 'Charlie was promoted to admin',
        createdAt: DateTime.now(),
      );

      expect(message.encryptedContent, 'Charlie was promoted to admin');
      expect(message.isSystemMessage, true);
    });
  });

  group('SystemMessage.formattedText', () {
    test('withDecryptedContent parses the {action,subject_name} JSON', () {
      final message = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        createdAt: DateTime.now(),
      ).withDecryptedContent(
        '{"action":"joined","subject_id":"user-789","subject_name":"Alice"}',
      );

      expect(message.action, 'joined');
      expect(message.subjectId, 'user-789');
      expect(message.subjectName, 'Alice');
      expect(message.formattedText, 'system_messages.member_joined'.tr(args: ['Alice']));
    });

    test(
        'regression: building SystemMessage straight from raw content (no '
        'withDecryptedContent) leaves action null and formattedText falls '
        'back to the raw JSON — the exact bug that made system messages '
        'print as {"action":...} while a chat was open live '
        '(messages_controller.dart _handleDecryptedMessage and '
        'notification_controller.dart both used to do this)', () {
      const raw = '{"action":"joined","subject_id":"user-789","subject_name":"Alice"}';
      final broken = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        createdAt: DateTime.now(),
        decryptedContent: raw, // <- the bug: set directly, action never parsed
      );

      expect(broken.action, isNull);
      expect(broken.formattedText, raw); // falls through to the default case

      // The fix: route the same raw content through withDecryptedContent.
      final fixed = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        createdAt: DateTime.now(),
      ).withDecryptedContent(raw);

      expect(fixed.action, 'joined');
      expect(fixed.formattedText, isNot(raw));
      // Without EasyLocalization loaded in the test, .tr() yields the raw
      // key (see notification_service_test.dart) — assert the correct key
      // is wired, same pattern as that file, rather than the translated text.
      expect(fixed.formattedText, 'system_messages.member_joined'.tr(args: ['Alice']));
    });

    test('formattedText falls back gracefully for an unknown action', () {
      final message = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        createdAt: DateTime.now(),
      ).withDecryptedContent('{"action":"some_future_action","subject_name":"Bob"}');

      // Unknown action -> the default branch, not a crash.
      expect(message.formattedText, isNotEmpty);
    });
  });

  group('Message Model - Edge Cases', () {
    test('round-trip serialization preserves all fields', () {
      final now = DateTime.now();
      final original = Message(
        id: 'msg-123',
        chatId: 'chat-456',
        senderId: 'user-789',
        recipientId: 'user-abc',
        encryptedContent: 'encrypted',
        messageType: MessageType.user,
        createdAt: now,
        decryptedContent: 'decrypted',
      );

      final json = original.toJson();
      final restored = Message.fromJson(json);

      expect(restored.id, original.id);
      expect(restored.chatId, original.chatId);
      expect(restored.senderId, original.senderId);
      expect(restored.recipientId, original.recipientId);
      expect(restored.encryptedContent, original.encryptedContent);
      expect(restored.messageType, original.messageType);
      expect(restored.decryptedContent, original.decryptedContent);
    });

    test('round-trip for system message preserves type', () {
      final now = DateTime.now();
      final original = SystemMessage(
        id: 'msg-123',
        chatId: 'chat-456',
        recipientId: 'user-abc',
        createdAt: now,
        decryptedContent: 'System event',
      );

      final json = original.toJson();
      // Use the polymorphic entry point — Message.fromJson is the user-only
      // concrete factory and rejects system messages by design.
      final restored = MessageInterface.fromJson(json);

      expect(restored.messageType, MessageType.system);
      expect(restored.isSystemMessage, true);
      expect(restored.decryptedContent, 'System event');
    });
  });
}
