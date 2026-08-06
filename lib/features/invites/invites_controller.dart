// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/security/kem_key_signer.dart';
import '../../core/security/security_providers.dart';
import '../../core/supabase/supabase_client_provider.dart';
import '../chats/chats_controller.dart';

/// Client side of the invitation flow (migration 00069). All authority lives
/// in the three SECURITY DEFINER RPCs — everything here is plumbing, and the
/// admin-only visibility in the UI is mere politeness on top of the server
/// checks.
final invitesControllerProvider = Provider<InvitesController>((ref) {
  return InvitesController(ref);
});

/// One row of the admin's revoke list.
class ChatInvite {
  final String token;
  final String chatId;
  final String targetChatId;
  final DateTime createdAt;
  final DateTime? revokedAt;

  const ChatInvite({
    required this.token,
    required this.chatId,
    required this.targetChatId,
    required this.createdAt,
    this.revokedAt,
  });

  bool get isRevoked => revokedAt != null;
}

/// Active (and revoked) invites of one group — admin-only by RLS: everyone
/// else simply gets an empty list, never an error.
final chatInvitesProvider = FutureProvider.autoDispose
    .family<List<ChatInvite>, String>((ref, chatId) async {
  final rows = await ref
      .read(supabaseClientProvider)
      .from('chat_invites')
      .select()
      .eq('chat_id', chatId)
      .order('created_at', ascending: false) as List<dynamic>;
  return rows.map((dynamic e) {
    final map = e as Map<String, dynamic>;
    return ChatInvite(
      token: map['token'] as String,
      chatId: map['chat_id'] as String,
      targetChatId: map['target_chat_id'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      revokedAt: map['revoked_at'] == null
          ? null
          : DateTime.parse(map['revoked_at'] as String),
    );
  }).toList();
});

class InvitesController {
  final Ref ref;

  InvitesController(this.ref);

  /// Mints one token scoped to [targetChatId]. One call PER target chat —
  /// a shared token across targets would defeat the "only valid in the chat
  /// it was sent to" rule.
  Future<String> createInvite({
    required String chatId,
    required String targetChatId,
  }) async {
    final token = await ref.read(supabaseClientProvider).rpc<dynamic>(
      'create_chat_invite',
      params: {'p_chat_id': chatId, 'p_target_chat_id': targetChatId},
    );
    return token as String;
  }

  Future<void> revokeInvite(String token) async {
    await ref.read(supabaseClientProvider).rpc<dynamic>(
      'revoke_chat_invite',
      params: {'p_token': token},
    );
  }

  /// Redeems [token] for the invited group [chatId]: generates this chat's
  /// keypair exactly like the QR join does (identity-signed public half),
  /// lets the server auto-approve, then loads the chat locally. Returns the
  /// joined chat id.
  ///
  /// Key generation is guarded by a membership check first — regenerating an
  /// existing member's keys would rotate them and spam a "new keys" system
  /// message (same trap requestToJoinChecked avoids).
  Future<String> redeemInvite({
    required String token,
    required String chatId,
  }) async {
    final client = ref.read(supabaseClientProvider);
    final userId = client.auth.currentUser?.id;
    if (userId == null) throw Exception('not authenticated');

    final alreadyMember = await client
            .from('chat_members')
            .count()
            .eq('chat_id', chatId)
            .eq('user_id', userId) >
        0;

    String publicKey = '';
    if (!alreadyMember) {
      final keyManager = ref.read(chatKeyPairManagerProvider);
      await keyManager.generateKeyPairForChat(chatId);
      final pub = await keyManager.getPublicKey(chatId);
      if (pub == null) throw Exception('Failed to generate key pair');
      publicKey = await ref.read(kemKeySignerProvider).sign(chatId, pub);
    }

    final joined = await client.rpc<dynamic>(
      'redeem_chat_invite',
      params: {'p_token': token, 'p_public_key': publicKey},
    ) as String;

    // Same post-join step as the QR path: pull the chat into local state.
    await ref.read(chatsControllerProvider.notifier).addChat(joined);
    logger.info('Joined chat $joined via invite', tag: 'InvitesController');
    return joined;
  }
}
