// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/lifecycle/app_lifecycle_service.dart';
import '../../core/logging/logger_service.dart';
import '../../core/security/chat_key_pair_manager.dart';
import '../../core/security/kem_key_signer.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../auth/auth_controller.dart';
import '../chats/chat_members_controller.dart';
import '../chats/chats_controller.dart';
import '../chats/mute_controller.dart';
import 'mcp_token_model.dart';
import 'mcp_tokens_controller.dart';

/// Background service (read once, no reactive state of its own — same shape
/// as [GlobalMessageHandler]) that silently joins MCP chats bound to this
/// user. E2E means the server can only grant *discovery* (RLS in migration
/// 00038_mcp_agent_chats.sql lets an mcp_owner see a chat before joining) —
/// becoming able to actually decrypt anything still requires this app to
/// generate a real per-chat keypair and go through the normal group-join
/// flow, same as scanning someone's QR code. That's what this does, minus
/// the QR code.
final mcpAutoJoinControllerProvider = Provider<McpAutoJoinController>((ref) {
  final client = ref.read(supabaseClientProvider);
  final keyManager = ref.read(chatKeyPairManagerProvider);
  final memberController = ref.read(chatMembersControllerProvider);
  final userId = ref.watch(authControllerProvider);

  final controller = McpAutoJoinController(
    ref,
    client,
    keyManager,
    memberController,
    userId,
  );

  ref.onDispose(controller.dispose);
  return controller;
});

class McpAutoJoinController {
  final Ref ref;
  final SupabaseClient client;
  final ChatKeyPairManager keyManager;
  final ChatMembersController memberController;
  final String? userId;

  StreamSubscription<void>? _resumeSub;
  bool _reconciling = false;

  /// Chat ids we've already submitted a join request for this session — a
  /// pending request survives until an admin approves/rejects it, so there's
  /// no need to hammer the same insert on every resume (it would just fail
  /// on the pending_chat_members primary key anyway; this just avoids the
  /// round-trip and the log noise).
  final Set<String> _requestedThisSession = {};

  McpAutoJoinController(
    this.ref,
    this.client,
    this.keyManager,
    this.memberController,
    this.userId,
  ) {
    if (userId != null) {
      _resumeSub = ref
          .read(appLifecycleServiceProvider)
          .onResume
          .listen((_) => reconcile());
      // Fire once at startup too — the resume stream only fires on a real
      // background->foreground transition, not on cold start.
      unawaited(reconcile());
    }
  }

  void dispose() {
    _resumeSub?.cancel();
  }

  /// Whether MCP is "enabled" enough to run the reconciler: the user holds at
  /// least one non-revoked token. Revoked-only means MCP was turned off, so we
  /// stay quiet. Pure + static so it's unit-testable without the whole
  /// provider graph (see test/mcp_auto_join_test.dart) — the async wiring that
  /// feeds it the resolved token list is exercised in reconcile().
  static bool hasActiveToken(List<McpTokenInfo> tokens) =>
      tokens.any((t) => !t.isRevoked);

  /// Finds MCP chats bound to this user that the app isn't a member of yet,
  /// and requests to join each of them.
  Future<void> reconcile() async {
    if (userId == null || _reconciling) return;
    _reconciling = true;
    try {
      // Gate on an actually-resolved token list. Reading this synchronously
      // (the old mcpEnabledProvider) returned false while mcpTokensProvider
      // was still AsyncLoading on cold start, so the reconciler bailed on
      // every run and never discovered owner-bound MCP chats. Awaiting the
      // future resolves it first. A fetch error propagates to the catch
      // below (logged, retried on the next resume) rather than being silently
      // read as "MCP disabled".
      final tokens = await ref.read(mcpTokensProvider.future);
      if (!hasActiveToken(tokens)) {
        return; // no active token minted -> MCP was never turned on
      }
      // RLS (migration 00038) grants a bound owner SELECT on chats they
      // haven't joined yet — get_user_chats_with_metadata can't be used here
      // since it INNER JOINs chat_members and would filter these out.
      final List<dynamic> rows = await client
          .from('chats')
          .select('id')
          .eq('is_mcp', true)
          .eq('mcp_owner_id', userId!);

      final joinedIds = ref.read(chatsControllerProvider).map((c) => c.id).toSet();

      for (final row in rows) {
        final chatId = row['id'] as String;
        if (joinedIds.contains(chatId)) continue;
        if (_requestedThisSession.contains(chatId)) continue;
        await _joinAndMute(chatId);
      }
    } catch (e, stackTrace) {
      logger.error(
        'Failed to reconcile MCP chats',
        tag: 'McpAutoJoin',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _joinAndMute(String chatId) async {
    _requestedThisSession.add(chatId);
    try {
      var publicKey = await keyManager.getPublicKey(chatId);
      if (publicKey == null) {
        await keyManager.generateKeyPairForChat(chatId);
        publicKey = await keyManager.getPublicKey(chatId);
      }
      if (publicKey == null) {
        throw Exception('Failed to generate a key pair for MCP chat $chatId');
      }

      await memberController.requestToJoin(
        chatId: chatId,
        userId: userId!,
        // Identity-signed so co-members can verify it (audit C1).
        publicKey: await ref.read(kemKeySignerProvider).sign(chatId, publicKey),
      );

      // Mute up front (not after approval) so there's no window where a
      // chatty agent's messages could slip through as a loud push the
      // moment an admin approves — the user opted into MCP, not into noise.
      // Muting doesn't require membership (chat_mute_prefs only FKs to
      // chats/auth.users, RLS just checks user_id = auth.uid()).
      await ref.read(mutedChatsProvider.notifier).mute(chatId);

      logger.info('Requested to join MCP chat $chatId', tag: 'McpAutoJoin');
    } catch (e) {
      // Most likely already pending (unique-violation on a stale session /
      // race with another resume) — not worth surfacing to the user.
      logger.warning(
        'Could not auto-join MCP chat $chatId: $e',
        tag: 'McpAutoJoin',
      );
    }
  }
}
