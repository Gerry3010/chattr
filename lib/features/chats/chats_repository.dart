// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/logging/logger_service.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../media/image_metadata.dart';
import 'chat_model.dart';

final chatsRepositoryProvider = Provider<ChatsRepository>((ref) {
  return ChatsRepository(ref.read(supabaseClientProvider));
});

class ChatsRepository {
  final SupabaseClient client;

  ChatsRepository(this.client);

  /// Mark a whole chat read for the current user — sets the PRIVATE per-member
  /// `last_read_at` (migration 00053) that drives the unread badge, with no read
  /// receipt / broadcast. Works regardless of the read-receipt privacy setting,
  /// so the badge no longer phantom-persists across restarts for receipts-off
  /// users (the RPC count is derived from this, not the suppressible `read_at`).
  Future<void> markChatRead(String chatId) async {
    await client.rpc<void>('mark_chat_read', params: {'p_chat_id': chatId});
  }

  Future<List<Chat>> fetchChats([Iterable<String>? chatIds]) async {
    final List<dynamic> res = await client.rpc<List<dynamic>>(
      'get_user_chats_with_metadata',
      params: {'p_chat_ids': chatIds?.toList(growable: false)},
    );

    final chats = res.map((dynamic e) {
      final map = e as Map<String, dynamic>;
      return Chat.fromJson(map);
    }).toList();

    // Sort by the shared sortDate getter (lastMessageAt ?? createdAt), so the
    // server-fetch order matches both the controller's re-sorts and what the
    // row displays. Most recent first.
    chats.sort((a, b) => b.sortDate.compareTo(a.sortDate));

    return chats;
  }

  Future<Chat> createChat(
    List<String> memberIds, {
    bool isGroup = true,
    String? name,
  }) async {
    final chatRes = await client
        .from('chats')
        .insert({
          'is_group': isGroup,
          if (isGroup && name != null) 'name': name,
        })
        .select()
        .maybeSingle();

    if (chatRes == null) {
      throw Exception('Failed to create chat');
    }

    final chat = Chat.fromJson(chatRes);

    try {
      await client
          .from('chat_members')
          .insert(
            memberIds
                .map((id) => {'chat_id': chat.id, 'user_id': id})
                .toList(growable: false),
          );
    } catch (e) {
      // Member insert rejected (e.g. blocked pair in a 1:1, migration 00031).
      // PostgREST calls aren't transactional across requests, so remove the
      // just-created chat row instead of leaving an orphan (we are its
      // admin → RLS allows the delete). Best-effort: an orphan is invisible
      // anyway (chat lists join through chat_members).
      try {
        await client.from('chats').delete().eq('id', chat.id);
      } catch (_) {}
      rethrow;
    }

    return chat;
  }

  /// Find an existing 1:1 (non-group) chat between the current user and
  /// [peerId], or null. Used to avoid creating a duplicate direct chat when the
  /// same pair is added again.
  ///
  /// RLS on `chat_members` only exposes rows for chats the caller belongs to
  /// (`is_chat_member(chat_id, auth.uid())`), so querying the PEER's memberships
  /// returns exactly the chats we share. Filtering those to `is_group = false`
  /// yields our direct chat (a 1:1 has only the two of us).
  Future<String?> findDirectChat(String peerId, String currentUserId) async {
    if (peerId == currentUserId) return null;
    final shared = await client
        .from('chat_members')
        .select('chat_id')
        .eq('user_id', peerId);
    final ids = (shared as List)
        .map((dynamic r) => (r as Map)['chat_id'] as String)
        .toList();
    if (ids.isEmpty) return null;

    final direct = await client
        .from('chats')
        .select('id')
        .eq('is_group', false)
        .inFilter('id', ids)
        .limit(1)
        .maybeSingle();
    return direct == null ? null : direct['id'] as String;
  }

  /// Get chat by ID
  Future<Chat?> getChatById(String chatId) async {
    final res = await client
        .from('chats')
        .select(
            'id, created_at, created_by, name, is_group, admins, is_mcp, mcp_owner_id')
        .eq('id', chatId)
        .maybeSingle();

    return res != null ? Chat.fromJson(res) : null;
  }

