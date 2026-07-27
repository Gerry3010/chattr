// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:freezed_annotation/freezed_annotation.dart';

part 'pending_chat_member_model.freezed.dart';
part 'pending_chat_member_model.g.dart';

@freezed
abstract class PendingChatMember with _$PendingChatMember {
  const PendingChatMember._();

  const factory PendingChatMember({
    @JsonKey(name: 'chat_id') required String chatId,
    @JsonKey(name: 'user_id') required String userId,
    @JsonKey(name: 'public_key') required String publicKey,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
    @JsonKey(name: 'blocked_at') DateTime? blockedAt,
  }) = _PendingChatMember;

  factory PendingChatMember.fromJson(Map<String, dynamic> json) =>
      _$PendingChatMemberFromJson(json);

  bool get isBlocked => blockedAt != null;
}

/// One of the current user's OWN outstanding join requests, enriched with the
/// group name that plain RLS would hide from a not-yet-member. Produced by the
/// `get_my_pending_requests()` RPC (see migration 00043) and shown in the
/// pending-requests overview's "my requests" section (Task #102).
typedef MyPendingRequest = ({
  String chatId,
  String? chatName,
  bool isGroup,
  DateTime createdAt,
  DateTime? blockedAt,
});

/// Parse one `get_my_pending_requests()` row into a [MyPendingRequest].
MyPendingRequest myPendingRequestFromRow(Map<String, dynamic> row) => (
      chatId: row['chat_id'] as String,
      chatName: row['chat_name'] as String?,
      isGroup: (row['is_group'] as bool?) ?? true,
      createdAt: DateTime.parse(row['created_at'] as String),
      blockedAt: row['blocked_at'] == null
          ? null
          : DateTime.parse(row['blocked_at'] as String),
    );

extension MyPendingRequestX on MyPendingRequest {
  bool get isBlocked => blockedAt != null;
}

