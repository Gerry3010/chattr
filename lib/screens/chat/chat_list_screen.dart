// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/core.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/profiles/profile_helpers.dart';
import 'package:chattr/features/profiles/profiles_controller.dart';
import 'package:chattr/features/profiles/widgets/profile_info_sheet.dart';
import 'package:chattr/features/profiles/widgets/user_avatar.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../core/navigation/app_page_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/chats/chat_members_controller.dart';
import '../../features/chats/chats_controller.dart';
import '../../features/chats/chats_repository.dart';
import '../qr/qr_scanner_screen.dart';
import '../settings/settings_screen.dart';
import 'chat_view_screen.dart';
import 'create_group_chat_screen.dart';
import 'favorites_screen.dart';
import 'global_search_screen.dart';
import 'mcp_chat_list_screen.dart';
import 'pending_requests_screen.dart';

class ChatListScreen extends HookConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allChats = ref.watch(chatsControllerProvider);
    // MCP chats live in their own hidden row/screen (see _McpChatsRow below) —
    // kept out of the main list so a chatty agent doesn't clutter it.
    final chats = allChats.where((c) => !c.isMcp).toList();
    final mcpChats = allChats.where((c) => c.isMcp).toList();

    // Hidden until the user pulls down past the top once (WhatsApp's
    // archived-chats gesture) — then it's a normal sliver they can scroll
    // past like any other, not an always-visible row.
    final mcpRowRevealed = useState(false);

    final currentUserId = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('chat_list.title'.tr()),
        leading: currentUserId == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(left: 12),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _openSettings(context),
                  child: Center(
                    child: UserAvatar(userId: currentUserId, radius: 16),
                  ),
                ),
              ),
        actions: [
          // Aggregate pending-requests inbox (admins only) — appears with a
          // count badge whenever any administered group has outstanding join
          // requests, so they can be reviewed without opening each chat.
          if (currentUserId != null)
            Builder(
              builder: (context) {
                // Show the inbox whenever there's anything to see: incoming
                // requests to administer OR the user's own outgoing requests.
                final visible =
                    ref.watch(pendingOverviewVisibleProvider(currentUserId));
                if (!visible) return const SizedBox.shrink();
                // The numeric badge counts only the actionable incoming
                // requests; with outgoing-only, show the plain icon.
                final incoming =
                    ref.watch(adminPendingCountProvider(currentUserId));
                const icon = Icon(Icons.person_add_alt_1);
                return IconButton(
                  icon: incoming > 0
                      ? Badge.count(count: incoming, child: icon)
                      : icon,
                  tooltip: 'pending_requests.tooltip'.tr(),
                  onPressed: () => Navigator.push(
                    context,
                    appPageRoute<void>(
                      builder: (_) => const PendingRequestsScreen(),
                    ),
                  ),
                );
              },
            ),
          // Favorited messages across all chats (#4).
          IconButton(
            icon: const Icon(Icons.star_border),
            onPressed: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => const FavoritesScreen(),
              ),
            ),
            tooltip: 'chat_list.favorites'.tr(),
          ),
          // Global (cross-chat) message search.
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.push(
              context,
              appPageRoute<void>(
                builder: (_) => const GlobalSearchScreen(),
              ),
            ),
            tooltip: 'messages_search.global_title'.tr(),
          ),
          // QR Code Scanner (add contact). Settings are reached via the avatar
          // in the leading slot, so no separate gear action here (avoids a
          // duplicate settings entry point on the left and right).
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () async {
              await _handleQrScan(context);
            },
            tooltip: 'tooltips.add_contact'.tr(),
          ),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        // Reveal the hidden MCP row on a pull-down past the top. The two
        // scroll physics report an at-top over-drag differently, so we watch
        // for both:
        //  • Android (ClampingScrollPhysics) refuses to move past the boundary
        //    and dispatches an OverscrollNotification with a negative overscroll.
        //  • iOS (BouncingScrollPhysics) never clamps (applyBoundaryConditions
        //    returns 0), so a pull-down instead moves the position past
        //    minScrollExtent and only emits a ScrollUpdateNotification with
        //    pixels < minScrollExtent — no OverscrollNotification fires on the
        //    user drag. Listening for OverscrollNotification alone therefore
        //    never revealed the row on iOS.
        onNotification: (notification) {
          if (!mcpRowRevealed.value) {
            final pulledPastTop =
                (notification is OverscrollNotification &&
                    notification.overscroll < 0) ||
                (notification is ScrollUpdateNotification &&
                    notification.metrics.pixels <
                        notification.metrics.minScrollExtent);
            if (pulledPastTop) {
              mcpRowRevealed.value = true;
            }
          }
          return false;
        },
        child: CustomScrollView(
          slivers: [
            if (mcpRowRevealed.value && mcpChats.isNotEmpty)
              SliverToBoxAdapter(child: _McpChatsRow(count: mcpChats.length)),
            if (chats.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 80,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'chat_list.empty_title'.tr(),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'chat_list.empty_subtitle'.tr(),
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: Colors.grey[600]),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final chat = chats[index];
                    return ChatListItem(chat: chat, index: index);
                  },
                  childCount: chats.length,
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showNewChatDialog(context),
        icon: const Icon(Icons.add_comment),
        label: Text('chat_list.new_chat'.tr()),
      ),
    );
  }

  void _showNewChatDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('chat_list.new_chat_dialog.title'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: Text('chat_list.new_chat_dialog.scan_qr'.tr()),
              subtitle: Text('chat_list.new_chat_dialog.scan_qr_desc'.tr()),
              onTap: () {
                Navigator.pop(context);
                _handleQrScan(context);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.keyboard),
              title: Text('chat_list.new_chat_dialog.enter_code'.tr()),
              subtitle: Text('chat_list.new_chat_dialog.enter_code_desc'.tr()),
              onTap: () {
                Navigator.pop(context);
                _handleQrScan(context, manualInput: true);
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.group_add),
              title: Text('chat_list.new_chat_dialog.create_group'.tr()),
              subtitle: Text(
                'chat_list.new_chat_dialog.create_group_desc'.tr(),
              ),
              onTap: () {
                Navigator.pop(context);
                _handleCreateGroup(context);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('common.cancel'.tr()),
          ),
        ],
      ),
    );
  }

  /// Pick an image and upload it as the current user's avatar.
  void _openSettings(BuildContext context) {
    Navigator.push(
      context,
      appPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _handleQrScan(
    BuildContext context, {
    bool manualInput = false,
  }) async {
    final result = await Navigator.push<Object?>(
      context,
      appPageRoute<Object?>(
        builder: (_) => QrScannerScreen(startWithManualInput: manualInput),
      ),
    );

    if (result is! Map || !context.mounted) return;

    // The QR scanner already did the work AND showed the correct, outcome-aware
    // feedback (1:1 created / already exists / group join requested / already a
    // member / …). We must NOT show a second snackbar here — doing so produced a
    // confusing double toast, and this branch even mislabelled a 1:1 ('user') as
    // "group joined".
    final type = result['type'] as String?;
    final chatId = result['chat_id'] as String?;
    logger.info('QR scan result: type=$type chatId=$chatId');

    // Open the chat that was created / joined / reopened. The scanner has
    // already popped back to this list, so this is a clean list → chat push
    // (not stacked on top of wherever the user was before).
    if (chatId != null && chatId.isNotEmpty && context.mounted) {
      await Navigator.push<void>(
        context,
        appPageRoute<void>(builder: (_) => ChatViewScreen(chatId: chatId)),
      );
    }
  }

  Future<void> _handleCreateGroup(BuildContext context) async {
    await Navigator.push(
      context,
      appPageRoute<void>(builder: (_) => const CreateGroupChatScreen()),
    );
  }
}

/// Hidden-until-revealed row (see [ChatListScreen]'s overscroll listener)
/// that opens [McpChatListScreen]. Styled like a normal chat row so it reads
/// as "one more entry" once revealed rather than a jarring banner.
class _McpChatsRow extends StatelessWidget {
  final int count;

  const _McpChatsRow({required this.count});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: const ValueKey('mcp_chats_row'),
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
        child: Icon(
          Icons.smart_toy_outlined,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text('chat_list.mcp_row.title'.tr()),
      subtitle: Text('chat_list.mcp_row.subtitle'.tr(args: ['$count'])),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        appPageRoute<void>(builder: (_) => const McpChatListScreen()),
      ),
    );
  }
}

