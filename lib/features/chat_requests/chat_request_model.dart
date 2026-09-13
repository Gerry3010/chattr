// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

/// An open request TO me, from `my_incoming_chat_requests()` (00082).
///
/// Name, picture and identity key come from the RPC itself and not via
/// `profileProvider`: as long as it has not been accepted we share no chat, and
/// the profile view (00046) deliberately does not hand out a stranger's
/// profile. Whoever reaches for the profile cache here gets an empty profile
/// and wonders why — so the fields are in the row.
typedef IncomingChatRequest = ({
  String requesterId,
  String username,
  String? avatarPath,
  String? identityPublicKey,
  DateTime createdAt,
});

IncomingChatRequest incomingChatRequestFromRow(Map<String, dynamic> row) => (
      requesterId: row['requester_id'] as String,
      username: (row['username'] as String?) ?? '',
      avatarPath: row['avatar_path'] as String?,
      identityPublicKey: row['identity_public_key'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );

/// A request I have sent, from `my_outgoing_chat_requests()`.
///
/// [state] knows only `pending` and `accepted`. A rejection looks like an open
/// request — that is decided (2026-08-24) and not a gap: the rejected party
/// should not know they were rejected, because otherwise they look for another
/// way.
typedef OutgoingChatRequest = ({
  String targetId,
  String state,
  String? chatId,
  DateTime createdAt,
});

OutgoingChatRequest outgoingChatRequestFromRow(Map<String, dynamic> row) => (
      targetId: row['target_id'] as String,
      state: (row['state'] as String?) ?? 'pending',
      chatId: row['chat_id'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );

extension OutgoingChatRequestX on OutgoingChatRequest {
  bool get isAccepted => state == 'accepted';
}

/// What the action row offers for a person — in a group member's profile sheet,
/// on the person screen and after a QR scan.
enum ChatRequestState {
  /// We already have a 1:1 chat → open it.
  chatExists,

  /// The person has requested ME → accept (or reject).
  incoming,

  /// I have requested and am waiting → withdraw.
  outgoing,

  /// Nichts liegt an → anfragen.
  none,

  /// Ich selbst.
  self,
}

/// The state along with the chat id, where there is one.
typedef ChatRequestStatus = ({ChatRequestState state, String? chatId});

/// Deliberately a pure function: this very branching decides whether somebody
/// sees "send request" or "open chat", and hiding it in a widget would mean not
/// being able to test it.
///
/// The order is not arbitrary. An existing chat ALWAYS wins, even when a
/// request row still lies beside it — otherwise the app would offer to request
/// somebody one has long been writing with (for instance when both requested
/// each other in the same moment and the server made a chat out of it).
ChatRequestStatus chatRequestStatusFor({
  required String peerId,
  required String? myId,
  required String? existingChatId,
  required Iterable<IncomingChatRequest> incoming,
  required Iterable<OutgoingChatRequest> outgoing,
}) {
  if (myId != null && peerId == myId) {
    return (state: ChatRequestState.self, chatId: null);
  }
  if (existingChatId != null) {
    return (state: ChatRequestState.chatExists, chatId: existingChatId);
  }
  final accepted = outgoing
      .where((r) => r.targetId == peerId && r.isAccepted && r.chatId != null)
      .firstOrNull;
  if (accepted != null) {
    return (state: ChatRequestState.chatExists, chatId: accepted.chatId);
  }
  if (incoming.any((r) => r.requesterId == peerId)) {
    return (state: ChatRequestState.incoming, chatId: null);
  }
  if (outgoing.any((r) => r.targetId == peerId && !r.isAccepted)) {
    return (state: ChatRequestState.outgoing, chatId: null);
  }
  return (state: ChatRequestState.none, chatId: null);
}
