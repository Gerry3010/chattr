// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/chats/chats.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../core/navigation/app_page_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/logging/logger_service.dart';
import '../../core/utils/app_time.dart';
import '../../core/utils/ttl_format.dart';
import '../../features/auth/auth_controller.dart';
import '../../features/blocks/blocked_users_repository.dart';
import '../../features/share_suggestions/share_suggestions_channel.dart';
import '../../features/chats/mute_controller.dart';
import '../../features/chats/pending_chat_member_model.dart';
import '../../features/chats/report_controller.dart';
import '../../features/reports/reports_repository.dart';
import '../../features/chats/group_avatar_actions.dart';
import '../../features/chats/widgets/group_avatar.dart';
import '../../features/profiles/profile_helpers.dart';
import '../../features/profiles/widgets/user_avatar.dart';
import '../../features/agents/main_agent_store.dart';
import '../../features/invites/invites_controller.dart';
import '../qr/group_chat_qr_display.dart';
import 'chat_members_screen.dart';
import 'components/forward_chat_sheet.dart';
import 'components/mute_sheet.dart';

class ChatDetailScreen extends HookConsumerWidget {
  final Chat chat;

  const ChatDetailScreen({super.key, required this.chat});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatNameController = useTextEditingController(text: chat.name);
    final descriptionController =
        useTextEditingController(text: chat.description);
    // Admin name/description are read-only until the pencil unlocks them; then
    // Save/Cancel icons commit or discard the edit (toggle UI).
    final editingName = useState(false);
    final editingDescription = useState(false);
    final currentUserId = ref.watch(authControllerProvider);
    final isAdmin = currentUserId != null && chat.isAdmin(currentUserId);
    final membersAsync = ref.watch(chatMembersProvider(chat.id));
    // Watch the live chat so settings (e.g. the disappearing-messages TTL)
    // reflect updates instead of the static value passed into the route.
    final liveChat = ref.watch(chatProvider(chat.id)) ?? chat;

