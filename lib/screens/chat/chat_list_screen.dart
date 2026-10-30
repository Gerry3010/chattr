// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chattr/core/core.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/features/profiles/avatar_url_cache.dart';
import 'package:chattr/features/profiles/avatar_image.dart';
import 'package:chattr/features/profiles/profile_helpers.dart';
import 'package:chattr/features/profiles/widgets/profile_info_sheet.dart';
import 'package:chattr/features/profiles/widgets/user_avatar.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../whats_new/whats_new_dialog.dart';
import '../../core/navigation/chat_navigation.dart';
import '../../core/navigation/app_page_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/chat_requests/chat_requests_controller.dart';
import '../../features/chats/chat_members_controller.dart';
import '../../features/identity/identity_color.dart';
import '../../features/chats/chats_controller.dart';
import '../../features/chats/chats_load_status.dart';
import '../../features/mentions/unread_mention_provider.dart';
import '../qr/qr_scanner_screen.dart';
import '../settings/settings_screen.dart';
import 'chat_view_screen.dart';
import 'create_group_chat_screen.dart';
import 'favorites_screen.dart';
import 'global_search_screen.dart';
import 'mcp_chat_list_screen.dart';
import '../../features/push_notifications/push_render_cache_sync.dart';
import 'pending_requests_screen.dart';
import 'components/server_offline_banner.dart';
import 'components/superseded_installation_banner.dart';
import '../../features/messages/global_search_controller.dart'
    show chatDisplayNameProvider;

/// Unread messages across all MCP (agent) chats.
///
/// They are filtered out of the main list, so this sum is the only thing that
/// represents them there — and it is part of what the app-icon badge counts
/// (`totalUnreadProvider` sums every chat, agent chats included).
@visibleForTesting
int mcpUnreadTotal(Iterable<Chat> mcpChats) =>
    mcpChats.fold<int>(0, (sum, c) => sum + c.unreadCount);

/// Whether the agent-chats row belongs on screen.
///
/// It is normally hidden behind a pull-down past the top (WhatsApp's
/// archived-chats gesture) so a chatty agent cannot clutter the list; pulling
/// down again puts it away (see [OverdragGesture]). That is the right default
/// right up until an agent says something the user has not read: the app-icon
/// badge counts those messages, so hiding the row left the icon showing a
/// number with no visible source anywhere in the list.
///
/// So: unread wins over hidden, and the row disappears again once it is read.
/// While something is unread the gesture therefore has no visible effect —
/// deliberately: the row is not the user's to hide while it is the only
/// explanation for the number on the app icon.
@visibleForTesting
bool shouldShowMcpRow({
  required int mcpChatCount,
  required int mcpUnread,
  required bool revealedByGesture,
}) {
  if (mcpChatCount == 0) return false;
  return revealedByGesture || mcpUnread > 0;
}

/// Turns the stream of scroll notifications into ONE event per pull-past-top.
///
/// **Why this exists** (Gerry, 2026-08-26): revealing the row was a one-way
/// switch, so "did this notification come from an over-drag?" was enough — it
/// could only ever set the same flag to true again. A toggle cannot be built
/// that way. A single pull dispatches dozens of notifications, and flipping on
/// each one lands on a coin toss: the row would appear to react at random, and
/// worse, the bug would look like "the gesture doesn't work" rather than "it
/// works too often".
///
/// So the over-drag is latched. It fires on the first notification that reports
/// a position past the top and stays quiet until [ended] — which the screen
/// calls on `ScrollEndNotification`, the one signal both platforms emit exactly
/// once per gesture. Unlatching on "no longer past the top" instead would be
/// wrong on Android: there the position never leaves the boundary during an
/// over-drag (`ClampingScrollPhysics` clamps it and reports the surplus
/// separately), so a stray in-bounds update mid-drag would re-arm the latch and
/// flip the row a second time within the same pull.
@visibleForTesting
class OverdragGesture {
  bool _latched = false;

  /// Whether the latch is currently held — exposed for the test only.
  @visibleForTesting
  bool get latched => _latched;

