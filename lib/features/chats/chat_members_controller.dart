// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/supabase/supabase_client_provider.dart';
import 'chat_member_model.dart';
import 'chat_members_repository.dart';
import 'chat_model.dart';
import 'chats_controller.dart';
import 'pending_chat_member_model.dart';
import 'pending_chat_members_repository.dart';

/// One chat the current user administers together with its outstanding join
/// requests. Building block for the app-wide pending-requests overview.
typedef PendingRequestGroup = ({Chat chat, List<PendingChatMember> pending});

/// Outcome of a checked join attempt, so the UI can tell the user what happened
/// instead of silently creating a duplicate/no-op request.
enum JoinRequestOutcome { requested, alreadyMember, alreadyPending }

final chatMembersRepositoryProvider = Provider<ChatMembersRepository>((ref) {
  return ChatMembersRepository(ref.read(supabaseClientProvider));
});

final pendingChatMembersRepositoryProvider =
    Provider<PendingChatMembersRepository>((ref) {
      return PendingChatMembersRepository(ref.read(supabaseClientProvider));
    });

/// Provider for chat members list
final chatMembersProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, chatId) async {
      final repo = ref.read(chatMembersRepositoryProvider);
      return await repo.getChatMembers(chatId);
    });

/// Provider for pending members list (uses new pending_chat_members table)
final pendingMembersProvider = FutureProvider.autoDispose
    .family<List<PendingChatMember>, String>((ref, chatId) async {
      final repo = ref.read(pendingChatMembersRepositoryProvider);
      return await repo.getPendingMembers(chatId);
    });

/// All outstanding join requests across every chat the current user
/// administers, grouped by chat (empty groups omitted). Feeds the app-wide
/// pending-requests overview and its badge. Auto-refreshes because each
/// per-chat [pendingMembersProvider] is invalidated by the realtime
/// `pendingMember` event.
final adminPendingRequestsProvider = Provider.autoDispose
    .family<List<PendingRequestGroup>, String>((ref, currentUserId) {
      final chats = ref.watch(chatsControllerProvider);
      final groups = <PendingRequestGroup>[];
      for (final chat in chats) {
        if (!chat.isAdmin(currentUserId)) continue;
        final pending = ref
                .watch(pendingMembersProvider(chat.id))
                .whenOrNull(data: (members) => members) ??
            const <PendingChatMember>[];
        if (pending.isNotEmpty) {
          groups.add((chat: chat, pending: pending));
        }
      }
      return groups;
    });

/// Total number of outstanding join requests across all administered chats —
/// the number shown on the overview badge.
final adminPendingCountProvider = Provider.autoDispose.family<int, String>((
  ref,
  currentUserId,
) {
  final groups = ref.watch(adminPendingRequestsProvider(currentUserId));
  return groups.fold<int>(0, (sum, g) => sum + g.pending.length);
});

/// The current user's OWN outstanding join requests (outgoing), across every
/// group they have asked to join — the "my requests" section of the overview
/// (Task #102). Enriched with the group name via the `get_my_pending_requests()`
/// RPC, which a plain `chats` SELECT would hide from a not-yet-member. Refreshed
/// on create/withdraw and when the user's membership changes (approval) — see
/// ChatsController._handleMembershipChanged / _handleResume.
final myPendingRequestsProvider = FutureProvider.autoDispose
    .family<List<MyPendingRequest>, String>((ref, currentUserId) async {
      final repo = ref.read(pendingChatMembersRepositoryProvider);
      return repo.getMyPendingRequests();
    });

/// Whether the pending-requests overview entry point should be shown at all —
/// true when there is anything to review: incoming requests to administer OR
/// the user's own outgoing requests. The numeric badge still reflects only the
/// actionable incoming count ([adminPendingCountProvider]); outgoing requests
/// make the entry reachable without inflating that action count.
final pendingOverviewVisibleProvider = Provider.autoDispose.family<bool, String>(
  (ref, currentUserId) {
    final incoming = ref.watch(adminPendingCountProvider(currentUserId));
    if (incoming > 0) return true;
    final outgoing = ref
            .watch(myPendingRequestsProvider(currentUserId))
            .whenOrNull(data: (r) => r.length) ??
        0;
    return outgoing > 0;
  },
);

