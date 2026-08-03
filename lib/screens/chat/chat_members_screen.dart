// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../core/navigation/app_page_route.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../core/logging/logger_service.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/chats/chat_model.dart';
import '../../features/chats/chat_members_controller.dart';
import '../../features/chats/chats_controller.dart';
import '../../features/identity/identity_verification_controller.dart';
import '../../features/identity/identity_verification_repository.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/widgets/profile_info_sheet.dart';
import '../../features/profiles/widgets/user_avatar.dart';
import '../identity/safety_number_screen.dart';
import '../qr/group_chat_qr_display.dart';
import '../qr/qr_scanner_screen.dart';

class ChatMembersScreen extends ConsumerStatefulWidget {
  final Chat chat;

  const ChatMembersScreen({super.key, required this.chat});

  @override
  ConsumerState<ChatMembersScreen> createState() => _ChatMembersScreenState();
}

class _ChatMembersScreenState extends ConsumerState<ChatMembersScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = ref.watch(authControllerProvider);
    // Watch the live chat (not the constructor snapshot) so admin badges and
    // the promote/demote menu update in place: promote/demote writes chats.admins,
    // the `chatUpdate` realtime event triggers refreshChats, and this rebuilds.
    final chats = ref.watch(chatsControllerProvider);
    final chat =
        chats.where((c) => c.id == widget.chat.id).firstOrNull ?? widget.chat;
    final isAdmin = currentUserId != null && chat.isAdmin(currentUserId);
    final membersAsync = ref.watch(chatMembersProvider(widget.chat.id));
    // E2E trust state per member (audit C1) — drives the shield badges below.
    final verification =
        ref.watch(chatVerificationProvider(widget.chat.id)).asData?.value;

    return Scaffold(
      appBar: AppBar(
        title: Text('chat_members.title'.tr()),
        actionsPadding: const EdgeInsets.symmetric(horizontal: 16),
        actions: [
          if (isAdmin)
            IconButton(
              icon: const Icon(Icons.person_add),
              onPressed: () => _showAddMemberDialog(context, ref),
              tooltip: 'chat_members.add_member'.tr(),
            ),
        ],
      ),
      body: membersAsync.when(
        data: (memberIds) {
          if (memberIds.isEmpty) {
            return Center(child: Text('chat_members.empty'.tr()));
          }

          final query = _searchQuery.toLowerCase();
          final queryParts = query
              .split(' ')
              .where((part) => part.isNotEmpty)
              .toList();

          // Filter members by search query
          final filteredMembers = _searchQuery.isEmpty
              ? memberIds
              : memberIds.where((memberId) {
                  final username = ref
                      .read(optionalUsernameProvider(memberId))
                      ?.toLowerCase();
                  if (username == null) return false;
                  return queryParts.any((part) => username.contains(part));
                  // final usernameParts = username?.split(' ').where((part) => part.isNotEmpty).toList() ?? [];
                  // return username?.toLowerCase().contains(query) ?? false;
                  // return queryParts.any((part) {
                  //   return username?.contains(part) ?? false ||
                  //       usernameParts.any((usernamePart) => usernamePart.contains(part));
                  // });
                }).toList();

          return Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'chat_members.search_hint'.tr(),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                              });
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                ),
              ),
              // Members list
              Expanded(
                child: filteredMembers.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.search_off,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'chat_members.no_results'.tr(),
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: filteredMembers.length,
                        itemBuilder: (context, index) {
                          final memberId = filteredMembers[index];
                          return _buildMemberTile(
                            context,
                            ref,
                            memberId,
                            isAdmin,
                            currentUserId,
                            chat,
                            verification?.peers[memberId],
                          );
                        },
                      ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text('common.error'.tr(args: [err.toString()])),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMemberTile(
    BuildContext context,
    WidgetRef ref,
    String memberId,
    bool isCurrentUserAdmin,
    String? currentUserId,
    Chat chat,
    IdentityVerificationState? trust,
  ) {
    final profile = ref.watch(profileProvider(memberId));
    final isMemberAdmin = chat.isAdmin(memberId);
    final isSelf = memberId == currentUserId;

    if (profile == null) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ListTile(
          leading: const CircleAvatar(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          title: Text('common.loading'.tr()),
        ),
      );
    }

    final memberTileKey = GlobalKey<PopupMenuButtonState<String>>();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAliasWithSaveLayer,
      child: ListTile(
        // Tap the avatar → this member's profile sheet (avatar, verify, info),
        // matching the chat-list/header behaviour. The row's own onTap stays the
        // admin action menu. Shared reactive [UserAvatar] shows the uploaded
        // picture when present; its picture-less fallback keeps the cryptographic
        // identity color (audit M2) so same-named members stay visibly distinct.
        // (Admin status stays visible via the separate amber "Admin" badge.)
        leading: UserAvatar(
          userId: memberId,
          onTap: () => showProfileInfoSheet(
            context: context,
            chat: chat,
            displayName: profile.username,
            otherUserId: memberId,
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(profile.username, overflow: TextOverflow.ellipsis),
            ),
            if (isSelf) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  // Same saturated-pill + white-text recipe as the admin/verify
                  // badges so the three read as one consistent set.
                  color: Colors.blue.shade700,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'chat_members.you_badge'.tr(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
            if (isMemberAdmin) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  // Deep amber-orange so the white label + icon stay readable —
                  // plain Colors.amber left near-white text on bright yellow,
                  // illegible.
                  color: Colors.orange.shade900,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon matches the "Admin" label colour (both white).
                    const Icon(Icons.admin_panel_settings,
                        size: 12, color: Colors.white),
                    const SizedBox(width: 2),
                    Text(
                      'chat_members.admin_badge'.tr(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // E2E trust shield (audit C1): tap to open the safety-number
            // screen and verify this member out-of-band. Warn-only.
            if (!isSelf && trust != null) ...[
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  Navigator.push(
                    context,
                    appPageRoute<void>(
                      builder: (_) => SafetyNumberScreen(
                        userId: memberId,
                        username: profile.username,
                      ),
                    ),
                  );
                },
                child: Icon(
                  switch (trust) {
                    IdentityVerificationState.verified => Icons.verified_user,
                    IdentityVerificationState.changed => Icons.gpp_bad,
                    _ => Icons.shield_outlined,
                  },
                  size: 18,
                  color: switch (trust) {
                    IdentityVerificationState.verified => Colors.green,
                    IdentityVerificationState.changed => Colors.red,
                    _ => Colors.grey,
                  },
                ),
              ),
            ],
          ],
        ),
        subtitle: Text('ID: ${memberId.substring(0, 8)}...'),
        // Member management is a group concept — in a 1:1 chat neither party
        // manages the other (this screen is only reachable from groups, but
        // keep the guard as defense in depth).
        trailing: chat.isGroup && isCurrentUserAdmin && !isSelf
            ? PopupMenuButton<String>(
                key: memberTileKey,
                onSelected: (value) => _handleMemberAction(
                  context,
                  ref,
                  value,
                  memberId,
                  isMemberAdmin,
                  profile.username,
                ),
                itemBuilder: (context) => [
                  // Promote/Demote
                  if (isMemberAdmin)
                    PopupMenuItem(
                      value: 'demote',
                      child: Row(
                        children: [
                          const Icon(Icons.arrow_downward, size: 20),
                          const SizedBox(width: 8),
                          Text('chat_members.demote'.tr()),
                        ],
                      ),
                    )
                  else
                    PopupMenuItem(
                      value: 'promote',
                      child: Row(
                        children: [
                          const Icon(Icons.arrow_upward, size: 20),
                          const SizedBox(width: 8),
                          Text('chat_members.promote'.tr()),
                        ],
                      ),
                    ),
                  // Remove member
                  PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.person_remove,
                          size: 20,
                          color: Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'chat_members.remove'.tr(),
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : null,
        onTap: isCurrentUserAdmin && !isSelf
            ? () => memberTileKey.currentState?.showButtonMenu()
            : null,
      ),
    );
  }

  Future<void> _handleMemberAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    String memberId,
    bool isMemberAdmin,
    String? username,
  ) async {
    final controller = ref.read(chatMembersControllerProvider);

    try {
      switch (action) {
        case 'promote':
          await controller.promoteToAdmin(
            chatId: widget.chat.id,
            userId: memberId,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'chat_members.promoted_success'.tr(
                    args: [username ?? memberId],
                  ),
                ),
              ),
            );
          }
          break;
        case 'demote':
          await controller.demoteFromAdmin(
            chatId: widget.chat.id,
            userId: memberId,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'chat_members.demoted_success'.tr(
                    args: [username ?? memberId],
                  ),
                ),
              ),
            );
          }
          break;
        case 'remove':
          final confirmed = await _showConfirmDialog(
            context,
            'chat_members.confirm_remove_title'.tr(),
            'chat_members.confirm_remove_message'.tr(
              args: [username ?? memberId],
            ),
          );
          if (confirmed == true) {
            await controller.removeMember(
              chatId: widget.chat.id,
              userId: memberId,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'chat_members.removed_success'.tr(
                      args: [username ?? memberId],
                    ),
                  ),
                ),
              );
            }
          }
          break;
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('common.error'.tr(args: [e.toString()])),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showAddMemberDialog(BuildContext context, WidgetRef ref) {
    // E2E model: a new member generates their own per-chat key pair and
    // requests to join. The admin "adds" someone by sharing the group invite
    // (QR / chat-ID); they request to join and the admin approves it.
    logger.info('Add member: showing group invite for chat ${widget.chat.id}');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'chat_members.add_member'.tr(),
                style: Theme.of(sheetContext).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'chat_detail.add_member_hint'.tr(),
                style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                      color:
                          Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              // Admin scans a user's QR to add them directly. The added member
              // has no per-chat key yet; their app self-heals on next sight of
              // the group.
              OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: Text('chat_members.scan_to_add'.tr()),
                onPressed: () async {
                  Navigator.pop(sheetContext);
                  await Navigator.push<Map<String, dynamic>>(
                    context,
                    appPageRoute(
                      builder: (_) =>
                          QrScannerScreen(addToChatId: widget.chat.id),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 12),
              GroupChatQrDisplay(chat: widget.chat),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool?> _showConfirmDialog(
    BuildContext context,
    String title,
    String message,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('common.cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('common.confirm'.tr()),
          ),
        ],
      ),
    );
  }
}
