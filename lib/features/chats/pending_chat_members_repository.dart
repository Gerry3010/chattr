// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/logging/logger_service.dart';
import 'pending_chat_member_model.dart';

class PendingChatMembersRepository {
  final SupabaseClient _client;

  PendingChatMembersRepository(this._client);

  /// Request to join a chat (creates pending membership)
  Future<void> requestToJoin({
    required String chatId,
    required String userId,
    required String publicKey,
  }) async {
    await _client.from('pending_chat_members').insert({
      'chat_id': chatId,
      'user_id': userId,
      'public_key': publicKey,
    });

    logger.info(
      'User $userId requested to join chat $chatId',
      tag: 'PendingChatMembersRepository',
    );
  }

  Future<List<PendingChatMember>> getPendingMembers(String chatId) async {
    final List<dynamic> response = await _client
        .from('pending_chat_members')
        .select()
        .eq('chat_id', chatId)
        .isFilter('blocked_at', null)  // Only non-blocked requests
        .order('created_at', ascending: true);

    return response
        .map((dynamic e) {
      final Map<String, dynamic> map = e as Map<String, dynamic>;
      return PendingChatMember.fromJson(map);
    })
        .toList();
  }

  /// Get user's own pending request status
  Future<PendingChatMember?> getUserPendingStatus({
    required String chatId,
    required String userId,
  }) async {
    final response = await _client
        .from('pending_chat_members')
        .select()
        .eq('chat_id', chatId)
        .eq('user_id', userId)
        .maybeSingle();

    if (response == null) {
      return null;
    }

    return PendingChatMember.fromJson(response);
  }

  /// Approve a pending member (admin only)
  /// This deletes from pending and adds to chat_members
  Future<void> approveMember({
    required String chatId,
    required String userId,
    required String publicKey,
  }) async {
    // Delete from pending_chat_members (RLS ensures admin permission)
    await _client
        .from('pending_chat_members')
        .delete()
        .eq('chat_id', chatId)
        .eq('user_id', userId);

    // Insert into chat_members (RLS ensures admin permission)
    await _client.from('chat_members').insert({
      'chat_id': chatId,
      'user_id': userId,
      'public_key': publicKey,
    });

    logger.info(
      'Approved user $userId for chat $chatId',
      tag: 'PendingChatMembersRepository',
    );
  }

  /// Reject a pending member (admin only)
  /// This simply deletes from pending_chat_members
  Future<void> rejectMember({
    required String chatId,
    required String userId,
  }) async {
    await _client
        .from('pending_chat_members')
        .delete()
        .eq('chat_id', chatId)
        .eq('user_id', userId);

    logger.info(
      'Rejected user $userId for chat $chatId',
      tag: 'PendingChatMembersRepository',
    );
  }

  /// Block a pending member (admin only)
  /// Sets blocked_at timestamp
  Future<void> blockMember({
    required String chatId,
    required String userId,
  }) async {
    await _client
        .from('pending_chat_members')
        // .toUtc(): a naive local ISO string (no offset) would be read as UTC
        // by the timestamptz column, storing an instant off by the local offset.
        .update({'blocked_at': DateTime.now().toUtc().toIso8601String()})
        .eq('chat_id', chatId)
        .eq('user_id', userId);

    logger.info(
      'Blocked user $userId from chat $chatId',
      tag: 'PendingChatMembersRepository',
    );
  }

  /// Cancel own pending request
  Future<void> cancelRequest({
    required String chatId,
    required String userId,
  }) async {
    // Users can only delete their own pending requests through RLS
    await _client
        .from('pending_chat_members')
        .delete()
        .eq('chat_id', chatId)
        .eq('user_id', userId);

    logger.info(
      'User $userId cancelled request to join chat $chatId',
      tag: 'PendingChatMembersRepository',
    );
  }

  Future<bool> isPendingMember({required String chatId, required String userId}) async {
    final response = await _client
    .from('pending_chat_members')
    .count()
    .eq('chat_id', chatId)
    .eq('user_id', userId);

    return response > 0;
  }

  /// The current user's OWN outstanding join requests, enriched with the group
  /// name (which plain `chats` RLS hides from a not-yet-member). Backed by the
  /// SECURITY DEFINER RPC `get_my_pending_requests()` (migration 00043), which
  /// scopes strictly to `auth.uid()`.
  Future<List<MyPendingRequest>> getMyPendingRequests() async {
    final res = await _client.rpc<dynamic>('get_my_pending_requests');
    final rows = res as List<dynamic>;
    return rows
        .map((dynamic e) => myPendingRequestFromRow(e as Map<String, dynamic>))
        .toList();
  }
}
