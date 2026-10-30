// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The "Edited" label must come ONLY from the explicit edited_at marker.
// updated_at is bumped by a DB trigger on every row update (read/receive
// marks), so it must never influence the label (that was bug: unedited
// messages showed "Edited" after a resume-resync).

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/models/optional.dart';
import 'package:chattr/features/messages/message_model.dart';

void main() {
  final created = DateTime.utc(2026, 7, 10, 10);

  Message message({DateTime? updatedAt, DateTime? editedAt}) => Message(
        id: 'm1',
        chatId: 'c1',
        senderId: 'u1',
        recipientId: 'u2',
        createdAt: created,
        updatedAt: updatedAt,
        editedAt: editedAt,
        decryptedContent: 'hello',
      );

  test('no edited label without edited_at, even when updated_at is later', () {
    final chatMsg = message(
      updatedAt: created.add(const Duration(minutes: 5)),
    ).toChatViewMessage();
    expect(chatMsg.updatedAt, isNull);
  });

  test('edited label shown iff edited_at is set', () {
    final editedAt = created.add(const Duration(minutes: 1));
    final chatMsg = message(editedAt: editedAt).toChatViewMessage();
    expect(chatMsg.updatedAt, editedAt);
  });

  test('edited_at survives JSON round-trip (local persistence)', () {
    final editedAt = created.add(const Duration(minutes: 1));
    final restored = Message.fromJson(message(editedAt: editedAt).toJson());
    expect(restored.editedAt, editedAt);
  });

  test('editedAt participates in equality/hash (UI diffing)', () {
    final a = message();
    final b = a.copyWith();
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);

    final edited = a.copyWith(
      editedAt: Optional(created.add(const Duration(minutes: 1))),
    );
    expect(a == edited, isFalse);
  });
}
