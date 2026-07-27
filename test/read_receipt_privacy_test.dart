// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Reciprocal read-receipt privacy (#107a): when the local user disables read
// receipts, their outgoing bubbles must never show "read" — only "delivered".
// "Delivered" itself must always work, both when receipts are on and off. See
// sendReadReceiptsProvider and Message.toChatViewMessage(showReadReceipts:).

import 'package:chatview/chatview.dart' as chatview;
import 'package:chattr/features/messages/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final created = DateTime.utc(2026, 7, 15, 10);
  final t = created.add(const Duration(minutes: 1));

  Message message({
    Map<String, DateTime?>? receivedAt,
    Map<String, DateTime?>? readAt,
  }) =>
      Message(
        id: 'm1',
        chatId: 'c1',
        senderId: 'me',
        recipientId: 'other',
        createdAt: created,
        receivedAt: receivedAt ?? const {},
        readAt: readAt ?? const {},
        decryptedContent: 'hi',
      );

  test('receipts ON: all-read promotes to read status', () {
    final msg = message(receivedAt: {'other': t}, readAt: {'other': t});
    expect(msg.toChatViewMessage().status, chatview.MessageStatus.read);
  });

  test('receipts OFF: caps at delivered even when all read', () {
    final msg = message(receivedAt: {'other': t}, readAt: {'other': t});
    expect(
      msg.toChatViewMessage(showReadReceipts: false).status,
      chatview.MessageStatus.delivered,
    );
  });

  test('delivered always works regardless of the flag', () {
    final msg = message(receivedAt: {'other': t}, readAt: {'other': null});
    expect(msg.toChatViewMessage().status, chatview.MessageStatus.delivered);
    expect(
      msg.toChatViewMessage(showReadReceipts: false).status,
      chatview.MessageStatus.delivered,
    );
  });

  test('undelivered when not received (flag irrelevant)', () {
    final msg = message(receivedAt: {'other': null}, readAt: {'other': null});
    expect(msg.toChatViewMessage().status, chatview.MessageStatus.undelivered);
    expect(
      msg.toChatViewMessage(showReadReceipts: false).status,
      chatview.MessageStatus.undelivered,
    );
  });

  test('group: read only when EVERY member read, and OFF still caps', () {
    final partial = message(
      receivedAt: {'a': t, 'b': t},
      readAt: {'a': t, 'b': null},
    );
    expect(partial.toChatViewMessage().status,
        chatview.MessageStatus.delivered);

    final allRead = message(
      receivedAt: {'a': t, 'b': t},
      readAt: {'a': t, 'b': t},
    );
    expect(allRead.toChatViewMessage().status, chatview.MessageStatus.read);
    expect(
      allRead.toChatViewMessage(showReadReceipts: false).status,
      chatview.MessageStatus.delivered,
    );
  });
}
