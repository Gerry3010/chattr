// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatview/chatview.dart' as chatview;
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/message_reaction_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReactionSummary.userIds', () {
    test('parses user_ids from the RPC payload', () {
      final summary = ReactionSummary.fromJson(const {
        'reaction': '👍',
        'count': 2,
        'user_reacted': true,
        'user_ids': ['user-a', 'user-b'],
      });
      expect(summary.userIds, ['user-a', 'user-b']);
    });

    test('defaults to empty for pre-00035 payloads without user_ids', () {
      final summary = ReactionSummary.fromJson(const {
        'reaction': '👍',
        'count': 2,
        'user_reacted': false,
      });
      expect(summary.userIds, isEmpty);
    });
  });

  group('toChatViewMessage reaction lists', () {
    Message buildMessage() => Message(
          id: 'm1',
          chatId: 'c1',
          senderId: 'user-a',
          recipientId: 'user-b',
          createdAt: DateTime.utc(2026, 7, 12),
          decryptedContent: 'hi',
        );

    test('reactions and reactedUserIds stay parallel', () {
      // chatview pairs reactions[i] with reactedUserIds[i] in its
      // "who reacted" sheet — the lists must have equal length.
      final msg = buildMessage().toChatViewMessage(reactions: [
        chatview.Reaction(
          reactions: ['👍', '👍'],
          reactedUserIds: ['user-a', 'user-b'],
        ),
        chatview.Reaction(
          reactions: ['❤️'],
          reactedUserIds: ['user-c'],
        ),
      ]);

      expect(msg.reaction, isNotNull);
      expect(msg.reaction!.reactions, ['👍', '👍', '❤️']);
      expect(msg.reaction!.reactedUserIds, ['user-a', 'user-b', 'user-c']);
      expect(
        msg.reaction!.reactions.length,
        msg.reaction!.reactedUserIds.length,
      );
    });

    test('no reactions → empty Reaction lists', () {
      // chatview.Message normalizes a null reaction to an empty Reaction.
      final msg = buildMessage().toChatViewMessage(reactions: []);
      expect(msg.reaction.reactions, isEmpty);
      expect(msg.reaction.reactedUserIds, isEmpty);
    });
  });
}
