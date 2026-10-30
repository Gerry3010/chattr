// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';

import 'app_page_route.dart';
import 'chat_navigation.dart';
import '../../features/chats/chat_model.dart';
import '../../screens/chat/chat_members_screen.dart';
import '../../screens/chat/pending_requests_screen.dart';
import '../../screens/chat/chat_view_screen.dart';

/// Service for handling global navigation
class NavigationService {
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Get the current context
  BuildContext? get context => navigatorKey.currentContext;

  /// Navigate to a chat by ID from a notification tap.
  ///
  /// Resets the stack down to the root (chat list) BEFORE opening the target,
  /// so tapping a notification while already inside another chat lands on
  /// `[chat list, target chat]` — not `[chat list, old chat, target chat]`,
  /// where "back" confusingly returned to the unrelated chat you were in.
  /// `pushAndRemoveUntil(..isFirst)` does the reset + open as one transition.
  ///
  /// If that chat is already on the stack, go back to it instead (CHAT-53).
  /// Pushing a second screen of the open chat let the old one, disposed after
  /// the transition, clear the active chat — and the chat then bannered its
  /// own messages.
  void navigateToChat(Chat chat) {
    if (context == null) return;
    _dismissKeyboard();

    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    if (OpenChats.isOpen(chat.id)) {
      navigator.popUntil(
        (route) =>
            route.settings.name == chatRouteName(chat.id) || route.isFirst,
      );
      return;
    }

    navigator.pushAndRemoveUntil(
      appPageRoute<void>(
        settings: RouteSettings(name: chatRouteName(chat.id)),
        builder: (_) => ChatViewScreen(chatId: chat.id),
      ),
      (route) => route.isFirst,
    );
  }

  /// Navigate to a chat's members screen from a notification tap. Same
  /// stack-reset rationale as [navigateToChat].
  void navigateToChatMembers(Chat chat) {
    if (context == null) return;
    _dismissKeyboard();

    navigatorKey.currentState?.pushAndRemoveUntil(
      appPageRoute<void>(
        builder: (_) => ChatMembersScreen(chat: chat),
      ),
      (route) => route.isFirst,
    );
  }

  /// Open the requests inbox — the route of a tapped chat request (00082). It
  /// hangs on NO chat, since there is none yet; so it leads not into a
  /// conversation but to where one answers it. Same stack reset as
  /// [navigateToChat].
  void navigateToRequests() {
    if (context == null) return;
    _dismissKeyboard();

    navigatorKey.currentState?.pushAndRemoveUntil(
      appPageRoute<void>(builder: (_) => const PendingRequestsScreen()),
      (route) => route.isFirst,
    );
  }

  /// Drop keyboard focus before a `pushAndRemoveUntil` reset. The removed
  /// route's composer `TextField` may hold focus; disposing it without
  /// unfocusing leaves the platform text-input connection open, so iOS keeps
  /// the keyboard up over the target chat (whose composer never asks for
  /// focus). Unfocusing first closes that connection cleanly. Not iOS-specific.
  void _dismissKeyboard() {
    // Target the actually-focused node directly: [context] here is the
    // Navigator's, which sits above the chat screens, so FocusScope.of(context)
    // would be the root scope, not the composer's.
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// Pop current route
  void pop() {
    navigatorKey.currentState?.pop();
  }

  /// Pop until first route
  void popToRoot() {
    navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }
}
