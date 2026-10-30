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

  /// Which admin minted this. A group can have several, and the list is the
  /// place where one of them decides whether to revoke someone else's work —
  /// so it has to say whose.
  final String? createdBy;

  const ChatInvite({
    required this.token,
    required this.chatId,
    required this.targetChatId,
    required this.createdAt,
    this.revokedAt,
    this.createdBy,
  });

  bool get isRevoked => revokedAt != null;
}

/// Which of [active] have done their job and can be retired?
///
/// An invitation is scoped to exactly one target chat: only members of that
/// chat can redeem it. So once every member of the target chat is already in
/// the group [chatId], no one is left who could use the token — it is spent.
/// In a 1:1 target that is simply "the invited person joined", which is the
/// case that had invitations sitting in "Aktive Einladungen" forever.
///
/// [membersByChat] must contain a chat's members only when they are actually
/// known. An unknown target chat (a co-admin invited into a chat we are not in,
/// so RLS shows us nothing) is left alone: "no rows" is not "everyone joined",
/// and reading it that way would revoke a live invitation behind the admin's
/// back.
Set<String> fulfilledInviteTokens({
  required String chatId,
  required Iterable<ChatInvite> active,
  required Map<String, Set<String>> membersByChat,
}) {
  final groupMembers = membersByChat[chatId] ?? const <String>{};
  if (groupMembers.isEmpty) return const <String>{};
  return {
    for (final invite in active)
      if (!invite.isRevoked)
        if ((membersByChat[invite.targetChatId] ?? const <String>{})
            case final targetMembers
            when targetMembers.isNotEmpty &&
                targetMembers.every(groupMembers.contains))
          invite.token,
  };
}

/// Active (and revoked) invites of one group — admin-only by RLS: everyone
/// else simply gets an empty list, never an error.
///
/// Before returning, invitations that have **done their job** are retired: an
/// invite is scoped to one target chat, so once every member of that target
/// chat is already in the group, nobody is left who could redeem it. Those used
/// to sit in "Aktive Einladungen" forever — in a 1:1 target that means the row
/// stayed the moment the invited person joined, offering to revoke a token that
/// had already been spent. Retiring means actually revoking it, not just hiding
/// it: a live token nobody needs is exactly what should not linger.
final chatInvitesProvider = FutureProvider.autoDispose
    .family<List<ChatInvite>, String>((ref, chatId) async {
  final client = ref.read(supabaseClientProvider);
  final rows = await client
      .from('chat_invites')
      .select()
      .eq('chat_id', chatId)
      .order('created_at', ascending: false) as List<dynamic>;
  final invites = rows.map((dynamic e) {
    final map = e as Map<String, dynamic>;
    return ChatInvite(
      token: map['token'] as String,
      chatId: map['chat_id'] as String,
      targetChatId: map['target_chat_id'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      revokedAt: map['revoked_at'] == null
          ? null
          : DateTime.parse(map['revoked_at'] as String),
      createdBy: map['created_by'] as String?,
    );
  }).toList();

  final active = invites.where((i) => !i.isRevoked).toList();
  if (active.isEmpty) return invites;

  // One query for the group's members and every target chat's members. A
  // target chat we are not in returns nothing (RLS) — that invite is simply
  // left alone, since "no rows" must never be read as "everyone joined".
  final chatIds = <String>{chatId, ...active.map((i) => i.targetChatId)};
  final memberRows = await client
      .from('chat_members')
      .select('chat_id, user_id')
      .inFilter('chat_id', chatIds.toList()) as List<dynamic>;
  final membersByChat = <String, Set<String>>{};
  for (final dynamic row in memberRows) {
    final map = row as Map<String, dynamic>;
    membersByChat
        .putIfAbsent(map['chat_id'] as String, () => <String>{})
        .add(map['user_id'] as String);
  }
  final fulfilled = fulfilledInviteTokens(
    chatId: chatId,
    active: active,
    membersByChat: membersByChat,
  );
  if (fulfilled.isEmpty) return invites;

  final controller = ref.read(invitesControllerProvider);
  final retired = <String>{};
  for (final token in fulfilled) {
    try {
      await controller.revokeInvite(token);
      retired.add(token);
      logger.info(
        'Retired fulfilled invite $token in chat $chatId',
        tag: 'InvitesController',
      );
    } catch (e) {
      // Not an admin, or the server said no — then it stays visible. Hiding a
      // token we failed to revoke would be the worst of both worlds.
      logger.warning(
        'Could not retire fulfilled invite $token: $e',
        tag: 'InvitesController',
      );
    }
  }
  if (retired.isEmpty) return invites;
  return invites.where((i) => !retired.contains(i.token)).toList();
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
