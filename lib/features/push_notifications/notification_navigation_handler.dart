// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/logging/logger_service.dart';
import '../../core/navigation/navigation_provider.dart';
import '../app_lock/app_lock_controller.dart';
import '../chats/chat_model.dart';
import '../chats/chats_controller.dart';

/// Handler for notification navigation
class NotificationNavigationHandler {
  final Ref _ref;

  NotificationNavigationHandler(this._ref);

  /// Handle notification tap and navigate to appropriate screen
  Future<void> handleNotificationTap(Map<String, dynamic> data) async {
    final type = data['type'] as String?;
    final chatId = data['chat_id'] as String?;

    logger.info('Handling notification tap: type=$type, chatId=$chatId');

    if (chatId == null) {
      logger.warning('No chat_id in notification data');
      return;
    }

    try {
      switch (type) {
        case 'new_message':
          await _navigateToChat(chatId);
          break;

        case 'member_request':
          await _navigateToChatMembers(chatId);
          break;

        case 'request_accepted':
        case 'request_rejected':
        case 'reaction':
          await _navigateToChat(chatId);
          break;

        default:
          logger.warning('Unknown notification type: $type');
      }
    } catch (e, stackTrace) {
      logger.error(
        'Failed to handle notification navigation',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Waits for [chatId] to appear in the loaded chats list.
  ///
  /// On a cold start (launch via notification tap) the chats controller is
  /// still fetching when the tap is processed — an immediate lookup misses
  /// and the tap used to end in a silent no-op. Poll briefly instead; chats
  /// normally arrive within a second or two of auth.
  Future<Chat?> _waitForChat(String chatId) async {
    const attempts = 20;
    const interval = Duration(milliseconds: 500);
    for (var i = 0; i < attempts; i++) {
      final chat = _ref
          .read(chatsControllerProvider)
          .where((c) => c.id == chatId)
          .firstOrNull;
      if (chat != null) return chat;
      await Future<void>.delayed(interval);
    }
    return null;
  }

  /// Waits until the app-lock screen (if any) is dismissed.
  ///
  /// A notification tap can wake a *locked* app: the Face-ID lock screen goes
  /// up and iOS drops the app to `inactive` while the system biometric UI is
  /// shown, which pauses the frame ticker. Pushing the chat route in that
  /// window starts the SwipeablePageRoute transition mid-`inactive`, and it
  /// sticks as a grey, half-transitioned screen the user can't escape — only
  /// on notification taps, because that's the only path that navigates while
  /// the lock is up. Defer the push until the app is unlocked and back on
  /// screen. With no lock enabled `locked` is already false → returns at once.
  Future<void> _waitForUnlock() async {
    const attempts = 240; // ~60s — the user may take a moment to authenticate
    const interval = Duration(milliseconds: 250);
    for (var i = 0; i < attempts; i++) {
      if (!_ref.read(appLockControllerProvider).locked) {
        // Let the just-dismissed lock overlay hand the frame ticker back
        // before we start the route transition.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return;
      }
      await Future<void>.delayed(interval);
    }
    logger.warning('Navigating while still locked — unlock timed out');
  }

  /// Navigate to chat view
  Future<void> _navigateToChat(String chatId) async {
    final navigationService = _ref.read(navigationServiceProvider);

    final chat = await _waitForChat(chatId);
    if (chat == null) {
      logger.warning('Cannot navigate: chat never loaded: $chatId');
      return;
    }

    await _waitForUnlock();
    navigationService.navigateToChat(chat);
    logger.info('Navigated to chat: $chatId');
  }

  /// Navigate to chat members screen
  Future<void> _navigateToChatMembers(String chatId) async {
    final navigationService = _ref.read(navigationServiceProvider);

    final chat = await _waitForChat(chatId);
    if (chat == null) {
      logger.warning('Cannot navigate to members: chat never loaded: $chatId');
      return;
    }

    await _waitForUnlock();
    navigationService.navigateToChatMembers(chat);
    logger.info('Navigated to chat members: $chatId');
  }
}

/// Provider for notification navigation handler
final notificationNavigationHandlerProvider =
    Provider<NotificationNavigationHandler>((ref) {
      return NotificationNavigationHandler(ref);
    });