/// A single row in the chat list — also reused by [McpChatListScreen] for
/// MCP chats, so both lists render identically.
class ChatListItem extends ConsumerWidget {
  final Chat chat;
  final int index;

  const ChatListItem({super.key, required this.chat, required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUserId = ref.watch(authControllerProvider);
    if (currentUserId == null) {
      return const SizedBox.shrink();
    }

    // Get members of the chat
    final membersAsync = ref.watch(chatMembersProvider(chat.id));
    final profiles = ref.watch(
      profilesListProvider(
        membersAsync.whenOrNull(data: (members) => members) ?? [],
      ),
    );

    // Check if user's membership status
    final membershipStatus = ref.watch(
      membershipStatusProvider((chatId: chat.id, userId: currentUserId)),
    );

    // membershipStatus.whenOrNull(data: (member) {
    //   final memberJson = jsonEncode(member?.toJson());
    //   logger.debug('Membership status for chat ${chat.id}: $memberJson');
    // });

    final isNotMember =
        membershipStatus.whenOrNull(data: (member) => member == null) ?? false;

    // Check if user is not a member and has a pending request
    final isPending =
        isNotMember &&
        (ref
                .watch(
                  pendingMembershipStatusProvider((
                    chatId: chat.id,
                    userId: currentUserId,
                  )),
                )
                .whenOrNull(data: (member) => member != null) ??
            false);

    // Check if user is admin and count pending requests
    final isAdmin = chat.isAdmin(currentUserId);
    final pendingRequestsAsync = isAdmin
        ? ref.watch(pendingMembersProvider(chat.id))
        : null;
    final pendingCount =
        pendingRequestsAsync?.whenOrNull(data: (members) => members.length) ??
        0;

    // We need to get the username of the other user (singular!) if not isGroup
    final otherUsers = Map.fromEntries(
      profiles
          .where((profile) => profile.id != currentUserId)
          .map((profile) => MapEntry(profile.id, profile.username)),
    );

    final displayName =
        (chat.isGroup
            ? chat.name
            : otherUsers[otherUsers.keys.firstWhere(
                (id) => id != currentUserId,
                orElse: () => '',
              )]) ??
        'chat_list.chat_title'.tr(args: [chat.id.substring(0, 8)]);

    // Peer avatar for the list (1:1 only): show the other user's uploaded
    // profile picture, falling back to the coloured initials in
    // [buildCircleAvatar] when they have none. Groups keep the group icon.
    String? peerAvatarUrl;
    String? peerUserId;
    if (!chat.isGroup) {
      for (final profile in profiles) {
        if (profile.id != currentUserId) {
          peerUserId = profile.id;
          peerAvatarUrl = ref
              .read(profilesControllerProvider.notifier)
              .avatarUrl(profile.avatarPath);
          break;
        }
      }
    }

    // Group avatar (00055): the uploaded group picture, else the group icon in
    // [buildCircleAvatar].
    final String? groupAvatarUrl = chat.isGroup
        ? ref.read(chatsRepositoryProvider).groupAvatarUrl(
              chat.avatarPath,
              cacheBust: chat.updatedAt.millisecondsSinceEpoch,
            )
        : null;

    return ListTile(
      // Tap the avatar (not the whole row, which opens the chat) → profile &
      // contact sheet. Pending rows have no chat to inspect yet.
      leading: GestureDetector(
        onTap: isPending
            ? null
            : () => showProfileInfoSheet(
                  context: context,
                  chat: chat,
                  displayName: displayName,
                  otherUserId: chat.isGroup ? null : peerUserId,
                ),
        child: buildCircleAvatar(
            isPending, chat, displayName, peerAvatarUrl, groupAvatarUrl),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              style: TextStyle(color: isPending ? Colors.grey[600] : null),
            ),
          ),
          if (isPending)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange[100],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'chat_list.pending'.tr(),
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.orange[900],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              isPending
                  ? 'chat_list.waiting_approval'.tr()
                  : chat.lastMessageAt != null
                  ? _formatDate(context, chat.lastMessageAt!)
                  : '${'chat_list.created_prefix'.tr()}: ${_formatDate(context, chat.createdAt)}',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ),
          // Unread message badge
          if (chat.unreadCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${chat.unreadCount}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          // Pending member requests badge (for admins)
          if (pendingCount > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.orange[600],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications, size: 12, color: Colors.white),
                  const SizedBox(width: 4),
                  Text(
                    '$pendingCount',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Pinned indicator (#3)
          if (chat.isPinned && !isPending) ...[
            const SizedBox(width: 6),
            Icon(Icons.push_pin, size: 14, color: Colors.grey[500]),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.push(
          context,
          appPageRoute<void>(builder: (_) => ChatViewScreen(chatId: chat.id)),
        );
      },
      onLongPress: isPending
          ? null
          : () {
              showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                builder: (sheetCtx) => SafeArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: Icon(chat.isPinned
                            ? Icons.push_pin_outlined
                            : Icons.push_pin),
                        title: Text((chat.isPinned
                                ? 'chat_list.unpin'
                                : 'chat_list.pin')
                            .tr()),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          ref
                              .read(chatsControllerProvider.notifier)
                              .togglePin(chat.id);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.copy),
                        title: Text('chat_list.copy_id'.tr()),
                        onTap: () {
                          Navigator.pop(sheetCtx);
                          Clipboard.setData(ClipboardData(text: chat.id));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('qr.id_copied'.tr()),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
    );
  }

  CircleAvatar buildCircleAvatar(
    bool isPending,
    Chat chat,
    String displayName,
    String? peerAvatarUrl,
    String? groupAvatarUrl,
  ) {
    // Calculate color based on chat id
    // final color = Colors.primaries[chat.id.hashCode % Colors.primaries.length];
    Color color = chat.color;
    final textColor = isPending
        ? Colors.grey[600]
        : (color.computeLuminance() > 0.5 ? Colors.black : Colors.white);
    final backgroundColor = isPending ? Colors.grey[300] : color;

    // 1:1 peer with an uploaded picture → show it (coloured initials stay the
    // fallback for peers without one).
    if (!chat.isGroup && peerAvatarUrl != null) {
      return CircleAvatar(
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        backgroundImage: NetworkImage(peerAvatarUrl),
        onBackgroundImageError: (_, _) {},
      );
    }

    // Group with an uploaded avatar (00055) → show it (group icon stays the
    // fallback for groups without one).
    if (chat.isGroup && groupAvatarUrl != null) {
      return CircleAvatar(
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        backgroundImage: NetworkImage(groupAvatarUrl),
        onBackgroundImageError: (_, _) {},
      );
    }

    // logger.debug('Color for chat $cId: r: $r, g: $g, b: $b');

    final initials = getInitials(displayName);
    return CircleAvatar(
      backgroundColor: backgroundColor,
      foregroundColor: textColor,
      child: chat.isGroup
          ? Icon(Icons.group, color: textColor)
          : Text(
              initials,
              // 'C${index + 1}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
    );
  }

  String _formatDate(BuildContext context, DateTime date) {
    // Calendar-day buckets (local), NOT a rolling 24h window: a chat last active
    // yesterday at 22:00 must read "yesterday" even when it's now 01:00 — the
    // rolling daysAgo would call it "today" (<24h old). This is the chat-list
    // sort/label mismatch users hit in the small hours.
    final days = AppTime.calendarDaysAgo(date);
    if (days <= 0) {
      return 'dates.today'.tr();
    } else if (days == 1) {
      return 'dates.yesterday'.tr();
    } else if (days < 7) {
      return 'dates.days_ago'.tr(args: [days.toString()]);
    } else {
      return AppTime.ymd(date, context.locale.toString());
    }
  }
}

/// First-letter avatar initials for a display name.
///
/// Guards against empty / whitespace-only names (e.g. the '' fallback when no
/// other-user name resolves), which previously threw a RangeError on `name[0]`.
String getInitials(String displayName) {
  final words = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  return words.first[0].toUpperCase();
}
