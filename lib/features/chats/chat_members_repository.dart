// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_member_model.dart';

/// Repository for managing chat members
class ChatMembersRepository {
  final SupabaseClient _supabase;

  ChatMembersRepository(this._supabase);

  /// Get all members of a chat
  Future<List<String>> getChatMembers(String chatId) async {
    final response = await _supabase
        .from('chat_members')
        .select('user_id')
        .eq('chat_id', chatId);

    return (response as List)
        .map((item) => item['user_id'] as String)
        .toList();
  }

  /// Get pending members of a chat (moved to PendingChatMembersRepository)
  /// This method is deprecated - use PendingChatMembersRepository.getPendingMembers instead
  @Deprecated('Use PendingChatMembersRepository.getPendingMembers instead')
  Future<List<ChatMember>> getPendingMembers(String chatId) async {
    // This now returns empty list - pending members are in separate table
    return [];
  }

  /// Add a member to a chat (admin only)
  Future<void> addMember({
    required String chatId,
    required String userId,
  }) async {
    await _supabase.from('chat_members').insert({
      'chat_id': chatId,
      'user_id': userId,
    });
  }

  /// Remove a member from a chat (admin only or self)
  Future<void> removeMember({
    required String chatId,
    required String userId,
  }) async {
    await _supabase
        .from('chat_members')
        .delete()
        .eq('chat_id', chatId)
        .eq('user_id', userId);
  }

  /// Promote a user to admin
  Future<void> promoteToAdmin({
    required String chatId,
    required String userId,
  }) async {
    // Get current admins
    final response = await _supabase
        .from('chats')
        .select('admins')
        .eq('id', chatId)
        .single();

    final currentAdmins = List<String>.from(response['admins'] as List? ?? []);

    // Add user if not already admin
    if (!currentAdmins.contains(userId)) {
      currentAdmins.add(userId);

      await _supabase
          .from('chats')
          .update({'admins': currentAdmins})
          .eq('id', chatId);
    }
  }

  /// Demote a user from admin (must have at least one admin remaining)
  Future<void> demoteFromAdmin({
    required String chatId,
    required String userId,
  }) async {
    // Get current admins
    final response = await _supabase
        .from('chats')
        .select('admins')
        .eq('id', chatId)
        .single();

    final currentAdmins = List<String>.from(response['admins'] as List? ?? []);

    // Check if there's more than one admin
    if (currentAdmins.length <= 1) {
      throw Exception('Cannot demote the last admin');
    }

    // Remove user from admins
    currentAdmins.remove(userId);

    await _supabase
        .from('chats')
        .update({'admins': currentAdmins})
        .eq('id', chatId);
  }

  /// Check if a user is an admin of a chat
  Future<bool> isAdmin({
    required String chatId,
    required String userId,
  }) async {
    final response = await _supabase
        .from('chats')
        .select('admins')
        .eq('id', chatId)
        .single();

    final admins = List<String>.from(response['admins'] as List? ?? []);
    return admins.contains(userId);
  }

  /// Check if a user is a member of a chat
  Future<bool> isMember({
    required String chatId,
    required String userId,
  }) async {
    final response = await _supabase
        .from('chat_members')
        .count()
        .eq('chat_id', chatId)
        .eq('user_id', userId);

    return response > 0;
  }

  /// Accept a pending member (moved to PendingChatMembersRepository)
  /// This method is deprecated - use PendingChatMembersRepository.approveMember instead
  @Deprecated('Use PendingChatMembersRepository.approveMember instead')
  Future<void> acceptMember({
    required String chatId,
    required String userId,
  }) async {
    throw UnimplementedError(
      'Use PendingChatMembersRepository.approveMember instead',
    );
  }

  /// Get membership status for a specific user in a chat
  /// Returns ChatMember with accepted field, or null if not a member
  Future<ChatMember?> getMembershipStatus({
    required String chatId,
    required String userId,
  }) async {
    final response = await _supabase
        .from('chat_members')
        .select('*')
        .eq('chat_id', chatId)
        .eq('user_id', userId)
        .maybeSingle();

    if (response == null) return null;
    return ChatMember.fromJson(response);
  }
}