/// Provider to check if user is admin
final isAdminProvider = FutureProvider.autoDispose
    .family<bool, ({String chatId, String userId})>((ref, params) async {
      final repo = ref.read(chatMembersRepositoryProvider);
      return await repo.isAdmin(chatId: params.chatId, userId: params.userId);
    });

/// Provider to check if user is member
final isMemberProvider = FutureProvider.autoDispose
    .family<bool, ({String chatId, String userId})>((ref, params) async {
      final repo = ref.read(chatMembersRepositoryProvider);
      return await repo.isMember(chatId: params.chatId, userId: params.userId);
    });

/// Provider to check if user is pending member
final isPendingMemberProvider = FutureProvider.autoDispose
    .family<bool, ({String chatId, String userId})>((ref, params) async {
      final repo = ref.read(pendingChatMembersRepositoryProvider);
      return await repo.isPendingMember(
        chatId: params.chatId,
        userId: params.userId,
      );
    });

/// Provider to get user's membership status
/// Returns ChatMember if user is an active member, null otherwise
final membershipStatusProvider = FutureProvider.autoDispose
    .family<ChatMember?, ({String chatId, String userId})>((ref, params) async {
      final repo = ref.read(chatMembersRepositoryProvider);
      return await repo.getMembershipStatus(
        chatId: params.chatId,
        userId: params.userId,
      );
    });

/// Provider to get user's pending membership status
/// Returns PendingChatMember if user has a pending request, null otherwise
final pendingMembershipStatusProvider = FutureProvider.autoDispose
    .family<PendingChatMember?, ({String chatId, String userId})>((
      ref,
      params,
    ) async {
      final repo = ref.read(pendingChatMembersRepositoryProvider);
      return await repo.getUserPendingStatus(
        chatId: params.chatId,
        userId: params.userId,
      );
    });

/// Controller for chat member actions
class ChatMembersController {
  final Ref _ref;
  final ChatMembersRepository _repo;
  final PendingChatMembersRepository _pendingRepo;

  ChatMembersController(this._ref, this._repo, this._pendingRepo);

  /// Add a member to a chat
  Future<void> addMember({
    required String chatId,
    required String userId,
  }) async {
    await _repo.addMember(chatId: chatId, userId: userId);
    // Invalidate cache to refresh
    invalidateProviders(chatId, userId);
  }

  /// Remove a member from a chat
  Future<void> removeMember({
    required String chatId,
    required String userId,
  }) async {
    await _repo.removeMember(chatId: chatId, userId: userId);
    // Invalidate cache to refresh
    invalidateProviders(chatId, userId);
  }

  /// Leave a chat (remove self)
  Future<void> leaveChat({
    required String chatId,
    required String currentUserId,
  }) async {
    await _repo.removeMember(chatId: chatId, userId: currentUserId);
    // Invalidate cache to refresh
    invalidateProviders(chatId, currentUserId);
  }

  /// Promote a user to admin
  Future<void> promoteToAdmin({
    required String chatId,
    required String userId,
  }) async {
    await _repo.promoteToAdmin(chatId: chatId, userId: userId);
    invalidateProviders(chatId, userId);
    // Invalidate admin status cache
    // _ref.invalidate(isAdminProvider((chatId: chatId, userId: userId)));
    // Invalidate membership status cache
    // _ref.invalidate(membershipStatusProvider((chatId: chatId, userId: userId)));
  }

  /// Demote a user from admin
  Future<void> demoteFromAdmin({
    required String chatId,
    required String userId,
  }) async {
    await _repo.demoteFromAdmin(chatId: chatId, userId: userId);
    invalidateProviders(chatId, userId);
    // Invalidate admin status cache
    // _ref.invalidate(isAdminProvider((chatId: chatId, userId: userId)));
    // Invalidate membership status cache
    // _ref.invalidate(membershipStatusProvider((chatId: chatId, userId: userId)));
  }