    return Scaffold(
      appBar: AppBar(
        title: Text('chat_detail.title'.tr()),
        actions: [
          // Settings/Options menu
          PopupMenuButton<String>(
            onSelected: (value) =>
                _handleMenuAction(context, ref, value, currentUserId),
            itemBuilder: (context) => [
              // Mute / unmute (all members)
              PopupMenuItem(
                value: 'mute',
                child: Consumer(
                  builder: (context, ref, _) {
                    final muted = ref.watch(chatIsMutedProvider(chat.id));
                    final until = ref
                        .read(mutedChatsProvider.notifier)
                        .mutedUntil(chat.id);
                    return ListTile(
                      leading: Icon(muted
                          ? Icons.notifications_off
                          : Icons.notifications),
                      title: Text((muted
                              ? 'chat_detail.unmute'
                              : 'chat_detail.mute')
                          .tr()),
                      subtitle: muted && until != null
                          ? Text('chat_detail.muted_until'
                              .tr(args: [formatMuteUntil(context, until)]))
                          : null,
                      contentPadding: EdgeInsets.zero,
                    );
                  },
                ),
              ),
              // Report (mutes + records locally)
              PopupMenuItem(
                value: 'report',
                child: ListTile(
                  leading: const Icon(Icons.flag_outlined, color: Colors.orange),
                  title: Text('chat_detail.report_user'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              // Rotate my key for this chat (all members)
              PopupMenuItem(
                value: 'rotate_key',
                child: ListTile(
                  leading: const Icon(Icons.key),
                  title: Text('chat_detail.rotate_key'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              // Leave chat
              PopupMenuItem(
                value: 'leave',
                child: ListTile(
                  leading: const Icon(Icons.exit_to_app),
                  title: Text('chat_detail.leave_chat'.tr()),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              // Delete chat (admin only)
              if (isAdmin)
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: const Icon(Icons.delete, color: Colors.red),
                    title: Text(
                      'chat_detail.delete_chat'.tr(),
                      style: const TextStyle(color: Colors.red),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          spacing: 16,
          children: [
            // 1:1 header: the peer's avatar (tappable → large viewer, #156)
            // and name. A direct chat has no member list — the two fixed
            // participants are self + this peer — so this replaces it (#157).
            if (!chat.isGroup && currentUserId != null)
              membersAsync.maybeWhen(
                data: (memberIds) {
                  final otherId = memberIds
                      .where((id) => id != currentUserId)
                      .firstOrNull;
                  if (otherId == null) return const SizedBox.shrink();
                  return _build1on1Header(context, ref, otherId);
                },
                orElse: () => const SizedBox.shrink(),
              ),

            // Group header: the group avatar (00055). Admins get a camera badge
            // to change/remove it; others just see the picture (or group icon).
            if (chat.isGroup)
              _buildGroupAvatarHeader(context, ref, liveChat, isAdmin),

            // Chat Info Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'chat_detail.info'.tr(),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    // Group name — its own full-width block (was squeezed into
                    // a narrow inline Row). Admins edit; others see it prominent.
                    if (chat.isGroup)
                      _buildInfoBlock(
                        context,
                        Icons.title,
                        'chat_detail.chat_name'.tr(),
                        child: isAdmin
                            ? (editingName.value
                                // Edit mode: unlocked field + Save/Cancel icons.
                                ? Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: chatNameController,
                                          autofocus: true,
                                          maxLines: 1,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium,
                                          decoration: InputDecoration(
                                            hintText: liveChat.name?.trim(),
                                            isDense: true,
                                          ),
                                          onSubmitted: (_) {
                                            final save = _updateChat(
                                                ref, chatNameController.text);
                                            if (save != null) {
                                              save();
                                              editingName.value = false;
                                            }
                                          },
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.check),
                                        color: Colors.green,
                                        tooltip:
                                            'chat_detail.save_changes'.tr(),
                                        onPressed: () {
                                          final save = _updateChat(
                                              ref, chatNameController.text);
                                          if (save != null) {
                                            save();
                                            editingName.value = false;
                                          }
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.close),
                                        tooltip: 'chat_detail.cancel'.tr(),
                                        onPressed: () {
                                          chatNameController.text =
                                              liveChat.name ?? '';
                                          editingName.value = false;
                                        },
                                      ),
                                    ],
                                  )
                                // View mode: value + a pencil to start editing.
                                : Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          (liveChat.name?.trim().isNotEmpty ??
                                                  false)
                                              ? liveChat.name!.trim()
                                              : 'chat_detail.chat_name'.tr(),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                  fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit, size: 20),
                                        tooltip: 'chat_detail.edit'.tr(),
                                        onPressed: () {
                                          chatNameController.text =
                                              liveChat.name ?? '';
                                          editingName.value = true;
                                        },
                                      ),
                                    ],
                                  ))
                            : Text(
                                chat.name ?? '',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                      ),
                    // Description / topic (groups) — full-width block. Admins
                    // edit inline; others see up to 4 lines + a "more…" link
                    // that opens the full text in a scrollable sheet.
                    if (chat.isGroup &&
                        (isAdmin ||
                            (liveChat.description?.trim().isNotEmpty ??
                                false))) ...[
                      const SizedBox(height: 16),
                      _buildInfoBlock(
                        context,
                        Icons.notes,
                        'chat_detail.description'.tr(),
                        child: isAdmin
                            ? (editingDescription.value
                                // Edit mode: unlocked multiline field + Save/Cancel.
                                ? Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      TextField(
                                        controller: descriptionController,
                                        autofocus: true,
                                        maxLines: null,
                                        decoration: InputDecoration(
                                          hintText:
                                              'chat_detail.description_hint'
                                                  .tr(),
                                          isDense: true,
                                        ),
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.check),
                                            color: Colors.green,
                                            tooltip:
                                                'chat_detail.save_changes'.tr(),
                                            onPressed: () async {
                                              await ref
                                                  .read(chatsControllerProvider
                                                      .notifier)
                                                  .updateChatDescription(
                                                    chat: liveChat,
                                                    newDescription:
                                                        descriptionController
                                                            .text,
                                                  );
                                              editingDescription.value = false;
                                              if (context.mounted) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                        'chat_detail.description_updated'
                                                            .tr()),
                                                    backgroundColor:
                                                        Colors.green,
                                                  ),
                                                );
                                              }
                                            },
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.close),
                                            tooltip: 'chat_detail.cancel'.tr(),
                                            onPressed: () {
                                              descriptionController.text =
                                                  liveChat.description ?? '';
                                              editingDescription.value = false;
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  )
                                // View mode: trimmed text (or hint) + pencil.
                                : Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: (liveChat.description
                                                    ?.trim()
                                                    .isNotEmpty ??
                                                false)
                                            ? _TrimmedDescription(
                                                liveChat.description!)
                                            : Text(
                                                'chat_detail.description_hint'
                                                    .tr(),
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .hintColor),
                                              ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit, size: 20),
                                        tooltip: 'chat_detail.edit'.tr(),
                                        onPressed: () {
                                          descriptionController.text =
                                              liveChat.description ?? '';
                                          editingDescription.value = true;
                                        },
                                      ),
                                    ],
                                  ))
                            : _TrimmedDescription(liveChat.description ?? ''),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _buildInfoRow(
                      context,
                      Icons.schedule,
                      'chat_detail.created'.tr(),
                      value: _formatDate(context, chat.createdAt),
                    ),
                    if (chat.createdBy != null) ...[
                      const SizedBox(height: 8),
                      _buildCreatorRow(context, ref, chat.createdBy!),
                    ],
                  ],
                ),
              ),
            ),

            // Group QR Code (only for group chats)
            if (chat.isGroup) GroupChatQrDisplay(chat: chat),

            // Disappearing messages (self-destruct TTL)
            Card(
              child: ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text('chat_detail.disappearing_messages'.tr()),
                subtitle: Text(_ttlLabel(liveChat.messageTtlSeconds)),
                trailing:
                    isAdmin ? const Icon(Icons.chevron_right) : null,
                onTap: isAdmin
                    ? () => _showTtlPicker(context, ref, liveChat)
                    : null,
              ),
            ),

            // Pending Requests Section (only for group chat admins)
            if (chat.isGroup && isAdmin)
              _buildPendingRequestsSection(context, ref),

            // Active invitation messages (1.13) — admins can revoke them.
            if (chat.isGroup && isAdmin)
              _buildInvitesSection(context, ref),

            // Members Section — groups only. A 1:1 chat has exactly two fixed
            // participants (self + peer), shown by the header above (#157).
            if (chat.isGroup)
              Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'chat_detail.members'.tr(),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        // Member management is a group concept — a 1:1 chat
                        // has exactly two fixed participants.
                        if (chat.isGroup && isAdmin)
                          IconButton(
                            icon: const Icon(Icons.person_add),
                            onPressed: () => _showAddMemberDialog(context, ref),
                            tooltip: 'chat_detail.add_member'.tr(),
                          ),
                      ],
                    ),
                  ),
                  membersAsync.when(
                    data: (memberIds) {
                      // Agents and humans are listed separately (1.13): the
                      // grouping is display-only (profiles.is_agent), but a
                      // model in the member list is something one wants to SEE
                      // at a glance, not discover.
                      final agentIds = memberIds
                          .where((id) =>
                              ref.watch(profileProvider(id))?.isAgent ?? false)
                          .toList();
                      final humanIds = memberIds
                          .where((id) => !agentIds.contains(id))
                          .toList();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Column(
                            spacing: 8,
                            children: humanIds
                                .map(
                                  (memberId) => _buildMemberTile(
                                    context,
                                    ref,
                                    memberId,
                                    isAdmin,
                                    currentUserId,
                                  ),
                                )
                                .toList(),
                          ),
                          if (agentIds.isNotEmpty) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(
                                'chat_detail.agents'.tr(),
                                style:
                                    Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            Column(
                              spacing: 8,
                              children: agentIds
                                  .map(
                                    (memberId) => _buildMemberTile(
                                      context,
                                      ref,
                                      memberId,
                                      isAdmin,
                                      currentUserId,
                                      isAgentSection: true,
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ],
                      );
                    },
                    loading: () => Padding(
                      padding: const EdgeInsets.all(16),
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                    error: (err, _) => Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('common.error'.tr(args: [err.toString()])),
                    ),
                  ),
                  if (membersAsync.hasValue && chat.isGroup)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            appPageRoute<void>(
                              builder: (_) => ChatMembersScreen(chat: chat),
                            ),
                          );
                        },
                        child: Text('chat_detail.view_all_members'.tr()),
                      ),
                    ),
                ],
              ),
            ),

            // Block (1:1 only): blocks the counterpart at the DB level and
            // leaves the chat. Unblock lives in Settings → Blocked users.
            if (!chat.isGroup && currentUserId != null)
              membersAsync.maybeWhen(
                data: (memberIds) {
                  final otherId = memberIds
                      .where((id) => id != currentUserId)
                      .firstOrNull;
                  if (otherId == null) return const SizedBox.shrink();
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.block, color: Colors.red),
                      title: Text(
                        'chat_detail.block_user'.tr(),
                        style: const TextStyle(color: Colors.red),
                      ),
                      onTap: () =>
                          _blockUser(context, ref, otherId, currentUserId),
                    ),
                  );
                },
                orElse: () => const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _blockUser(
    BuildContext context,
    WidgetRef ref,
    String otherUserId,
    String currentUserId,
  ) async {
    final otherName =
        ref.read(profileProvider(otherUserId))?.username ?? otherUserId;
    final confirmed = await _showConfirmDialog(
      context,
      'chat_detail.block_confirm_title'.tr(args: [otherName]),
      'chat_detail.block_confirm_message'.tr(args: [otherName]),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      // Block first (from now on the pair can't message / re-create a 1:1),
      // then leave — the leave trigger hands the chat to the other member or
      // deletes it when empty.
      await ref.read(blockedUsersRepositoryProvider).block(otherUserId);
      await ref.read(chatMembersControllerProvider).leaveChat(
            chatId: chat.id,
            currentUserId: currentUserId,
          );
      // Drop the iOS Share-Suggestions donation for the blocked 1:1 chat.
      await ShareSuggestionsChannel.deleteConversations([chat.id]);
      if (context.mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text('chat_detail.blocked_success'.tr(args: [otherName])),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('common.error'.tr(args: ['$e']))),
      );
    }
  }

  VoidCallback? _updateChat(WidgetRef ref, String newName) {
    newName = newName.trim();
    final canSave = newName.isNotEmpty && newName.length >= 2;
    return canSave
        ? () async {
            final controller = ref.read(chatsControllerProvider.notifier);
            await controller.updateChatName(
              chat: chat,
              newName: newName,
            );
            if (ref.context.mounted) {
              ScaffoldMessenger.of(ref.context).showSnackBar(
                SnackBar(content: Text('chat_detail.name_updated'.tr()),
                backgroundColor: Colors.green,),
              );
            }
          }
        : null;
  }

  /// The 1:1 header: the peer's avatar (tap → large viewer) + their name,
  /// standing in for the (meaningless) two-row member list in a direct chat.
  Widget _build1on1Header(BuildContext context, WidgetRef ref, String otherId) {
    final profile = ref.watch(profileProvider(otherId));
    final name = profile?.username ?? 'chat_detail.unknown_user'.tr();
    return Column(
      children: [
        UserAvatar(
          userId: otherId,
          radius: 56,
          onTap: () => showAvatarViewer(context, otherId),
        ),
        const SizedBox(height: 12),
        Text(
          name,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ],
    );
  }

  /// Group avatar header (00055): a large [GroupAvatar]. Admins get a camera
  /// badge to change/remove the picture; non-admins just see it.
  Widget _buildGroupAvatarHeader(
    BuildContext context,
    WidgetRef ref,
    Chat chat,
    bool isAdmin,
  ) {
    final avatar = GroupAvatar(
      chatId: chat.id,
      radius: 56,
      onTap: () => showGroupAvatarViewer(context, chat.id),
    );
    if (!isAdmin) return Column(children: [avatar]);
    return Column(
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            avatar,
            Material(
              color: Theme.of(context).colorScheme.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _showGroupAvatarActions(context, ref, chat),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child:
                      Icon(Icons.photo_camera, size: 18, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _showGroupAvatarActions(
    BuildContext context,
    WidgetRef ref,
    Chat chat,
  ) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text('chat_detail.avatar_camera'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                captureAndUploadGroupAvatar(context, ref, chat);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text('chat_detail.avatar_change'.tr()),
              onTap: () {
                Navigator.pop(sheetContext);
                pickAndUploadGroupAvatar(context, ref, chat);
              },
            ),
            if (chat.avatarPath != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text('chat_detail.avatar_remove'.tr()),
                onTap: () {
                  Navigator.pop(sheetContext);
                  ref
                      .read(chatsControllerProvider.notifier)
                      .clearGroupAvatar(chat: chat);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Full-width info block: the labelled icon on its own row, the value/editor
  /// spanning the full card width beneath it (name + description redesign, #5).
  Widget _buildInfoBlock(
    BuildContext context,
    IconData icon,
    String label, {
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(color: Colors.grey[600])),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    IconData icon,
    String label, {
    String? value,
    Widget? valueWidget,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: Colors.grey[600])),
        const SizedBox(width: 8),
        valueWidget ??
            Expanded(
              child: Text(
                value ?? '',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
      ],
    );
  }

  Widget _buildCreatorRow(BuildContext context, WidgetRef ref, String userId) {
    final profile = ref.watch(profileProvider(userId));

    return Row(
      children: [
        Icon(Icons.person, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Text(
          'chat_detail.created_by'.tr(),
          style: TextStyle(color: Colors.grey[600]),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            profile?.username ?? 'chat_detail.unknown_user'.tr(),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildMemberTile(
    BuildContext context,
    WidgetRef ref,
    String memberId,
    bool isCurrentUserAdmin,
    String? currentUserId, {
    bool isAgentSection = false,
  }) {
    final profile = ref.watch(profileProvider(memberId));
    final isMemberAdmin = chat.isAdmin(memberId);
    final isSelf = memberId == currentUserId;
    // Promote/demote/remove exist only in groups; in a 1:1 chat neither
    // party manages the other (DB-enforced too, migration 00030).
    final canManage = chat.isGroup && isCurrentUserAdmin && !isSelf;

    // Main agent (1.13): exactly one per chat — the addressee of the chat
    // summary. A LOCAL preference of this user on this device, so anyone may
    // set it, not just admins. Tapping the filled star clears the choice
    // (back to "any agent answers").
    final isMainAgent = isAgentSection &&
        ref.watch(mainAgentProvider(chat.id)) == memberId;

    final memberKey = GlobalKey<PopupMenuButtonState<String>>();
    return ListTile(
      onTap: canManage
          ? () => memberKey.currentState?.showButtonMenu()
          : null,
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      leading: UserAvatar(userId: memberId, radius: 20),
      title: Row(
        children: [
          Text(profile?.username ?? 'chat_detail.unknown_user'.tr()),
          if (isMemberAdmin) ...[
            const SizedBox(width: 8),
            Chip(
              label: Text(
                'chat_detail.admin_badge'.tr(),
                style: const TextStyle(fontSize: 10),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ],
      ),
      subtitle: isSelf
          ? Text('chat_detail.you'.tr())
          : (isMainAgent ? Text('chat_detail.main_agent'.tr()) : null),
      trailing: (!isAgentSection && !canManage)
          ? null
          : Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isAgentSection)
            IconButton(
              icon: Icon(
                isMainAgent ? Icons.star : Icons.star_border,
                color: isMainAgent
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              tooltip: 'chat_detail.main_agent'.tr(),
              onPressed: () => ref
                  .read(mainAgentProvider(chat.id).notifier)
                  .set(isMainAgent ? null : memberId),
            ),
          if (canManage)
            PopupMenuButton<String>(
              key: memberKey,
              onSelected: (value) => _handleMemberAction(
                context,
                ref,
                value,
                memberId,
                isMemberAdmin,
              ),
              itemBuilder: (context) => _memberActions(isMemberAdmin),
            ),
        ],
      ),
    );
  }

  List<PopupMenuEntry<String>> _memberActions(bool isMemberAdmin) {
    return [
      // Promote/Demote
      if (isMemberAdmin)
        PopupMenuItem(
          value: 'demote',
          child: ListTile(
            leading: const Icon(Icons.arrow_downward),
            title: Text('chat_detail.demote_admin'.tr()),
            contentPadding: EdgeInsets.zero,
          ),
        )
      else
        PopupMenuItem(
          value: 'promote',
          child: ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: Text('chat_detail.promote_admin'.tr()),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      // Remove member
      PopupMenuItem(
        value: 'remove',
        child: ListTile(
          leading: const Icon(Icons.person_remove, color: Colors.red),
          title: Text(
            'chat_detail.remove_member'.tr(),
            style: const TextStyle(color: Colors.red),
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ];
  }

  Future<void> _handleMemberAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    String memberId,
    bool isMemberAdmin,
  ) async {
    final controller = ref.read(chatMembersControllerProvider);

    try {
      switch (action) {
        case 'promote':
          await controller.promoteToAdmin(chatId: chat.id, userId: memberId);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('chat_detail.promoted_success'.tr())),
            );
          }
          break;
        case 'demote':
          await controller.demoteFromAdmin(chatId: chat.id, userId: memberId);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('chat_detail.demoted_success'.tr())),
            );
          }
          break;
        case 'remove':
          final confirmed = await _showConfirmDialog(
            context,
            'chat_detail.confirm_remove_title'.tr(),
            'chat_detail.confirm_remove_message'.tr(),
          );
          if (confirmed == true) {
            await controller.removeMember(chatId: chat.id, userId: memberId);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('chat_detail.removed_success'.tr())),
              );
            }
          }
          break;
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('common.error'.tr(args: [e.toString()]))));
      }
    }
  }

  Future<void> _handleMenuAction(
    BuildContext context,
    WidgetRef ref,
    String action,
    String? currentUserId,
  ) async {
    switch (action) {
      case 'mute':
        final muteController = ref.read(mutedChatsProvider.notifier);
        if (muteController.isMuted(chat.id)) {
          await muteController.unmute(chat.id);
        } else if (context.mounted) {
          await showMuteSheet(context: context, ref: ref, chatId: chat.id);
        }
      case 'report':
        final confirmedReport = await _showConfirmDialog(
          context,
          'chat_detail.confirm_report_title'.tr(),
          'chat_detail.confirm_report_message'.tr(),
        );
        if (confirmedReport == true) {
          await ref.read(reportedChatsProvider.notifier).report(chat.id);
          // Also file a content-blind server report (metadata only). Best-effort:
          // the local report is already recorded, so a server failure is silent.
          try {
            final reports = ref.read(reportsRepositoryProvider);
            if (chat.isGroup) {
              await reports.reportGroup(
                  chatId: chat.id, reason: 'reported_from_chat');
            } else {
              final members =
                  await ref.read(chatMembersProvider(chat.id).future);
              String? peerId;
              for (final memberId in members) {
                if (memberId != currentUserId) {
                  peerId = memberId;
                  break;
                }
              }
              if (peerId != null) {
                await reports.reportUser(
                  reportedUserId: peerId,
                  chatId: chat.id,
                  reason: 'reported_from_chat',
                );
              }
            }
          } catch (_) {
            /* server report is best-effort */
          }
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('chat_detail.reported'.tr())),
            );
          }
        }
      case 'rotate_key':
        final confirmedRotate = await _showConfirmDialog(
          context,
          'chat_detail.confirm_rotate_title'.tr(),
          'chat_detail.confirm_rotate_message'.tr(),
        );
        if (confirmedRotate == true) {
          await ref.read(chatsControllerProvider.notifier).rotateChatKey(chat.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('chat_detail.key_rotated'.tr()),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      case 'leave':
        final confirmed = await _showConfirmDialog(
          context,
          'chat_detail.confirm_leave_title'.tr(),
          'chat_detail.confirm_leave_message'.tr(),
        );
        if (confirmed == true && currentUserId != null) {
          final controller = ref.read(chatMembersControllerProvider);
          try {
            await controller.leaveChat(
              chatId: chat.id,
              currentUserId: currentUserId,
            );
            // Only leave the screen once the server delete (and the admin-
            // reassign trigger) actually succeeded. Admin-leave used to fail
            // invisibly: the trigger rolled the transaction back but this
            // handler popped anyway, so the chat silently stayed. Surface the
            // error instead of swallowing it.
            if (context.mounted) {
              Navigator.pop(context);
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('common.error'.tr(args: [e.toString()])),
                ),
              );
            }
          }
        }
        break;
      case 'delete':
        final confirmed = await _showConfirmDialog(
          context,
          'chat_detail.confirm_delete_title'.tr(),
          'chat_detail.confirm_delete_message'.tr(),
          destructive: true,
        );
        if (confirmed == true) {
          final controller = ref.read(chatsControllerProvider.notifier);
          final success = await controller.deleteChat(chat.id);
          if (!context.mounted) break;
          if (success) {
            Navigator.popUntil(context, (route) => route.isFirst);
          } else {
            // RLS blocked the delete (not admin) or the request failed —
            // the chat still exists, so don't pretend it's gone.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('chat_detail.delete_failed'.tr())),
            );
          }
        }
        break;
    }
  }

  void _showAddMemberDialog(BuildContext context, WidgetRef ref) {
    // In the per-chat-key E2E model a member must generate their own key pair
    // and request to join, so the admin "adds" someone by sharing the group
    // invite (QR / chat-ID). They scan it / enter the ID and request to join,
    // which the admin then approves in the pending-requests list.
    logger.info('Add member: showing group invite for chat ${chat.id}');
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
                'chat_detail.add_member'.tr(),
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
              GroupChatQrDisplay(chat: chat),
            ],
          ),
        ),
      ),
    );
  }

  /// Available disappearing-messages durations. null = off.
  static const List<int?> _ttlOptions = [
    null,
    30,
    300,
    3600,
    86400,
    604800,
  ];

  // Shares formatMessageTtl with the system message that announces a TTL
  // change, so the picker and the announcement can never word the same
  // duration differently.
  String _ttlLabel(int? seconds) =>
      seconds == null ? 'chat_detail.ttl_off'.tr() : formatMessageTtl(seconds);

  void _showTtlPicker(BuildContext context, WidgetRef ref, Chat chat) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'chat_detail.disappearing_messages'.tr(),
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
            ),
            for (final option in _ttlOptions)
              ListTile(
                title: Text(_ttlLabel(option)),
                trailing: option == chat.messageTtlSeconds
                    ? Icon(
                        Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await ref
                      .read(chatsControllerProvider.notifier)
                      .updateMessageTtl(chat: chat, ttlSeconds: option);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _showConfirmDialog(
    BuildContext context,
    String title,
    String message, {
    bool destructive = false,
  }) {
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
            style: destructive
                ? TextButton.styleFrom(foregroundColor: Colors.red)
                : null,
            child: Text('common.confirm'.tr()),
          ),
        ],
      ),
    );
  }

  String _formatDate(BuildContext context, DateTime date) {
    return AppTime.ymdHm(date, context.locale.toString());
  }

  /// Active invitation messages of this group (admin-only — RLS gives
  /// everyone else an empty list anyway). Revoking kills the token
  /// server-side; already-joined members stay, the card in the target chat
  /// simply stops working.
  Widget _buildInvitesSection(BuildContext context, WidgetRef ref) {
    final invitesAsync = ref.watch(chatInvitesProvider(chat.id));

    return invitesAsync.when(
      data: (invites) {
        final active = invites.where((i) => !i.isRevoked).toList();
        if (active.isEmpty) return const SizedBox.shrink();

        final chats = ref.watch(chatsControllerProvider);
        final currentUserId = ref.watch(authControllerProvider);

        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'invite.active_title'.tr(),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              ...active.map((invite) {
                final target = chats
                    .where((c) => c.id == invite.targetChatId)
                    .firstOrNull;
                final targetName = target == null
                    ? invite.targetChatId.substring(0, 8)
                    : (currentUserId == null
                        ? (target.name ?? invite.targetChatId.substring(0, 8))
                        : forwardChatDisplayName(ref, target, currentUserId));
                return ListTile(
                  leading: const Icon(Icons.forward_to_inbox),
                  title: Text(targetName),
                  subtitle: Text(
                    AppTime.ymdHm(invite.createdAt, context.locale.toString()),
                  ),
                  trailing: TextButton(
                    onPressed: () async {
                      try {
                        await ref
                            .read(invitesControllerProvider)
                            .revokeInvite(invite.token);
                        ref.invalidate(chatInvitesProvider(chat.id));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('invite.revoked_done'.tr())),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text('invite.revoke_failed'.tr(args: ['$e'])),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                    child: Text('invite.revoke'.tr()),
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }

  Widget _buildPendingRequestsSection(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingMembersProvider(chat.id));

    return pendingAsync.when(
      data: (pendingMembers) {
        if (pendingMembers.isEmpty) {
          return const SizedBox.shrink();
        }

        return Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      Icons.pending_actions,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'chat_detail.pending_requests'.tr(),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(width: 8),
                    Chip(
                      label: Text(
                        '${pendingMembers.length}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ),
              ),
              ...pendingMembers.map(
                (member) => _buildPendingMemberTile(context, ref, member),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (err, _) => const SizedBox.shrink(),
    );
  }

  Widget _buildPendingMemberTile(
    BuildContext context,
    WidgetRef ref,
    PendingChatMember member,
  ) {
    final profile = ref.watch(profileProvider(member.userId));

    return ListTile(
      leading: UserAvatar(userId: member.userId, radius: 20),
      title: Text(profile?.username ?? 'chat_detail.unknown_user'.tr()),
      subtitle: Text(
        'chat_detail.requested'.tr(
          namedArgs: {'time': _formatDate(context, member.createdAt)},
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.check, color: Colors.green),
            onPressed: () => _handleAcceptMember(context, ref, member),
            tooltip: 'chat_detail.accept_request'.tr(),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.red),
            onPressed: () => _handleRejectMember(context, ref, member.userId),
            tooltip: 'chat_detail.reject_request'.tr(),
          ),
          IconButton(
            icon: const Icon(Icons.block, color: Colors.deepOrange),
            onPressed: () => _handleBlockMember(context, ref, member.userId),
            tooltip: 'chat_detail.block_request'.tr(),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAcceptMember(
    BuildContext context,
    WidgetRef ref,
    PendingChatMember member,
  ) async {
    final controller = ref.read(chatMembersControllerProvider);

    try {
      // Approve member with their public key
      await controller.approveMember(
        chatId: chat.id,
        userId: member.userId,
        publicKey: member.publicKey,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('chat_detail.request_accepted'.tr())),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('common.error'.tr(args: [e.toString()]))));
      }
    }
  }

  Future<void> _handleRejectMember(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) async {
    final controller = ref.read(chatMembersControllerProvider);

    try {
      // Reject the pending request
      await controller.rejectMember(chatId: chat.id, userId: userId);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('chat_detail.request_rejected'.tr())),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('common.error'.tr(args: [e.toString()]))));
      }
    }
  }

  /// Reject AND block: the request is marked blocked (kept in the table) so the
  /// user cannot send repeated join requests (anti-spam).
  Future<void> _handleBlockMember(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) async {
    final controller = ref.read(chatMembersControllerProvider);

    try {
      await controller.blockMember(chatId: chat.id, userId: userId);
      // Refresh the pending list (blocked requests are hidden from it).
      ref.invalidate(pendingMembersProvider(chat.id));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('chat_detail.request_blocked'.tr())),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('common.error'.tr(args: [e.toString()]))));
      }
    }
  }
}

/// Read-only group description: renders up to 4 lines, and — when the text
/// overflows — a "more…" link that opens the full, scrollable text in a sheet
/// (#5). Prevents a long description from dominating the detail screen.
class _TrimmedDescription extends StatelessWidget {
  final String text;

  const _TrimmedDescription(this.text);

  void _showFull(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'chat_detail.description'.tr(),
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Flexible(child: SingleChildScrollView(child: Text(text))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 4,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = tp.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              maxLines: overflows ? 4 : null,
              overflow:
                  overflows ? TextOverflow.ellipsis : TextOverflow.clip,
            ),
            if (overflows)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InkWell(
                  onTap: () => _showFull(context),
                  child: Text(
                    'chat_detail.description_more'.tr(),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
