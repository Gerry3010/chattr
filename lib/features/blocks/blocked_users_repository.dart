// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_client_provider.dart';

/// Manages the current user's block list (`blocked_users` table).
///
/// RLS restricts every operation to rows where `blocker_id = auth.uid()`;
/// enforcement against the blocked pair (no new 1:1 chats, no 1:1 messages)
/// lives in DB triggers (migration 00031), not here.
class BlockedUsersRepository {
  final SupabaseClient client;

  BlockedUsersRepository(this.client);

  /// User ids blocked by the current user, newest first.
  Future<List<String>> getBlockedUserIds() async {
    final rows = await client
        .from('blocked_users')
        .select('blocked_id')
        .order('created_at', ascending: false);
    return rows.map((r) => r['blocked_id'] as String).toList();
  }

  Future<void> block(String userId) async {
    final blockerId = client.auth.currentUser?.id;
    if (blockerId == null) {
      throw Exception('Cannot block: not authenticated');
    }
    await client.from('blocked_users').upsert({
      'blocker_id': blockerId,
      'blocked_id': userId,
    });
  }

  Future<void> unblock(String userId) async {
    await client.from('blocked_users').delete().eq('blocked_id', userId);
  }
}

final blockedUsersRepositoryProvider = Provider<BlockedUsersRepository>((ref) {
  return BlockedUsersRepository(ref.read(supabaseClientProvider));
});

/// The current user's block list. Refresh after block/unblock via
/// `ref.invalidate(blockedUserIdsProvider)`.
final blockedUserIdsProvider =
    FutureProvider.autoDispose<List<String>>((ref) async {
  return ref.read(blockedUsersRepositoryProvider).getBlockedUserIds();
});
