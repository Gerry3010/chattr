// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/core/notifications/in_app_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('InAppNotificationService', () {
    late InAppNotificationService service;

    setUp(() {
      service = InAppNotificationService();
    });

    tearDown(() {
      service.dispose();
    });

    test('emits notification when show is called', () async {
      final notification = InAppNotification(
        type: NotificationType.info,
        title: 'Test Title',
        message: 'Test Message',
      );

      expectLater(
        service.notifications,
        emits(notification),
      );

      service.show(notification);
    });

    test('showNewMessage creates correct notification', () async {
      service.notifications.listen(
        expectAsync1((notification) {
          expect(notification.type, NotificationType.newMessage);
          expect(notification.title, 'Test Chat');
          expect(notification.message, 'Alice: Hello World');
          expect(notification.chatId, 'chat-123');
          expect(notification.duration, const Duration(seconds: 4));
        }),
      );

      service.showNewMessage(
        chatName: 'Test Chat',
        senderName: 'Alice',
        message: 'Hello World',
        chatId: 'chat-123',
      );
    });

    test('showMemberRequest creates correct notification', () async {
      service.notifications.listen(
        expectAsync1((notification) {
          expect(notification.type, NotificationType.memberRequest);
          // Localized via easy_localization; without EasyLocalization loaded in
          // the test, .tr() yields the raw key — assert the correct key is wired.
          expect(notification.title, 'notifications.new_join_request');
          expect(notification.message, 'notifications.wants_to_join');
          expect(notification.chatId, 'chat-456');
          expect(notification.userId, 'user-789');
          expect(notification.duration, const Duration(seconds: 5));
        }),
      );

      service.showMemberRequest(
        username: 'Bob',
        chatName: 'Test Group',
        chatId: 'chat-456',
        userId: 'user-789',
      );
    });

    test('showMemberAccepted creates correct notification', () async {
      service.notifications.listen(
        expectAsync1((notification) {
          expect(notification.type, NotificationType.memberAccepted);
          expect(notification.title, 'notifications.request_accepted');
          expect(notification.message, 'notifications.can_now_send');
          expect(notification.chatId, 'chat-123');
        }),
      );

      service.showMemberAccepted(
        chatName: 'Test Group',
        chatId: 'chat-123',
      );
    });

    test('showMemberRejected creates correct notification', () async {
      service.notifications.listen(
        expectAsync1((notification) {
          expect(notification.type, NotificationType.memberRejected);
          expect(notification.title, 'notifications.request_rejected');
          expect(notification.message, 'notifications.request_rejected_body');
        }),
      );

      service.showMemberRejected(
        chatName: 'Test Group',
      );
    });

    test('showInfo creates correct notification', () async {
      service.notifications.listen(
        expectAsync1((notification) {
          expect(notification.type, NotificationType.info);
          expect(notification.title, 'Info Title');
          expect(notification.message, 'Info Message');
          expect(notification.duration, const Duration(seconds: 3));
        }),
      );

      service.showInfo(
        title: 'Info Title',
        message: 'Info Message',
      );
    });

    test('showError creates correct notification', () async {
      service.notifications.listen(
        expectAsync1((notification) {
          expect(notification.type, NotificationType.error);
          expect(notification.title, 'Error Title');
          expect(notification.message, 'Error Message');
          expect(notification.duration, const Duration(seconds: 4));
        }),
      );

      service.showError(
        title: 'Error Title',
        message: 'Error Message',
      );
    });

    test('multiple notifications are emitted in sequence', () async {
      final notifications = <InAppNotification>[];
      
      service.notifications.listen((notification) {
        notifications.add(notification);
      });

      service.showInfo(title: 'First', message: 'Message 1');
      service.showInfo(title: 'Second', message: 'Message 2');
      service.showInfo(title: 'Third', message: 'Message 3');

      await Future.delayed(const Duration(milliseconds: 100));

      expect(notifications.length, 3);
      expect(notifications[0].title, 'First');
      expect(notifications[1].title, 'Second');
      expect(notifications[2].title, 'Third');
    });
  });

  group('InAppNotification', () {
    test('generates unique IDs', () async {
      final notification1 = InAppNotification(
        type: NotificationType.info,
        title: 'Test',
        message: 'Message',
      );

      // Small delay to ensure different timestamp
      await Future.delayed(const Duration(milliseconds: 1));

      final notification2 = InAppNotification(
        type: NotificationType.info,
        title: 'Test',
        message: 'Message',
      );

      expect(notification1.id, isNot(equals(notification2.id)));
    });

    test('uses provided ID', () {
      final notification = InAppNotification(
        id: 'custom-id',
        type: NotificationType.info,
        title: 'Test',
        message: 'Message',
      );

      expect(notification.id, 'custom-id');
    });

    test('returns correct icon for each type', () {
      expect(
        InAppNotification(
          type: NotificationType.newMessage,
          title: 'Test',
          message: 'Message',
        ).icon,
        Icons.message,
      );

      expect(
        InAppNotification(
          type: NotificationType.memberRequest,
          title: 'Test',
          message: 'Message',
        ).icon,
        Icons.person_add,
      );

      expect(
        InAppNotification(
          type: NotificationType.memberAccepted,
          title: 'Test',
          message: 'Message',
        ).icon,
        Icons.check_circle,
      );

      expect(
        InAppNotification(
          type: NotificationType.memberRejected,
          title: 'Test',
          message: 'Message',
        ).icon,
        Icons.cancel,
      );

      expect(
        InAppNotification(
          type: NotificationType.info,
          title: 'Test',
          message: 'Message',
        ).icon,
        Icons.info,
      );

      expect(
        InAppNotification(
          type: NotificationType.error,
          title: 'Test',
          message: 'Message',
        ).icon,
        Icons.error,
      );
    });

    test('returns correct color for each type', () {
      expect(
        InAppNotification(
          type: NotificationType.newMessage,
          title: 'Test',
          message: 'Message',
        ).color,
        Colors.blue,
      );

      expect(
        InAppNotification(
          type: NotificationType.memberRequest,
          title: 'Test',
          message: 'Message',
        ).color,
        Colors.orange,
      );

      expect(
        InAppNotification(
          type: NotificationType.memberAccepted,
          title: 'Test',
          message: 'Message',
        ).color,
        Colors.green,
      );

      expect(
        InAppNotification(
          type: NotificationType.memberRejected,
          title: 'Test',
          message: 'Message',
        ).color,
        Colors.red,
      );

      expect(
        InAppNotification(
          type: NotificationType.info,
          title: 'Test',
          message: 'Message',
        ).color,
        Colors.blue,
      );

      expect(
        InAppNotification(
          type: NotificationType.error,
          title: 'Test',
          message: 'Message',
        ).color,
        Colors.red,
      );
    });

    test('onTap callback is stored correctly', () {
      var tapped = false;
      final notification = InAppNotification(
        type: NotificationType.info,
        title: 'Test',
        message: 'Message',
        onTap: () {
          tapped = true;
        },
      );

      notification.onTap?.call();
      expect(tapped, true);
    });

    test('stores optional chatId and userId', () {
      final notification = InAppNotification(
        type: NotificationType.newMessage,
        title: 'Test',
        message: 'Message',
        chatId: 'chat-123',
        userId: 'user-456',
      );

      expect(notification.chatId, 'chat-123');
      expect(notification.userId, 'user-456');
    });
  });
}
