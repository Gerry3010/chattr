// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/chats/chat_members_controller.dart';
import '../../features/chats/pending_chat_member_model.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/widgets/user_avatar.dart';

/// App-wide overview of every outstanding join request across all groups the
/// current user administers. The per-chat requests also appear inside each
/// chat's detail screen; this is the single place to review them all without
/// opening each chat. Approve / reject / block reuse the same controller calls.
class PendingRequestsScreen extends ConsumerWidget {
  const PendingRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUserId = ref.watch(authControllerProvider);
    final groups = currentUserId == null
        ? const <PendingRequestGroup>[]
        : ref.watch(adminPendingRequestsProvider(currentUserId));
    // The user's OWN outgoing join requests (loading/error → empty; the section
    // simply doesn't appear until the RPC resolves).
    final myRequests = currentUserId == null
        ? const <MyPendingRequest>[]
        : ref
                .watch(myPendingRequestsProvider(currentUserId))
                .whenOrNull(data: (r) => r) ??
            const <MyPendingRequest>[];

    final isEmpty = groups.isEmpty && myRequests.isEmpty;
    // Only label the two sections when both are present — a pure-admin or
    // pure-requester view stays as clean as before (no redundant header).
    final showSectionHeaders = groups.isNotEmpty && myRequests.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: Text('pending_requests.title'.tr())),
      body: isEmpty
          ? _EmptyState()
          : ListView(
              children: [
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
