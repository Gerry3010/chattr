// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_client_provider.dart';

/// A published one-time prekey: its id + the identity-signed public blob
/// (`{"x":..,"m":..,"s":..}`).
class PublishedPrekey {
  final String prekeyId;
  final String publicBlob;
  const PublishedPrekey({required this.prekeyId, required this.publicBlob});
}

/// Server access for the one-time KEM prekey pool (`chat_member_prekeys`,
/// forward secrecy audit P3). Public halves only — the private halves live in
/// [PrekeyLocalRepository]. The server stays zero-knowledge.
class PrekeyRepository {
  final SupabaseClient client;

  PrekeyRepository(this.client);

  /// Publish a batch of my own public prekeys for [chatId].
  Future<void> publish({
    required String chatId,
    required String userId,
    required List<PublishedPrekey> prekeys,
  }) async {
    if (prekeys.isEmpty) return;
    final rows = prekeys
        .map((p) => {
              'chat_id': chatId,
              'user_id': userId,
              'prekey_id': p.prekeyId,
              'public_blob': p.publicBlob,
            })
        .toList();
    await client.from('chat_member_prekeys').insert(rows);
  }

  /// The ids of [userId]'s still-unconsumed prekeys in [chatId]. Used to
  /// decide when to top the pool up, and to find prekeys whose private half
  /// this device does not have (see [PrekeyManager.replenishIfLow]).
  Future<List<String>> unconsumedIds({
    required String chatId,
    required String userId,
  }) async {
    final res = await client
        .from('chat_member_prekeys')
        .select('prekey_id')
        .eq('chat_id', chatId)
        .eq('user_id', userId)
        .isFilter('consumed_at', null);
    return [for (final row in res as List) (row as Map)['prekey_id'] as String];
  }

  /// Delete specific prekeys of my own in [chatId], consumed or not. RLS
  /// (`prekeys_delete_self`) only ever lets a member delete its own rows.
  Future<void> deleteMine({
    required String chatId,
    required String userId,
    required List<String> prekeyIds,
  }) async {
    if (prekeyIds.isEmpty) return;
    await client
        .from('chat_member_prekeys')
        .delete()
        .eq('chat_id', chatId)
        .eq('user_id', userId)
        .inFilter('prekey_id', prekeyIds);
  }

  /// Atomically claim + consume one unconsumed prekey of [recipientId] in
  /// [chatId] (SECURITY DEFINER RPC, SKIP LOCKED — never hands the same prekey
  /// to two senders). Returns null when the pool is exhausted → caller falls
  /// back to v4.
  Future<PublishedPrekey?> claim({
    required String chatId,
    required String recipientId,
  }) async {
    final res = await client.rpc<List<dynamic>>('claim_prekey', params: {
      'p_chat_id': chatId,
      'p_user_id': recipientId,
    });
    final list = res;
    if (list.isEmpty) return null;
    final row = list.first as Map<String, dynamic>;
    return PublishedPrekey(
      prekeyId: row['prekey_id'] as String,
      publicBlob: row['public_blob'] as String,
    );
  }

  /// Delete my own consumed prekeys in [chatId] (housekeeping on replenish, so
  /// the server pool doesn't grow unbounded). Never touches unconsumed ones.
  Future<void> deleteMyConsumed({
    required String chatId,
    required String userId,
  }) async {
    await client
        .from('chat_member_prekeys')
        .delete()
        .eq('chat_id', chatId)
        .eq('user_id', userId)
        .not('consumed_at', 'is', null);
  }
}

final prekeyRepositoryProvider = Provider<PrekeyRepository>((ref) {
  return PrekeyRepository(ref.read(supabaseClientProvider));
});
