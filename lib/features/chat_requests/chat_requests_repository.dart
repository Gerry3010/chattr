// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';
import 'chat_request_model.dart';

/// Why a request could not be created — as far as the server says at all.
/// [blocked] is deliberately missing here: a block looks like a success on the
/// wire (00082), otherwise the error message would be the disclosure there is
/// not supposed to be.
enum ChatRequestFailure {
  /// No account with this id — a mistyped ID should be visible.
  noSuchUser,

  /// We already have a chat.
  chatExists,

  /// Quota exhausted (20 open, or 10 per hour).
  tooMany,

  /// Alles andere (Netz, unerwarteter Serverfehler).
  unknown,
}

class ChatRequestException implements Exception {
  final ChatRequestFailure reason;
  final Object? cause;

  const ChatRequestException(this.reason, [this.cause]);

  @override
  String toString() => 'ChatRequestException($reason, $cause)';
}

/// Access to the chat requests (migration 00082).
///
/// The table `chat_requests` has NO RLS policy — every access runs through the
/// six functions here. That is not a detour: if the requester read the row
/// directly, `accepted = false` would stand in it, and the silent rejection
/// would be none.
class ChatRequestsRepository {
  static const String _tag = 'ChatRequestsRepository';

  final SupabaseClient _client;

  ChatRequestsRepository(this._client);

  Future<List<IncomingChatRequest>> incoming() async {
    final res = await _client.rpc<dynamic>('my_incoming_chat_requests');
    return (res as List<dynamic>)
        .map((dynamic e) =>
            incomingChatRequestFromRow(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<List<OutgoingChatRequest>> outgoing() async {
    final res = await _client.rpc<dynamic>('my_outgoing_chat_requests');
    return (res as List<dynamic>)
        .map((dynamic e) =>
            outgoingChatRequestFromRow(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Requests [targetId]. Passes without error when a request is already
  /// pending or a block exists — both look the same to the caller.
  Future<void> send(String targetId) async {
    try {
      await _client.rpc<dynamic>(
        'send_chat_request',
        params: {'p_target': targetId},
      );
      logger.info('Chat-Anfrage an $targetId gesendet', tag: _tag);
    } on PostgrestException catch (e) {
      throw ChatRequestException(_failureFrom(e), e);
    }
  }

  /// Accepts the request from [requesterId] and returns the id of the freshly
  /// created chat.
  Future<String> accept(String requesterId) async {
    final res = await _client.rpc<dynamic>(
      'accept_chat_request',
      params: {'p_requester': requesterId},
    );
    logger.info('Chat-Anfrage von $requesterId angenommen', tag: _tag);
    return res as String;
  }

  /// Rejects. Sends the requester nothing — neither event nor push.
  Future<void> decline(String requesterId, {bool block = false}) async {
    await _client.rpc<dynamic>(
      'decline_chat_request',
      params: {'p_requester': requesterId, 'p_block': block},
    );
  }

  /// Withdraws one's own request.
  Future<void> withdraw(String targetId) async {
    await _client.rpc<dynamic>(
      'withdraw_chat_request',
      params: {'p_target': targetId},
    );
  }

  /// By SQLSTATE, not by text — that is not translated and could change.
  /// `check_violation` covers "requesting oneself" besides the quota; the UI
  /// cannot trigger that at all (one's own name does not offer the row), so the
  /// coarser mapping here is not an imprecision anybody will ever get to see.
  static ChatRequestFailure _failureFrom(PostgrestException e) {
    switch (e.code) {
      case '23503': // foreign_key_violation
        return ChatRequestFailure.noSuchUser;
      case '23505': // unique_violation
        return ChatRequestFailure.chatExists;
      case '23514': // check_violation
        return ChatRequestFailure.tooMany;
      default:
        return ChatRequestFailure.unknown;
    }
  }
}
