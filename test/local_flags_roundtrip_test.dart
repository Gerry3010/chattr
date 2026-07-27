// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// 1.8: the local-only pin (Chat.isPinned, #3) and favorite (Message.isFavorite,
// #4) flags must round-trip through the encrypted local JSON blob, and default
// to false for pre-1.8 data (and server data) that lacks the key.

import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Chat.isPinned round-trip (#3)', () {
    test('true survives toJson → fromJson', () {
      final c = Chat(
        id: 'c1',
        createdAt: DateTime.utc(2026, 1, 1),
        isPinned: true,
      );
      expect(Chat.fromJson(c.toJson()).isPinned, isTrue);
    });

    test('defaults to false when the key is absent (server / pre-1.8 data)', () {
      final json = {
        'id': 'c2',
        'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        // no is_pinned
      };
      expect(Chat.fromJson(json).isPinned, isFalse);
    });

    test('copyWith toggles the flag', () {
      final c = Chat(id: 'c3', createdAt: DateTime.utc(2026, 1, 1));
      expect(c.isPinned, isFalse);
      expect(c.copyWith(isPinned: true).isPinned, isTrue);
    });
  });

  group('Chat.avatarPath round-trip (group avatars #55)', () {
    test('survives toJson → fromJson', () {
      final c = Chat(
        id: 'g1',
        createdAt: DateTime.utc(2026, 1, 1),
        avatarPath: 'g1/avatar.jpg',
      );
      expect(Chat.fromJson(c.toJson()).avatarPath, 'g1/avatar.jpg');
    });

    test('defaults to null when the key is absent (pre-#55 data)', () {
      final json = {
        'id': 'g2',
        'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        // no avatar_path
      };
      expect(Chat.fromJson(json).avatarPath, isNull);
    });

    test('copyWith sets and clearAvatar clears', () {
      final c = Chat(id: 'g3', createdAt: DateTime.utc(2026, 1, 1));
      expect(c.avatarPath, isNull);
      final withAvatar = c.copyWith(avatarPath: 'g3/avatar.png');
      expect(withAvatar.avatarPath, 'g3/avatar.png');
      expect(withAvatar.copyWith(clearAvatar: true).avatarPath, isNull);
    });
  });

  group('Message.isFavorite round-trip (#4)', () {
    Message msg({bool isFavorite = false}) => Message(
          id: 'm1',
          chatId: 'c1',
          senderId: 'u1',
          recipientId: 'u2',
          createdAt: DateTime.utc(2026, 1, 1),
          isFavorite: isFavorite,
        );

    test('true survives toJson → fromJson', () {
      final m = msg(isFavorite: true);
      expect(Message.fromJson(m.toJson()).isFavorite, isTrue);
    });

    test('defaults to false when the key is absent (pre-1.8 data)', () {
      final json = {
        'id': 'm2',
        'chat_id': 'c1',
        'sender_id': 'u1',
        'recipient_id': 'u2',
        'message_type': 'user',
        'created_at': DateTime.utc(2026, 1, 1).toIso8601String(),
        // no is_favorite
      };
      expect(Message.fromJson(json).isFavorite, isFalse);
    });

    test('copyWith toggles the flag', () {
      final m = msg();
      expect(m.isFavorite, isFalse);
      expect(m.copyWith(isFavorite: true).isFavorite, isTrue);
    });
  });
}
