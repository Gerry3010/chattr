// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart' show StateController;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../core/navigation/chat_navigation.dart';
import '../../core/diagnostics/ui_trace.dart';
import '../../core/logging/logger_service.dart';
import '../../core/notifications/active_chat_provider.dart';
import '../../features/chat_view/chat_view_controller.dart';
import '../../features/chats/chats_controller.dart';
import 'components/chat_view_banners.dart';
import 'components/server_offline_banner.dart';
import 'components/top_banner_column.dart';
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
    // For openChatAtMessage: only whoever knows that this chat is already on
    // the stack may safely pop back to it instead of pushing anew.
    OpenChats.enter(widget.chatId);
    _activeChat = ref.read(activeChatProvider.notifier);
    _chats = ref.read(chatsControllerProvider.notifier);
    // Mark this chat as on-screen so in-app banners/chime skip it. Post-frame:
    // providers must not be mutated during build/initState of a widget tick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      logger.info('chat ${shortId(widget.chatId)} opened → active',
          tag: uiTraceTag);
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
    logger.info('chat ${shortId(widget.chatId)} covered by a pushed route',
        tag: uiTraceTag);
    if (_activeChat.state == widget.chatId) _activeChat.state = null;
  }

  // Returned to the chat view (sub-screen popped) → suppress its own banner
  // again while it's back on top.
  @override
  void didPopNext() {
    logger.info('chat ${shortId(widget.chatId)} uncovered → active',
        tag: uiTraceTag);
    _activeChat.state = widget.chatId;
  }

  @override
  void dispose() {
    OpenChats.leave(widget.chatId);
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
    // A second screen of the SAME chat would defeat that check (its id is
    // ours); NavigationService.navigateToChat therefore returns to an open
    // chat instead of stacking it again (CHAT-53).
    final active = _activeChat;
    logger.info('chat ${shortId(widget.chatId)} disposed', tag: uiTraceTag);
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
    // The banners sit ABOVE the chat's app bar, which (chatview package) pads
    // for the status bar itself. TopBannerColumn hands the inset to whichever
    // shows first, so it is never applied twice.
    return Scaffold(
      body: TopBannerColumn(
        banners: [
          // Above the chat banners on purpose: an outage explains why the rest
          // of the screen is silent, so it must not be hidden behind a banner
          // about something else.
          (
            banner: const ServerOfflineBanner(),
            visible: ref.watch(serverBannerProvider) != null,
          ),
          (
            banner: ChatViewBanners(chatId: widget.chatId),
            visible: ref.watch(chatBannerProvider(widget.chatId)) != null,
          ),
        ],
        child: ChatViewBody(chatId: widget.chatId),
      ),
    );
  }
}
