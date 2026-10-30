// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/chat_requests/chat_request_model.dart';
import '../../features/chat_requests/chat_requests_controller.dart';
import '../../features/chats/chat_members_controller.dart';
import '../../features/chats/pending_chat_member_model.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/widgets/user_avatar.dart';

/// App-wide overview of every outstanding join request across all groups the
/// current user administers. The per-chat requests also appear inside each
/// chat's detail screen; this is the single place to review them all without
/// opening each chat. Approve / reject / block reuse the same controller calls.
class PendingRequestsScreen extends ConsumerWidget {
  /// Narrowed to ONE chat (called from its info view). `null` = the account-
  /// wide overview as before.
  ///
  /// In chat mode the section "my own requests" falls away: about a group one
  /// is already in, one's own open request says nothing — it belongs in the
  /// overview, not here.
  final String? chatId;

  const PendingRequestsScreen({super.key, this.chatId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUserId = ref.watch(authControllerProvider);
    final alleGruppen = currentUserId == null
        ? const <PendingRequestGroup>[]
        : ref.watch(adminPendingRequestsProvider(currentUserId));
    final groups = chatId == null
        ? alleGruppen
        : alleGruppen.where((g) => g.chat.id == chatId).toList();
    // The user's OWN outgoing join requests (loading/error → empty; the section
    // simply doesn't appear until the RPC resolves).
    final myRequests = (currentUserId == null || chatId != null)
        ? const <MyPendingRequest>[]
        : ref
                .watch(myPendingRequestsProvider(currentUserId))
                .whenOrNull(data: (r) => r) ??
            const <MyPendingRequest>[];

    // Chat requests (00082) live here too rather than opening a second inbox:
    // from the user's point of view both are the same — somebody wants access,
    // and one decides. A button of its own with its own badge beside it would
    // be two routes for one question. Only in account-wide mode; the chat-
    // scoped view shows joins to ONE group.
    final chatRequests = chatId != null
        ? const <IncomingChatRequest>[]
        : ref.watch(incomingChatRequestsProvider).asData?.value ??
            const <IncomingChatRequest>[];

    final isEmpty =
        groups.isEmpty && myRequests.isEmpty && chatRequests.isEmpty;
    // Only label the two sections when both are present — a pure-admin or
    // pure-requester view stays as clean as before (no redundant header).
    final showSectionHeaders = [
          groups.isNotEmpty,
          myRequests.isNotEmpty,
          chatRequests.isNotEmpty,
        ].where((v) => v).length >
        1;

    return Scaffold(
      appBar: AppBar(title: Text('pending_requests.title'.tr())),
      body: isEmpty
          ? _EmptyState()
          : ListView(
              children: [
                if (chatRequests.isNotEmpty) ...[
                  if (showSectionHeaders)
                    _SectionHeader(
                      icon: Icons.chat_bubble_outline,
                      label: 'chat_requests.section'.tr(),
                    ),
                  for (final request in chatRequests)
                    _ChatRequestTile(request: request),
                  const Divider(height: 1),
                ],
                if (myRequests.isNotEmpty && currentUserId != null) ...[
                  if (showSectionHeaders)
                    _SectionHeader(
                      icon: Icons.outbox_outlined,
                      label: 'pending_requests.my_requests_section'.tr(),
                    ),
                  for (final request in myRequests)
                    _MyRequestTile(
                      request: request,
                      currentUserId: currentUserId,
                    ),
                  const Divider(height: 1),
                ],
                if (groups.isNotEmpty) ...[
                  if (showSectionHeaders)
                    _SectionHeader(
                      icon: Icons.inbox_outlined,
                      label: 'pending_requests.incoming_section'.tr(),
                    ),
                  for (final group in groups) ...[
                    if (chatId == null)
                      _ChatHeader(name: _chatTitle(context, group)),
                    for (final member in group.pending)
                      _PendingMemberTile(
                        chatId: group.chat.id,
                        member: member,
                      ),
                    const Divider(height: 1),
                  ],
                ],
              ],
            ),
    );
  }

  String _chatTitle(BuildContext context, PendingRequestGroup group) {
    final chat = group.chat;
    if (chat.isGroup && (chat.name?.isNotEmpty ?? false)) return chat.name!;
    return 'chat_list.chat_title'.tr(args: [chat.id.substring(0, 8)]);
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inbox_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            'pending_requests.empty'.tr(),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(
            Icons.group,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingMemberTile extends ConsumerWidget {
  const _PendingMemberTile({required this.chatId, required this.member});

  final String chatId;
  final PendingChatMember member;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider(member.userId));

    return ListTile(
      leading: UserAvatar(userId: member.userId, radius: 20),
      title: Text(profile?.username ?? 'chat_detail.unknown_user'.tr()),
      subtitle: Text(
        'chat_detail.requested'.tr(
          namedArgs: {'time': _formatDate(member.createdAt)},
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.check, color: Colors.green),
            tooltip: 'chat_detail.accept_request'.tr(),
            onPressed: () => _accept(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.red),
            tooltip: 'chat_detail.reject_request'.tr(),
            onPressed: () => _reject(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.block, color: Colors.deepOrange),
            tooltip: 'chat_detail.block_request'.tr(),
            onPressed: () => _block(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _accept(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(chatMembersControllerProvider);
    try {
      await controller.approveMember(
        chatId: chatId,
        userId: member.userId,
        publicKey: member.publicKey,
      );
      _toast(messenger, 'chat_detail.request_accepted'.tr());
    } catch (e) {
      _toast(messenger, 'common.error'.tr(args: [e.toString()]));
    }
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(chatMembersControllerProvider);
    try {
      await controller.rejectMember(chatId: chatId, userId: member.userId);
      _toast(messenger, 'chat_detail.request_rejected'.tr());
    } catch (e) {
      _toast(messenger, 'common.error'.tr(args: [e.toString()]));
    }
  }

  Future<void> _block(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(chatMembersControllerProvider);
    try {
      await controller.blockMember(chatId: chatId, userId: member.userId);
      ref.invalidate(pendingMembersProvider(chatId));
      _toast(messenger, 'chat_detail.request_blocked'.tr());
    } catch (e) {
      _toast(messenger, 'common.error'.tr(args: [e.toString()]));
    }
  }

  void _toast(ScaffoldMessengerState messenger, String msg) {
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatDate(DateTime date) {
    final l = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }
}

/// An open chat request: somebody wants a 1:1 with me.
///
/// Name and picture come from the row, NOT from `profileProvider` — as long as
/// it has not been accepted we share no chat, and the profile view (00046) does
/// not hand out a stranger's profile. Whoever looks it up here gets a "?"
/// circle without a name.
class _ChatRequestTile extends ConsumerWidget {
  const _ChatRequestTile({required this.request});

  final IncomingChatRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: UserAvatar(
        userId: request.requesterId,
        radius: 20,
        overrideUsername: request.username,
        overrideAvatarPath: request.avatarPath,
        overrideIdentityKey: request.identityPublicKey,
      ),
      title: Text(request.username),
      subtitle: Text('chat_requests.wants_to_chat'.tr()),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.check, color: Colors.green),
            tooltip: 'chat_requests.accept'.tr(),
            onPressed: () => _decide(context, ref, accept: true),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.red),
            tooltip: 'chat_requests.decline'.tr(),
            onPressed: () => _decide(context, ref, accept: false),
          ),
          IconButton(
            icon: const Icon(Icons.block, color: Colors.deepOrange),
            tooltip: 'chat_requests.decline_and_block'.tr(),
            onPressed: () => _decide(context, ref, accept: false, block: true),
          ),
        ],
      ),
    );
  }

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref, {
    required bool accept,
    bool block = false,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(incomingChatRequestsProvider.notifier);
    try {
      if (accept) {
        await controller.accept(request.requesterId);
        messenger.showSnackBar(
          SnackBar(content: Text('chat_requests.accepted'.tr())),
        );
      } else {
        await controller.decline(request.requesterId, block: block);
        // Deliberately WITHOUT feedback to the other party — and the message
        // here therefore does not say "rejected" either, only that it is gone.
        messenger.showSnackBar(
          SnackBar(content: Text('chat_requests.dismissed'.tr())),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: [e.toString()]))),
      );
    }
  }
}

