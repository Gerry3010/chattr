// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The wire format of an invitation message (`_chattr_invite`).
///
/// An admin shares a group INTO another chat as an ordinary E2E-encrypted
/// message whose body is this envelope; the recipients see a card and a tap
/// joins them without any further approval (`redeem_chat_invite`, migration
/// 00069). The server never sees the group name — it stores only the token's
/// checkable state (scope, revocation) in `chat_invites`.
///
/// The card is CONVERSATION, not machinery: unlike summary envelopes it
/// counts as unread, pushes, and lives in history like any other message.
library;

import 'dart:convert';

class InviteEnvelope {
  static const String marker = '_chattr_invite';

  /// The invited-into group.
  final String chatId;

  /// Display name at send time (RLS hides `chats.name` from non-members, so
  /// the card must carry it — it may go stale if the group renames; fine).
  final String chatName;

  /// The redeem token. Worthless outside the chat this message was sent to:
  /// `redeem_chat_invite` requires membership in that target chat.
  final String token;

  const InviteEnvelope({
    required this.chatId,
    required this.chatName,
    required this.token,
  });

  String encode() => jsonEncode({
        marker: 1,
        'chat_id': chatId,
        'chat_name': chatName,
        'token': token,
      });

  static InviteEnvelope? tryParse(String? body) {
    if (body == null || body.isEmpty || !body.contains(marker)) return null;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json[marker] == null) return null;
      final chatId = json['chat_id'];
      final chatName = json['chat_name'];
      final token = json['token'];
      if (chatId is! String || chatName is! String || token is! String) {
        return null;
      }
      return InviteEnvelope(chatId: chatId, chatName: chatName, token: token);
    } catch (_) {
      return null;
    }
  }
}
