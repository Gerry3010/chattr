// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/supabase/supabase_client_provider.dart';

final chatMemberKeysRepositoryProvider = Provider<ChatMemberKeysRepository>((ref) {
  return ChatMemberKeysRepository(ref.read(supabaseClientProvider));
});

class ChatMemberKeysRepository {
  final SupabaseClient client;

  ChatMemberKeysRepository(this.client);

  /// Set or update public key for a user in a chat
  Future<void> setPublicKey({
    required String chatId,
    required String userId,
    required String publicKeyPem,
  }) async {
    await client.from('chat_members').update({
      'public_key': publicKeyPem,
    }).match({
      'chat_id': chatId,
      'user_id': userId,
    });
  }

  /// Get public key for a user in a chat
  Future<String?> getPublicKey({
    required String chatId,
    required String userId,
  }) async {
    final res = await client
        .from('chat_members')
        .select('public_key')
        .match({
          'chat_id': chatId,
          'user_id': userId,
        })
        .maybeSingle();

    return res?['public_key'] as String?;
  }

  /// Get all public keys for members in a chat (userId -> publicKey)
  Future<Map<String, String>> getAllPublicKeys(String chatId) async {
    var query = client
        .from('chat_members')
        .select('user_id, public_key')
        .eq('chat_id', chatId)
        .not('public_key', 'is', null);
    final res = await query;

    final keys = <String, String>{};
    for (final row in res as List) {
      final userId = row['user_id'] as String;
      final publicKey = row['public_key'] as String?;
      if (publicKey != null) {
        keys[userId] = publicKey;
      }
    }
    return keys;
  }

  /// Get all user IDs in a chat who have public keys set
  Future<List<String>> getUsersWithKeys(String chatId) async {
    final res = await client
        .from('chat_members')
        .select('user_id')
        .eq('chat_id', chatId)
        .not('public_key', 'is', null);

    return (res as List).map((e) => e['user_id'] as String).toList();
  }
}
