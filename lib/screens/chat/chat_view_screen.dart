// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart' show StateController;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/notifications/active_chat_provider.dart';
import '../../features/chat_view/chat_view_controller.dart';
import '../../features/chats/chats_controller.dart';
import 'components/chat_view_banners.dart';
import 'components/server_offline_banner.dart';
import 'components/chat_view_body.dart';

/// Screen that displays a single chat conversation.
///
/// It uses the `chatview` package for the UI and [ChatViewController] for state
/// management. Enter-to-send is handled inside chatview itself (the fork's
/// `SendMessageConfiguration.sendOnEnter`, on by default for desktop + web).
class ChatViewScreen extends ConsumerStatefulWidget {
  final String chatId;

  /// When set (opened from a favorite / global-search hit), the chat scrolls to
  /// this message and pulses it once it's in the loaded window (fork p18).
  final String? highlightMessageId;

  const ChatViewScreen({
    super.key,
    required this.chatId,
    this.highlightMessageId,
  });

  @override
  ConsumerState<ChatViewScreen> createState() => _ChatViewScreenState();
}

class _ChatViewScreenState extends ConsumerState<ChatViewScreen>
    with RouteAware {
  // Cached in initState: dispose() must not touch `ref` (throws a StateError
  // once the element is unmounted).
  late final StateController<String?> _activeChat;

  /// Cached for the same reason. `ChatsController` is NOT autoDispose, so this
  /// notifier outlives the screen and is safe to call while tearing down.
  late final ChatsController _chats;

  /// Safety net for the unread jump — see initState.
  Timer? _unreadJumpFallback;

  @override
  void initState() {
    super.initState();
    _activeChat = ref.read(activeChatProvider.notifier);
    _chats = ref.read(chatsControllerProvider.notifier);
    // Mark this chat as on-screen so in-app banners/chime skip it. Post-frame:
    // providers must not be mutated during build/initState of a widget tick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activeChat.state = widget.chatId;
    });
    // No explicit target, but unread messages waiting → open where reading
    // stopped instead of at the newest message.
    //
    // The fork decides whether to do its initial scroll-to-bottom at its first
    // post-frame, by looking at the highlight notifier. The real target id is
    // not known then (messages load asynchronously), so park a placeholder to
    // claim the jump; the controller replaces it with the first unread message
    // once the boundary is computed. The placeholder itself is never found —
    // the fork simply clears it, which is exactly what we want.
    //
    // The timer is the safety net, not a nicety: if the boundary never gets
    // computed (nothing loads, or the badge was a stale server count), the
    // suppressed scroll would leave the chat sitting at the top of history.
    if (widget.highlightMessageId == null) {
      final unread = ref
          .read(chatsControllerProvider)
          .where((c) => c.id == widget.chatId)
          .firstOrNull
          ?.unreadCount ??
          0;
      if (unread > 0) {
        final c = ref.read(chatViewControllerProvider(widget.chatId).notifier);
        c.awaitingUnreadJump = true;
        c.highlightNotifier.value = unreadDividerMessageId;
        _unreadJumpFallback = Timer(const Duration(seconds: 2), () {
          if (!mounted || !c.awaitingUnreadJump) return;
          c.awaitingUnreadJump = false;
          c.chatController.scrollToLastMessage();
        });
      }
    }
    // Jump to + pulse the target message (favorites / search). Retry until it's
    // in the loaded window, since messages load asynchronously from local DB.
    final target = widget.highlightMessageId;
    if (target != null) {
      // Set the notifier SYNCHRONOUSLY, before the first frame, so the chat list
      // suppresses its initial scroll-to-bottom (whose delayed 300ms timer would
      // otherwise fire after the jump and snap back to the end). The fork's
      // notifier listener performs the actual scroll+pulse once laid out.
      final c = ref.read(chatViewControllerProvider(widget.chatId).notifier);
      c.highlightNotifier.value = target;
      _scheduleHighlight(target, attemptsLeft: 100, pagedIn: false);
    }
  }

  void _scheduleHighlight(
    String id, {
    required int attemptsLeft,
    required bool pagedIn,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || attemptsLeft <= 0) return;
      final controller = ref.read(
        chatViewControllerProvider(widget.chatId).notifier,
      );
      final present = controller.chatController.initialMessageList.any(
        (m) => m.id == id,
      );
      final hasMore = ref
          .read(chatViewControllerProvider(widget.chatId))
          .hasMoreMessages;
      if (present) {
        // Fire the jump OURSELVES only if we had to page the message in. For a
        // message already loaded at mount, the fork's subscribe-time handler
        // (it read our initState-set notifier) already scans for it — firing
        // again here would start a SECOND concurrent scan loop that fights the
        // first over the scroll controller (neither progresses → both give up).
        if (pagedIn) {
          controller.highlightMessage(id);
        }
        return;
      }
      // Not in the loaded window yet. Favourites / global search can point at a
      // message far above it — actively page older history in from the local DB
      // until the target appears (or we run out of history). Without this, old
      // messages never got loaded and the jump silently did nothing.
      if (hasMore) {
        await controller.loadMoreMessages();
        if (mounted) {
          // Small gap so the freshly-loaded page settles into the list before
          // the next check; keeps this from tight-spinning while a load runs.
          Future.delayed(const Duration(milliseconds: 30), () {
            if (mounted) {
              _scheduleHighlight(
                id,
                attemptsLeft: attemptsLeft - 1,
                pagedIn: true,
              );
            }
          });
        }
        return;
      }
      // No more history and still not found — give up quietly.
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) chatViewRouteObserver.subscribe(this, route);
  }

  // A sub-screen (chat details, image/avatar viewer) was pushed ON TOP of this
  // chat view → the chat is no longer the one being looked at, so let ITS
  // notifications (banner + chime) through again.
  @override
  void didPushNext() {
    if (_activeChat.state == widget.chatId) _activeChat.state = null;
  }

  // Returned to the chat view (sub-screen popped) → suppress its own banner
  // again while it's back on top.
  @override
  void didPopNext() => _activeChat.state = widget.chatId;

  @override
  void dispose() {
    _unreadJumpFallback?.cancel();
    chatViewRouteObserver.unsubscribe(this);
    // LEAVING the chat means everything in it has been seen. Say so once, here.
    //
    // Marking-as-read otherwise happens only while the chat is on screen, as a
    // reaction to messages arriving — and that reaction competes with the
    // global handler that bumps the badge for every incoming message. Lose the
    // race (app backgrounded, controller already torn down, message landing
    // mid-navigation) and the chat you just read still wears an unread badge.
    // Reported 2026-08-05: "manchmal", which is what a race looks like from
    // the outside.
    //
    // This is deliberately a SECOND, unconditional pass rather than a fix to
    // the race: leaving is the one moment where the answer is never in doubt.
    _chats.resetUnreadCount(widget.chatId);
    // Only clear if we are still the active chat — a push-replace to another
    // ChatViewScreen sets its own id in initState before our dispose runs.
    final active = _activeChat;
    if (active.state == widget.chatId) {
      // Post-frame for the same reason as initState (dispose happens mid-tick).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (active.state == widget.chatId) active.state = null;
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The membership banner (ChatViewBanners) sits ABOVE the chat's app bar and
    // wraps itself in SafeArea. The app bar (chatview package) also adds its own
    // top safe-area inset — so when a banner is shown both consume the inset and
    // leave a large gap between the banner and the app bar. Strip the app bar's
    // inset only while a banner is visible.
    final showBanner = ref.watch(
      chatViewControllerProvider(widget.chatId).select((s) => s.isNotMember),
    );
    Widget body = ChatViewBody(chatId: widget.chatId);
    if (showBanner) {
      body = MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: body,
      );
    }
    return Scaffold(
      body: Column(
        children: [
          // Above the membership banners on purpose: an outage explains why the
          // rest of the screen is silent, so it must not be hidden behind a
          // banner about something else.
          const ServerOfflineBanner(),
          ChatViewBanners(chatId: widget.chatId),
          Expanded(child: body),
        ],
      ),
    );
  }
}
