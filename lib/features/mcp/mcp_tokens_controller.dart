// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mcp_token_model.dart';
import 'mcp_tokens_repository.dart';

/// The current user's MCP tokens (metadata only — never the secret).
/// Invalidate after mint/revoke to refresh (see McpSettingsScreen).
final mcpTokensProvider =
    FutureProvider.autoDispose<List<McpTokenInfo>>((ref) async {
  final repo = ref.watch(mcpTokensRepositoryProvider);
  return repo.listTokens();
});

// NOTE: there used to be a synchronous `mcpEnabledProvider` here that the
// auto-join reconciler read as a gate. It read the async [mcpTokensProvider]
// via maybeWhen(orElse: false), so on cold start — while the token list was
// still AsyncLoading — it returned false and the reconciler bailed *every*
// time, never discovering owner-bound MCP chats (owner's app never filed a
// join request). The reconciler now awaits the token future directly
// (see McpAutoJoinController.reconcile) so it gates on a resolved value.
