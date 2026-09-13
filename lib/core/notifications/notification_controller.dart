// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/media_preview_label.dart';
import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/features/messages/global_search_controller.dart'
    show chatDisplayNameProvider;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_controller.dart';
import '../../features/chats/chats_controller.dart';
import '../../features/chats/mute_controller.dart';
import '../../features/profiles/profiles_controller.dart';
import '../events/event_bus_provider.dart';
import '../events/event_types.dart';
import '../navigation/navigation_provider.dart';
import 'active_chat_provider.dart';
import 'in_app_notification_service.dart';
import 'notification_provider.dart';
import '../../features/places/place_preview_label.dart';

/// Controller that connects event bus to notification service
class NotificationController {
  final Ref _ref;
  final InAppNotificationService _notificationService;
  final String? _userId;

  StreamSubscription<BusEvent>? _sub;

  NotificationController(this._ref, this._notificationService, this._userId) {
    if (_userId != null) {
      _init();
    }
  }

  void _init() {
    final eventBus = _ref.read(eventBusProvider);
    if (eventBus == null) return;

    _sub = eventBus.eventStream.listen((event) {
      if (event is NewMessageEvent) {
        _handleNewMessage(event);
      } else if (event is PendingMemberEvent) {
        // For admins.
        _handlePendingMember(event);
      } else if (event is NewChatEvent && _userId != null) {
        // The user was accepted into a chat.
        _handleMemberStatusChanged(
          MemberStatusChangedEvent(
            chatId: event.chatId,
            userId: _userId,
            accepted: true,
          ),
        );
      }
    });
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _handleNewMessage(NewMessageEvent event) async {
    // Don't show notification for own messages or if not decrypted
    if (event.senderId == _userId || event.decrypted == false) return;

    // Muted chat: suppress the in-app banner (push is already filtered
    // server-side in notify_members_new_message).
    if (_ref.read(mutedChatsProvider.notifier).isMuted(event.chatId)) return;

    // The chat is on screen right now: the message appears live in the view,
    // so banner + chime would be redundant noise.
    if (_ref.read(activeChatProvider) == event.chatId) return;

    // Backlog, not news. The catch-up run at start replays every message that
    // arrived while the app was closed through this very path — deliberately,
    // so decryption, prekeys, persistence and receipts behave identically. But
    // a banner each turns opening the app into a wall of notifications for
    // things the user already got a real push about (reported 2026-08-19 with
    // a screenshot: ~10 banners at once).
    //
    // Only the BANNER is suppressed. The unread count is derived from the
    // local database (`ChatsController._withLocalUnread` → `countUnread`), not
    // from this stream, so it keeps counting these messages exactly as before.
    if (event.catchUp) return;

    try {
      // Get chat info
      final chatsController = _ref.read(chatsControllerProvider);
      final chats = chatsController;
      final chat = chats.where((c) => c.id == event.chatId).firstOrNull;

      // If chat not found, skip notification (might not be loaded yet)
      if (chat == null) {
        debugPrint('Chat ${event.chatId} not found for notification');
        return;
      }

      final String senderName;
      // Same {"action":...} JSON as any system message — withDecryptedContent
      // parses it into formattedText's action/subjectName fields. Passing
      // event.content straight through (as this used to) showed the raw
      // JSON in the banner; see message_model.dart's formattedText doc.
      final String bannerMessage;
      if (event.messageType == MessageType.system) {
        senderName = 'System';
        bannerMessage = SystemMessage(
          id: event.messageId,
          chatId: event.chatId,
          recipientId: _userId!,
          createdAt: event.timestamp,
        ).withDecryptedContent(event.content).formattedText;
      } else if (event.senderId != null) {
        // Get sender profile
        final profilesController = _ref.read(
          profilesControllerProvider.notifier,
        );
        final senderProfile = await profilesController.getProfile(event.senderId!);
        senderName = senderProfile.username;
        bannerMessage = _previewContent(event.content);
      } else {
        senderName = 'chat_detail.unknown_user'.tr();
        bannerMessage = _previewContent(event.content);
      }

      // Show notification
      final navigationService = _ref.read(navigationServiceProvider);
      // The banner used to show `chat.name ?? 'Chat'` — and a 1:1 chat HAS no
      // name, so the word "Chat" stood literally above every notice. The
      // correct name (group name or the counterpart's username) is resolved by
      // `chatDisplayNameProvider`; its own documentation names "notifications"
      // as a use case, only nobody here had used it.
      final chatName = _ref.read(chatDisplayNameProvider(event.chatId));
      _notificationService.showNewMessage(
        chatName: chatName,
        senderName: senderName,
        message: bannerMessage,
        chatId: event.chatId,
        onTap: () {
          navigationService.navigateToChat(chat);
        },
      );
    } catch (e) {
      debugPrint('Error showing new message notification: $e');
    }
  }

  /// Turn a message's raw content into a readable banner line. Media messages
  /// carry a JSON album envelope as their content — show the shared "📎 …"
  /// preview instead of the raw JSON (same as reply/forward/last-message).
  String _previewContent(String content) {
    if (content.isEmpty) return content;
    // Never a shot as raw text: the envelope carries path and media key, and a
    // notification is read on the lock screen.
    final shot = shotPreviewLabel(content);
    if (shot != null) return shot;
    final album = MediaAlbum.tryParse(content);
    if (album != null) return mediaPreviewLabel(album);
    return placePreviewLabel(content) ?? content;
  }

  Future<void> _handlePendingMember(PendingMemberEvent event) async {
    try {
      // Get chat info
      final chatsController = _ref.read(chatsControllerProvider);
      final chats = chatsController;
      final chat = chats.where((c) => c.id == event.chatId).firstOrNull;

      // If chat not found, skip notification
      if (chat == null) {
        debugPrint('Chat ${event.chatId} not found for notification');
        return;
      }

      // Only show to admins
      if (!chat.isAdmin(_userId!)) return;

      // Get user profile
      final profilesController = _ref.read(profilesControllerProvider.notifier);
      final userProfile = await profilesController.getProfile(event.userId);
      final username = userProfile.username;

      // Show notification
      final navigationService = _ref.read(navigationServiceProvider);
      final chatName = _ref.read(chatDisplayNameProvider(event.chatId));
      _notificationService.showMemberRequest(
        username: username,
        chatName: chatName,
        chatId: event.chatId,
        userId: event.userId,
        onTap: () {
          navigationService.navigateToChatMembers(chat);
        },
      );
    } catch (e) {
      debugPrint('Error showing member request notification: $e');
    }
  }

  Future<void> _handleMemberStatusChanged(
    MemberStatusChangedEvent event,
  ) async {
    // Only show notification for current user
    if (event.userId != _userId) return;

    try {
      // Get chat info
      final chatsController = _ref.read(chatsControllerProvider);
      final chats = chatsController;
      final chat = chats.where((c) => c.id == event.chatId).firstOrNull;

      // If chat not found, skip notification
      if (chat == null) {
        debugPrint('Chat ${event.chatId} not found for notification');
        return;
      }

      final navigationService = _ref.read(navigationServiceProvider);
      final chatName = _ref.read(chatDisplayNameProvider(event.chatId));
      if (event.accepted) {
        _notificationService.showMemberAccepted(
          chatName: chatName,
          chatId: event.chatId,
          onTap: () {
            navigationService.navigateToChat(chat);
          },
        );
      } else {
        _notificationService.showMemberRejected(
          chatName: chatName,
          onTap: () {
            navigationService.popToRoot();
          },
        );
      }
    } catch (e) {
      debugPrint('Error showing member status notification: $e');
    }
  }
}

/// Provider for notification controller
final notificationControllerProvider = Provider<NotificationController>((ref) {
  final notificationService = ref.watch(inAppNotificationServiceProvider);
  final userId = ref.watch(authControllerProvider);

  final controller = NotificationController(ref, notificationService, userId);
  ref.onDispose(controller.dispose);
  return controller;
});