  /// Request to join a chat (creates pending membership)
  Future<void> requestToJoin({
    required String chatId,
    required String userId,
    required String publicKey,
  }) async {
    await _pendingRepo.requestToJoin(
      chatId: chatId,
      userId: userId,
      publicKey: publicKey,
    );
    // Invalidate caches to refresh
    invalidateProviders(chatId, userId);
  }

  /// Like [requestToJoin], but first checks whether the caller is already a
  /// member or already has a pending request — so the UI can tell them
  /// ("you're already in this group") instead of silently creating a duplicate
  /// pending row or a confusing no-op.
  ///
  /// [generatePublicKey] is called only when a request is actually needed, so
  /// an existing member does NOT get their chat keys spuriously regenerated
  /// (which would rotate keys and emit a "new keys" system message).
  Future<JoinRequestOutcome> requestToJoinChecked({
    required String chatId,
    required String userId,
    required Future<String?> Function() generatePublicKey,
  }) async {
    if (await _repo.isMember(chatId: chatId, userId: userId)) {
      return JoinRequestOutcome.alreadyMember;
    }
    if (await _pendingRepo.isPendingMember(chatId: chatId, userId: userId)) {
      return JoinRequestOutcome.alreadyPending;
    }
    final publicKey = await generatePublicKey();
    if (publicKey == null) {
      throw Exception('Failed to generate key pair');
    }
    await _pendingRepo.requestToJoin(
      chatId: chatId,
      userId: userId,
      publicKey: publicKey,
    );
    invalidateProviders(chatId, userId);
    return JoinRequestOutcome.requested;
  }

  /// Approve a pending member (admin only)
  Future<void> approveMember({
    required String chatId,
    required String userId,
    required String publicKey,
  }) async {
    await _pendingRepo.approveMember(
      chatId: chatId,
      userId: userId,
      publicKey: publicKey,
    );
    // Invalidate caches to refresh
    invalidateProviders(chatId, userId);
  }

  /// Reject a pending member (admin only)
  Future<void> rejectMember({
    required String chatId,
    required String userId,
  }) async {
    await _pendingRepo.rejectMember(chatId: chatId, userId: userId);
    // Invalidate caches to refresh
    invalidateProviders(chatId, userId);
  }

  /// Block a pending member (admin only)
  Future<void> blockMember({
    required String chatId,
    required String userId,
  }) async {
    await _pendingRepo.blockMember(chatId: chatId, userId: userId);
    // Invalidate caches to refresh
    invalidateProviders(chatId, userId);
  }

  /// Withdraw the caller's own pending join request (surfaced in the pending
  /// overview's "my requests" section, Task #102). RLS ("Users can withdraw own
  /// pending request", 00012) permits this only for the caller's OWN row and
  /// only while it is NOT blocked — a blocked request stays put, and its primary
  /// key blocks a fresh re-request, so this is not a spam vector.
  Future<void> cancelRequest({
    required String chatId,
    required String userId,
  }) async {
    await _pendingRepo.cancelRequest(chatId: chatId, userId: userId);
    // Invalidate caches to refresh
    invalidateProviders(chatId, userId);
  }

  void invalidateProviders(String chatId, [String? userId]) {
    _ref.invalidate(chatMembersProvider(chatId));
    _ref.invalidate(pendingMembersProvider(chatId));
    final providers = [
      membershipStatusProvider,
      membershipStatusProvider,
      pendingMembershipStatusProvider,
      isMemberProvider,
      isAdminProvider,
      isPendingMemberProvider,
    ];
    for (final provider in providers) {
      if (userId == null) {
        _ref.invalidate(provider);
      } else {
        final args = (chatId: chatId, userId: userId);
        _ref.invalidate(provider(args));
      }
    }
  }
}

final chatMembersControllerProvider = Provider<ChatMembersController>((ref) {
  final repo = ref.read(chatMembersRepositoryProvider);
  final pendingRepo = ref.read(pendingChatMembersRepositoryProvider);
  return ChatMembersController(ref, repo, pendingRepo);
});
