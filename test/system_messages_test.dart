// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chattr/features/messages/message_model.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('00064 does not re-open the system-message forgery hole (H4)', () {
    // insert_system_message is SECURITY DEFINER and performs RLS-bypassing
    // inserts; 00045 revoked EXECUTE from anon/authenticated so a normal JWT
    // cannot forge "system" messages. 00064 DROPs and re-CREATEs it to add the
    // `detail` argument — and a freshly created function is EXECUTE-able by
    // PUBLIC again by default. Losing that one REVOKE line is silent and
    // undetectable from the app, so it is asserted here.
    final sql =
        File('supabase/migrations/00064_ttl_system_messages.sql').readAsStringSync();

    test('re-applies the REVOKE for the new 5-argument signature', () {
      expect(sql, contains('DROP FUNCTION IF EXISTS public.insert_system_message'));
      expect(
        sql.replaceAll(RegExp(r'\s+'), ' '),
        contains(
          'REVOKE EXECUTE ON FUNCTION '
          'public.insert_system_message(uuid, text, uuid, text, text) '
          'FROM PUBLIC, anon, authenticated, service_role;',
        ),
      );
    });

    test('the trigger only announces a TTL that actually changed', () {
      // UPDATE OF fires on any write to the column, including a no-op re-save
      // of the same value — without this guard every unrelated settings save
      // would spam the chat.
      expect(
        sql,
        contains(
          'NEW.message_ttl_seconds IS NOT DISTINCT FROM OLD.message_ttl_seconds',
        ),
      );
    });
  });

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
      // ...and specifically NOT the raw payload. The old default returned
      // decryptedContent, which for a parsed JSON action is the stringified
      // map — a user staring at `{action: some_future_action, …}` in the
      // middle of their chat.
      expect(message.formattedText, isNot(contains('some_future_action')));
    });
  });

  group('SystemMessage: disappearing-messages announcements (00064)', () {
    SystemMessage decode(String json) => SystemMessage(
          id: 'msg-1',
          chatId: 'chat-1',
          recipientId: 'user-1',
          createdAt: DateTime.now(),
        ).withDecryptedContent(json);

    test('ttl_enabled carries the duration as raw seconds in `detail`', () {
      final m = decode(
        '{"action":"ttl_enabled","subject_id":"u-1",'
        '"subject_name":"Gerry","detail":"300"}',
      );

      expect(m.action, 'ttl_enabled');
      expect(m.detail, '300');
      // Raw seconds, NOT a rendered string — each device formats it in its
      // own locale, so the sender's language never leaks into the chat.
      expect(m.formattedText, startsWith('system_messages.ttl_enabled'));
      expect(m.state, SystemMessageState.success);
    });

    test('a numeric (non-string) detail survives — jsonb sends it unquoted',
        () {
      final m = decode(
        '{"action":"ttl_enabled","subject_name":"Gerry","detail":300}',
      );

      expect(m.detail, '300');
      expect(m.formattedText, startsWith('system_messages.ttl_enabled'));
    });

    test('ttl_enabled without a usable detail still reads sensibly', () {
      final m = decode('{"action":"ttl_enabled","subject_name":"Gerry"}');

      expect(m.detail, isNull);
      expect(m.formattedText, 'system_messages.ttl_enabled_unknown'.tr(args: ['Gerry']));
      expect(m.state, SystemMessageState.success);
    });

    test('ttl_disabled warns — protection was switched back off', () {
      final m = decode('{"action":"ttl_disabled","subject_name":"Gerry"}');

      expect(m.formattedText, 'system_messages.ttl_disabled'.tr(args: ['Gerry']));
      expect(m.state, SystemMessageState.warning);
    });

    test('adding `detail` does not disturb the existing actions', () {
      final m = decode(
        '{"action":"joined","subject_id":"u-1","subject_name":"Alice"}',
      );

      expect(m.detail, isNull);
      expect(m.formattedText, 'system_messages.member_joined'.tr(args: ['Alice']));
    });
  });

  group('SystemMessage.state', () {
    SystemMessage withAction(String action) => SystemMessage(
          id: 'msg-1',
          chatId: 'chat-1',
          recipientId: 'user-1',
          createdAt: DateTime.now(),
        ).withDecryptedContent('{"action":"$action","subject_name":"Alice"}');

    test('gaining access is success, losing it is a warning', () {
      expect(withAction('joined').state, SystemMessageState.success);
      expect(withAction('approved').state, SystemMessageState.success);
      expect(withAction('removed').state, SystemMessageState.warning);
    });

    test('a key rotation warns — it is the one you must verify out of band',
        () {
      expect(withAction('keys_rotated').state, SystemMessageState.warning);
    });

    test('routine bookkeeping stays neutral', () {
      expect(withAction('left').state, SystemMessageState.info);
      expect(withAction('promoted').state, SystemMessageState.info);
      expect(withAction('chat_created').state, SystemMessageState.info);
    });

    test('an unknown future action degrades to info, never to error', () {
      expect(withAction('some_future_action').state, SystemMessageState.info);
    });

    test('a system message that never decrypted is an error', () {
      final undecrypted = SystemMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        recipientId: 'user-1',
        createdAt: DateTime.now(),
        encryptedContent: 'gibberish',
      );

      expect(undecrypted.state, SystemMessageState.error);
      expect(undecrypted.formattedText, 'system_messages.undecryptable'.tr());
    });

    test('a legacy plain-text system message is info, not an error', () {
      final legacy = SystemMessage(
        id: 'msg-1',
        chatId: 'chat-1',
        recipientId: 'user-1',
        createdAt: DateTime.now(),
        decryptedContent: 'Alice joined',
      );

      expect(legacy.state, SystemMessageState.info);
      expect(legacy.formattedText, 'Alice joined');
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