  /// Feed every notification's "is the list past its top?" verdict here.
  /// Returns true exactly once per gesture.
  bool fires({required bool pastTop}) {
    if (!pastTop || _latched) return false;
    _latched = true;
    return true;
  }

  /// The scroll came to rest — the next pull may fire again.
  void ended() => _latched = false;
}

/// What an empty list says depends on why it is empty. "Noch keine Chats"
/// only once the local chats are actually read; while locked the lock screen
/// lies on top, and a failed start says so and offers another go.
class _EmptyChatList extends ConsumerWidget {
  const _EmptyChatList({required this.status});

  final ChatsLoadStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = Colors.grey[600];
    switch (status) {
      case ChatsLoadStatus.loading:
      case ChatsLoadStatus.locked:
        return const SizedBox.shrink();
      case ChatsLoadStatus.failed:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'chat_list.load_failed'.tr(),
              style: theme.textTheme.titleMedium?.copyWith(color: muted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () =>
                  ref.read(chatsControllerProvider.notifier).retryLoad(),
              child: Text('chat_list.retry'.tr()),
            ),
          ],
        );
      case ChatsLoadStatus.ready:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, size: 80, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'chat_list.empty_title'.tr(),
              style: theme.textTheme.headlineSmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            Text(
              'chat_list.empty_subtitle'.tr(),
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              textAlign: TextAlign.center,
            ),
          ],
        );
    }
  }
}

