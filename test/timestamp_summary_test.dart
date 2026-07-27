// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Slide-to-Timestamp (#107b): the peek chip's status/time selection. Read state
// is gated by the reciprocal read-receipt setting (showRead) — with it off a
// message can never surface as "read", only "delivered". Foreign messages show
// the sent time.

import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/screens/chat/components/timestamp_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final created = DateTime.utc(2026, 7, 15, 10);
  final recv1 = created.add(const Duration(minutes: 1));
  final recv2 = created.add(const Duration(minutes: 2));
  final read1 = created.add(const Duration(minutes: 3));
  final read2 = created.add(const Duration(minutes: 5));

  Message msg({
    String sender = 'me',
    Map<String, DateTime?>? receivedAt,
    Map<String, DateTime?>? readAt,
  }) =>
      Message(
        id: 'm1',
        chatId: 'c1',
        senderId: sender,
        recipientId: 'other',
        createdAt: created,
        receivedAt: receivedAt ?? const {},
        readAt: readAt ?? const {},
        decryptedContent: 'hi',
      );

  test('incoming message → sent time, no own-status', () {
    final s = timestampSummary(msg(sender: 'other'), 'me', true);
    expect(s.status, TimestampStatus.incoming);
    expect(s.time, created);
  });

  test('own all-read → read with the LATEST read time', () {
    final s = timestampSummary(
      msg(receivedAt: {'a': recv1, 'b': recv2}, readAt: {'a': read1, 'b': read2}),
      'me',
      true,
    );
    expect(s.status, TimestampStatus.read);
    expect(s.time, read2); // latest across recipients
  });

  test('own all-read but receipts OFF → caps at delivered (latest received)', () {
    final s = timestampSummary(
      msg(receivedAt: {'a': recv1, 'b': recv2}, readAt: {'a': read1, 'b': read2}),
      'me',
      false,
    );
    expect(s.status, TimestampStatus.delivered);
    expect(s.time, recv2);
  });

  test('own partially read → delivered (not everyone read)', () {
    final s = timestampSummary(
      msg(receivedAt: {'a': recv1, 'b': recv2}, readAt: {'a': read1, 'b': null}),
      'me',
      true,
    );
    expect(s.status, TimestampStatus.delivered);
    expect(s.time, recv2);
  });

  test('own not-yet-delivered → sent (createdAt)', () {
    final s = timestampSummary(
      msg(receivedAt: {'a': recv1, 'b': null}, readAt: {'a': null, 'b': null}),
      'me',
      true,
    );
    expect(s.status, TimestampStatus.sent);
    expect(s.time, created);
  });
}