  /// Update chat name (admin only)
  Future<void> updateChatName(String chatId, String? name) async {
    await client.from('chats').update({'name': name}).eq('id', chatId);
  }

  /// Update chat description / topic (admin only)
  Future<void> updateChatDescription(String chatId, String? description) async {
    await client
        .from('chats')
        .update({'description': description}).eq('id', chatId);
  }

  /// Public storage bucket for group avatars (00055). Public read; write only
  /// for chat admins (path `<chatId>/…`), enforced by storage RLS.
  static const String groupAvatarBucket = 'group-avatars';

  // No `groupAvatarUrl` here any more: the bucket is private (00075) and a
  // public URL would 404. Group pictures are reached through
  // `avatarSignedUrlProvider`, whose signature also does the cache-busting the
  // old `?u=<updatedAt>` parameter was for — a new signature is a new URL.

  /// Upload a new avatar for a group, point the chat at it and delete the one
  /// it replaces.
  /// Returns the stored object path. Only admins of [chatId] may write, and only
  /// under the `<chatId>/…` folder (both enforced by storage + chat UPDATE RLS).
  Future<String> uploadGroupAvatar({
    required String chatId,
    required Uint8List bytes,
    required String fileExtension,
    String contentType = 'image/jpeg',
  }) async {
    final ext = fileExtension.replaceAll('.', '').toLowerCase();
    // Fresh name per upload, same reasons as ProfilesRepository.uploadAvatar
    // (CHAT-23): a fixed name is guessable and kept the old picture in every
    // image cache keyed on `bucket/path`.
    final path = '$chatId/${const Uuid().v4()}.$ext';
    // Strip EXIF/GPS at the choke point (same reasoning as ProfilesRepository
    // .uploadAvatar). This path also takes CAMERA shots directly, so an
    // unstripped upload published the capture location into a public bucket.
    final clean = await ImageMetadata.normalizeAndStrip(bytes, contentType);
    final previous = await _currentGroupAvatarPath(chatId);
    await client.storage.from(groupAvatarBucket).uploadBinary(
          path,
          clean,
          fileOptions: FileOptions(contentType: contentType),
        );
    await client.from('chats').update({'avatar_path': path}).eq('id', chatId);
    await _removeGroupAvatarObject(chatId, previous, keep: path);
    return path;
  }

  /// Remove a group's avatar (admin only): clears the column, then deletes the
  /// stored object, since with per-upload names nothing would overwrite it.
  Future<void> clearGroupAvatar(String chatId) async {
    final previous = await _currentGroupAvatarPath(chatId);
    await client.from('chats').update({'avatar_path': null}).eq('id', chatId);
    await _removeGroupAvatarObject(chatId, previous);
  }

  Future<String?> _currentGroupAvatarPath(String chatId) async {
    try {
      final row = await client
          .from('chats')
          .select('avatar_path')
          .eq('id', chatId)
          .maybeSingle();
      return row?['avatar_path'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Best effort, and only inside the chat's own folder: a leftover costs
  /// storage, never correctness.
  Future<void> _removeGroupAvatarObject(
    String chatId,
    String? previous, {
    String? keep,
  }) async {
    if (previous == null || previous == keep) return;
    if (!previous.startsWith('$chatId/')) return;
    try {
      await client.storage.from(groupAvatarBucket).remove([previous]);
    } catch (e) {
      logger.warning('Could not remove replaced group avatar $previous: $e',
          tag: 'ChatsRepository');
    }
  }

  /// Set the disappearing-messages TTL (seconds) for a chat. Null disables it.
  Future<void> updateMessageTtl(String chatId, int? ttlSeconds) async {
    await client
        .from('chats')
        .update({'message_ttl_seconds': ttlSeconds}).eq('id', chatId);
  }

  /// Delete a chat (admin only). Returns whether a row was actually deleted:
  /// PostgREST reports success even when RLS filters the delete down to zero
  /// rows (e.g. requester is not an admin), so the affected rows must be
  /// checked explicitly.
  Future<bool> deleteChat(String chatId) async {
    final rows =
        await client.from('chats').delete().eq('id', chatId).select('id');
    return rows.isNotEmpty;
  }
}
