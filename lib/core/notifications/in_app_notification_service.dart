// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Types of in-app notifications
enum NotificationType {
  newMessage,
  memberRequest,
  memberAccepted,
  memberRejected,
  info,
  error,
}

/// In-app notification data model
class InAppNotification {
  final String id;
  final NotificationType type;
  final String title;
  final String message;
  final DateTime timestamp;
  final VoidCallback? onTap;
  final Duration? duration;
  
  /// Optional data for navigation
  final String? chatId;
  final String? userId;

  InAppNotification({
    String? id,
    required this.type,
    required this.title,
    required this.message,
    DateTime? timestamp,
    this.onTap,
    this.duration,
    this.chatId,
    this.userId,
  })  : id = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        timestamp = timestamp ?? DateTime.now();

  IconData get icon {
    switch (type) {
      case NotificationType.newMessage:
        return Icons.message;
      case NotificationType.memberRequest:
        return Icons.person_add;
      case NotificationType.memberAccepted:
        return Icons.check_circle;
      case NotificationType.memberRejected:
        return Icons.cancel;
      case NotificationType.info:
        return Icons.info;
      case NotificationType.error:
        return Icons.error;
    }
  }

  Color get color {
    switch (type) {
      case NotificationType.newMessage:
        return Colors.blue;
      case NotificationType.memberRequest:
        return Colors.orange;
      case NotificationType.memberAccepted:
        return Colors.green;
      case NotificationType.memberRejected:
        return Colors.red;
      case NotificationType.info:
        return Colors.blue;
      case NotificationType.error:
        return Colors.red;
    }
  }
}

/// Service for managing in-app notifications
class InAppNotificationService {
  final StreamController<InAppNotification> _notificationController =
      StreamController<InAppNotification>.broadcast();

  /// Stream of notifications to display
  Stream<InAppNotification> get notifications => _notificationController.stream;

  /// Show a notification. The audible/haptic cue for incoming social
  /// notifications is handled by the overlay widget (which always has a live
  /// binding), keeping this service pure and unit-testable.
  void show(InAppNotification notification) {
    _notificationController.add(notification);
  }

  /// Show a new message notification
  void showNewMessage({
    required String chatName,
    required String senderName,
    required String message,
    required String chatId,
    VoidCallback? onTap,
  }) {
    show(InAppNotification(
      type: NotificationType.newMessage,
      title: chatName,
      message: '$senderName: $message',
      chatId: chatId,
      onTap: onTap,
      duration: const Duration(seconds: 4),
    ));
  }

  /// Show a member request notification
  void showMemberRequest({
    required String username,
    required String chatName,
    required String chatId,
    required String userId,
    VoidCallback? onTap,
  }) {
    show(InAppNotification(
      type: NotificationType.memberRequest,
      title: 'notifications.new_join_request'.tr(),
      message: 'notifications.wants_to_join'
          .tr(namedArgs: {'user': username, 'chat': chatName}),
      chatId: chatId,
      userId: userId,
      onTap: onTap,
      duration: const Duration(seconds: 5),
    ));
  }

  /// Show a member accepted notification
  void showMemberAccepted({
    required String chatName,
    required String chatId,
    VoidCallback? onTap,
  }) {
    show(InAppNotification(
      type: NotificationType.memberAccepted,
      title: 'notifications.request_accepted'.tr(),
      message: 'notifications.can_now_send'.tr(namedArgs: {'chat': chatName}),
      chatId: chatId,
      onTap: onTap,
      duration: const Duration(seconds: 4),
    ));
  }

  /// Show a member rejected notification
  void showMemberRejected({
    required String chatName,
    VoidCallback? onTap,
  }) {
    show(InAppNotification(
      type: NotificationType.memberRejected,
      title: 'notifications.request_rejected'.tr(),
      message:
          'notifications.request_rejected_body'.tr(namedArgs: {'chat': chatName}),
      onTap: onTap,
      duration: const Duration(seconds: 4),
    ));
  }

  /// Show an info notification
  void showInfo({
    required String title,
    required String message,
    VoidCallback? onTap,
  }) {
    show(InAppNotification(
      type: NotificationType.info,
      title: title,
      message: message,
      onTap: onTap,
      duration: const Duration(seconds: 3),
    ));
  }

  /// Show an error notification
  void showError({
    required String title,
    required String message,
    VoidCallback? onTap,
  }) {
    show(InAppNotification(
      type: NotificationType.error,
      title: title,
      message: message,
      onTap: onTap,
      duration: const Duration(seconds: 4),
    ));
  }

  /// Dispose the service
  void dispose() {
    _notificationController.close();
  }
}
