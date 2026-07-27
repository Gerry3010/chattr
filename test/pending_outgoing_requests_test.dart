// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/chats/pending_chat_member_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task #102: the `get_my_pending_requests()` RPC (migration 00043) feeds the
/// "my requests" overview section. These tests pin the row → model mapping,
/// which is where a JSON/typing bug would silently corrupt the outgoing list.
void main() {
  group('myPendingRequestFromRow', () {
    test('parses a normal group request', () {
      final req = myPendingRequestFromRow({
        'chat_id': 'abc123',
        'chat_name': 'Gerres Geräte',
        'is_group': true,
        'created_at': '2026-07-15T10:20:30.000Z',
        'blocked_at': null,
      });

      expect(req.chatId, 'abc123');
      expect(req.chatName, 'Gerres Geräte');
      expect(req.isGroup, isTrue);
      expect(req.createdAt.toUtc(),
          DateTime.utc(2026, 7, 15, 10, 20, 30));
      expect(req.blockedAt, isNull);
      expect(req.isBlocked, isFalse);
    });

    test('flags a blocked request', () {
      final req = myPendingRequestFromRow({
        'chat_id': 'blocked-1',
        'chat_name': 'Some Group',
        'is_group': true,
        'created_at': '2026-07-15T10:20:30.000Z',
        'blocked_at': '2026-07-15T11:00:00.000Z',
      });

      expect(req.isBlocked, isTrue);
      expect(req.blockedAt, isNotNull);
    });

    test('defaults is_group to true when absent', () {
      // Defensive: the RPC always returns is_group, but a null must not throw.
      final req = myPendingRequestFromRow({
        'chat_id': 'x',
        'chat_name': null,
        'is_group': null,
        'created_at': '2026-07-15T10:20:30.000Z',
        'blocked_at': null,
      });

      expect(req.isGroup, isTrue);
    });

    test('keeps chatName null so the UI can fall back to the short id', () {
      final req = myPendingRequestFromRow({
        'chat_id': '015f509f-786c-4ff9-a8a4-67e0529347dd',
        'chat_name': null,
        'is_group': true,
        'created_at': '2026-07-15T10:20:30.000Z',
        'blocked_at': null,
      });

      expect(req.chatName, isNull);
      // The screen renders `chat_list.chat_title` with the first 8 chars.
      expect(req.chatId.substring(0, 8), '015f509f');
    });

    test('parses timestamps with a timezone offset', () {
      final req = myPendingRequestFromRow({
        'chat_id': 'tz',
        'chat_name': 'TZ',
        'is_group': true,
        'created_at': '2026-07-15T12:20:30+02:00',
        'blocked_at': null,
      });

      // 12:20:30 +02:00 == 10:20:30 UTC
      expect(req.createdAt.toUtc(), DateTime.utc(2026, 7, 15, 10, 20, 30));
    });
  });
}