/// Section divider label for the overview when it holds both the user's own
/// outgoing requests and incoming requests to administer.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                  letterSpacing: 0.6,
                ),
          ),
        ],
      ),
    );
  }
}

/// One of the current user's OWN outgoing join requests: which group, when it
/// was asked, and — unless it was blocked — a button to withdraw it.
class _MyRequestTile extends ConsumerWidget {
  const _MyRequestTile({required this.request, required this.currentUserId});

  final MyPendingRequest request;
  final String currentUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final name = (request.chatName?.isNotEmpty ?? false)
        ? request.chatName!
        : 'chat_list.chat_title'.tr(args: [request.chatId.substring(0, 8)]);
    final blocked = request.isBlocked;

    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: scheme.secondaryContainer,
        child: Icon(
          request.isGroup ? Icons.group : Icons.person,
          color: scheme.onSecondaryContainer,
        ),
      ),
      title: Text(name),
      subtitle: Text(
        blocked
            ? 'pending_requests.blocked_status'.tr()
            : 'chat_detail.requested'.tr(
                namedArgs: {'time': _formatDate(request.createdAt)},
              ),
        style: blocked ? TextStyle(color: scheme.error) : null,
      ),
      trailing: blocked
          ? Icon(Icons.block, color: scheme.error)
          : OutlinedButton(
              onPressed: () => _withdraw(context, ref),
              child: Text('pending_requests.withdraw'.tr()),
            ),
    );
  }

  Future<void> _withdraw(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('pending_requests.withdraw_confirm_title'.tr()),
        content: Text('pending_requests.withdraw_confirm_body'.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('common.cancel'.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('pending_requests.withdraw'.tr()),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final controller = ref.read(chatMembersControllerProvider);
    try {
      await controller.cancelRequest(
        chatId: request.chatId,
        userId: currentUserId,
      );
      ref.invalidate(myPendingRequestsProvider(currentUserId));
      messenger.showSnackBar(
        SnackBar(content: Text('pending_requests.withdrawn'.tr())),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: [e.toString()]))),
      );
    }
  }

  String _formatDate(DateTime date) {
    final l = date.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.day)}.${two(l.month)}.${l.year} ${two(l.hour)}:${two(l.minute)}';
  }
}
