// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_client_provider.dart';
import 'mcp_token_model.dart';

final mcpTokensRepositoryProvider = Provider<McpTokensRepository>((ref) {
  return McpTokensRepository(ref.read(supabaseClientProvider));
});

/// Talks to the mcp_tokens table / mint_mcp_token / revoke_mcp_token RPCs
/// (migration 00038_mcp_agent_chats.sql). The token secret itself only ever
/// exists client-side for the moment mintToken() returns it — the server
/// stores just its hash and never returns it again.
class McpTokensRepository {
  final SupabaseClient client;

  McpTokensRepository(this.client);

  Future<List<McpTokenInfo>> listTokens() async {
    final List<dynamic> res = await client
        .from('mcp_tokens')
        .select('id, label, created_at, revoked_at')
        .order('created_at', ascending: false);
    return res
        .map((dynamic e) => McpTokenInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Mints a new token and returns the plaintext secret — shown to the user
  /// ONCE. There is no way to retrieve it again after this call returns.
  Future<String> mintToken({String? label}) async {
    final secret = await client.rpc<String>(
      'mint_mcp_token',
      params: {'p_label': label},
    );
    return secret;
  }

  Future<void> revokeToken(String tokenId) async {
    await client.rpc<void>(
      'revoke_mcp_token',
      params: {'p_token_id': tokenId},
    );
  }
}