class ChatListScreen extends HookConsumerWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allChats = ref.watch(chatsControllerProvider);
    final loadStatus = ref.watch(chatsLoadStatusProvider);
    // MCP chats live in their own hidden row/screen (see _McpChatsRow below) —
    // kept out of the main list so a chatty agent doesn't clutter it.
    final chats = allChats.where((c) => !c.isMcp).toList();
    final mcpChats = allChats.where((c) => c.isMcp).toList();

    // Hidden until the user pulls down past the top (WhatsApp's archived-chats
    // gesture) — then it's a normal sliver they can scroll past like any other,
    // not an always-visible row. Pulling down again hides it, so the gesture is
    // a switch rather than a one-way door.
    final mcpRowRevealed = useState(false);
    // Survives rebuilds: the latch below must span a whole gesture, and the
    // toggle itself rebuilds this widget mid-drag.
    final mcpGesture = useRef(OverdragGesture());

    // …but not while an agent is waiting to be read. The app-icon badge counts
    // MCP chats like any other, so a hidden row meant the icon showed a number
    // with no visible source anywhere in the list. The row therefore reveals
    // itself whenever there is something unread in it, and goes back into
    // hiding once it's read — which keeps the original point of hiding it (a
    // chatty agent must not clutter the list) without letting it swallow the
    // one thing the user needs to see.
    final mcpUnread = mcpUnreadTotal(mcpChats);
    final showMcpRow = shouldShowMcpRow(
      mcpChatCount: mcpChats.length,
      mcpUnread: mcpUnread,
      revealedByGesture: mcpRowRevealed.value,
    );

    final currentUserId = ref.watch(authControllerProvider);

    // Since "Push ohne Klartext" the server sends only ids, so the device has
    // to know the names itself when a push wakes it. This screen is where the
    // app knows every name a push could plausibly arrive for, so it is where
    // the background isolate's lookup table gets refreshed. Best-effort and
    // off the build path — see syncPushRenderCache.
    // Keyed on the RESOLVED names, not just the chat count. The names come from
    // providers that are often still empty on the first build — the sync then
    // wrote chat ids where names belong, and never ran again because the count
    // had not changed. That is why a fresh install first showed "Chattr / Neue
    // Nachricht" and then "Chat 1e4e401e" instead of the peer's name. Watching
    // the display names makes this rebuild as they arrive, and the fingerprint
    // makes the effect fire exactly then — not on every build.
    final resolvedNames = [
      for (final chat in allChats) ref.watch(chatDisplayNameProvider(chat.id)),
    ].join('\u0000');
    useEffect(() {
      if (allChats.isEmpty) return null;
      unawaited(syncPushRenderCache(ref));
      return null;
    }, [resolvedNames, currentUserId]);

    // "New in this version" — once per signed-in session start, after the
    // first frame so the list is already there behind the card.
    useEffect(() {
      if (currentUserId == null) return null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) unawaited(showWhatsNewIfUnread(context, ref));
      });
      return null;
    }, [currentUserId]);

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
                // Chat requests (00082) count too: the same inbox, because for
                // the user it is the same question — somebody wants access, and
                // they decide.
                final chatRequests = ref.watch(incomingChatRequestCountProvider);
                final visible = chatRequests > 0 ||
                    ref.watch(pendingOverviewVisibleProvider(currentUserId));
                if (!visible) return const SizedBox.shrink();
                // The numeric badge counts only the actionable incoming
                // requests; with outgoing-only, show the plain icon.
                final incoming =
                    ref.watch(adminPendingCountProvider(currentUserId)) +
                        chatRequests;
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
              appPageRoute<void>(builder: (_) => const FavoritesScreen()),
            ),
            tooltip: 'chat_list.favorites'.tr(),
          ),
          // Global (cross-chat) message search.
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.push(
              context,
              appPageRoute<void>(builder: (_) => const GlobalSearchScreen()),
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
      body: Column(
        children: [
          // The chat list is served entirely from the local database, so it
          // still looks completely normal during an outage — which is exactly
          // why it needs to say so.
          const ServerOfflineBanner(),
          // Replaced by a recovery on another device: say why nothing arrives.
          const SupersededInstallationBanner(),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              // Pull down past the top to show the hidden MCP row — pull down
              // again to put it away. The two scroll physics report an at-top
              // over-drag differently, so we watch for both:
              //  • Android (ClampingScrollPhysics) refuses to move past the boundary
              //    and dispatches an OverscrollNotification with a negative overscroll.
              //  • iOS (BouncingScrollPhysics) never clamps (applyBoundaryConditions
              //    returns 0), so a pull-down instead moves the position past
              //    minScrollExtent and only emits a ScrollUpdateNotification with
              //    pixels < minScrollExtent — no OverscrollNotification fires on the
              //    user drag. Listening for OverscrollNotification alone therefore
              //    never revealed the row on iOS.
              onNotification: (notification) {
                if (notification is ScrollEndNotification) {
                  mcpGesture.value.ended();
                  return false;
                }
                final pulledPastTop =
                    (notification is OverscrollNotification &&
                        notification.overscroll < 0) ||
                    (notification is ScrollUpdateNotification &&
                        notification.metrics.pixels <
                            notification.metrics.minScrollExtent);
                if (mcpGesture.value.fires(pastTop: pulledPastTop)) {
                  mcpRowRevealed.value = !mcpRowRevealed.value;
                }
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  if (showMcpRow)
                    SliverToBoxAdapter(
                      child: _McpChatsRow(
                        count: mcpChats.length,
                        unread: mcpUnread,
                      ),
                    ),
                  if (chats.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: _EmptyChatList(status: loadStatus),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final chat = chats[index];
                        return ChatListItem(chat: chat, index: index);
                      }, childCount: chats.length),
                    ),
                ],
              ),
            ),
          ),
        ],
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
        appPageRoute<void>(
          settings: RouteSettings(name: chatRouteName(chatId)),
          builder: (_) => ChatViewScreen(chatId: chatId),
        ),
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

  /// Unread messages across all MCP chats. The row is the only place they are
  /// visible from the main list, so this is what the app-icon badge counts on
  /// this side of the split.
  final int unread;

  const _McpChatsRow({required this.count, this.unread = 0});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: const ValueKey('mcp_chats_row'),
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Icon(
          Icons.smart_toy_outlined,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text('chat_list.mcp_row.title'.tr()),
      subtitle: Text('chat_list.mcp_row.subtitle'.tr(args: ['$count'])),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread > 0) ...[
            // Deliberately identical to the per-chat badge in [ChatListItem] —
            // same padding, radius and type. Two unread badges on one screen
            // that look subtly different read as a bug, not as a distinction.
            Container(
              key: const ValueKey('mcp_chats_unread_badge'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$unread',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          const Icon(Icons.chevron_right),
        ],
      ),
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
    ImageProvider? peerAvatar;
    String? peerUserId;
    Color? peerColor;
    if (!chat.isGroup) {
      for (final profile in profiles) {
        if (profile.id != currentUserId) {
          peerUserId = profile.id;
          // From the disk cache when offline (CHAT-63).
          peerAvatar = ref.watch(avatarImageProvider(
            (bucket: kAvatarBucket, path: profile.avatarPath ?? ''),
          ));
          // 1:1 rows use the peer's IDENTITY colour (audit M2) — the same one
          // UserAvatar/the chat header show — not the chat-uuid colour, which
          // made the same user olive here and pink elsewhere.
          peerColor = IdentityColor.forKeyOrId(
            profile.identityPublicKey,
            profile.id,
          );
          break;
        }
      }
    }

    // Group avatar (00055): the uploaded group picture, else the group icon in
    // [buildCircleAvatar].
    final ImageProvider? groupAvatar = chat.isGroup
        ? ref.watch(avatarImageProvider(
            (bucket: kGroupAvatarBucket, path: chat.avatarPath ?? ''),
          ))
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
          isPending,
          chat,
          displayName,
          peerAvatar,
          groupAvatar,
          peerColor: peerColor,
        ),
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
          // @-mention marker (1.10): shown when an unread message in this chat
          // mentions me. Gated on unreadCount so it only decrypts unread chats
          // and clears the moment the chat is read.
          if (chat.unreadCount > 0 &&
              (ref
                      .watch(unreadMentionProvider(chat.id))
                      .whenOrNull(data: (v) => v) ??
                  false)) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.alternate_email,
                size: 12,
                color: Colors.white,
              ),
            ),
          ],
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
          appPageRoute<void>(
            settings: RouteSettings(name: chatRouteName(chat.id)),
            builder: (_) => ChatViewScreen(chatId: chat.id),
          ),
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
                        leading: Icon(
                          chat.isPinned
                              ? Icons.push_pin_outlined
                              : Icons.push_pin,
                        ),
                        title: Text(
                          (chat.isPinned ? 'chat_list.unpin' : 'chat_list.pin')
                              .tr(),
                        ),
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
    ImageProvider? peerAvatar,
    ImageProvider? groupAvatar, {
    Color? peerColor,
  }) {
    // 1:1 → the peer's identity colour (consistent with every other avatar
    // surface); groups keep the chat-uuid colour (a group is not a user
    // identity). Pending rows stay grey.
    final Color color = (!chat.isGroup && peerColor != null)
        ? peerColor
        : chat.color;
    final textColor = isPending
        ? Colors.grey[600]
        : IdentityColor.foregroundOn(color);
    final backgroundColor = isPending ? Colors.grey[300] : color;

    // 1:1 peer with an uploaded picture → show it (coloured initials stay the
    // fallback for peers without one).
    if (!chat.isGroup && peerAvatar != null) {
      return CircleAvatar(
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        backgroundImage: peerAvatar,
        onBackgroundImageError: (_, _) {},
      );
    }

    // Group with an uploaded avatar (00055) → show it (group icon stays the
    // fallback for groups without one).
    if (chat.isGroup && groupAvatar != null) {
      return CircleAvatar(
        backgroundColor: backgroundColor,
        foregroundColor: textColor,
        backgroundImage: groupAvatar,
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
              // Canonical size/weight (20 = CircleAvatar's default radius here);
              // the colour override keeps the grey pending-row letter.
              style: IdentityColor.initialsTextStyle(
                20,
                color,
              ).copyWith(color: textColor),
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

/// Avatar initials for a display name — delegates to the canonical
/// [initialsFor] (first + last word) so every surface renders the same
/// initials. Kept as a named alias for existing call sites/tests.
String getInitials(String displayName) => initialsFor(displayName);
