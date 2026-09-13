// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The invite envelope decides whether a message renders as a join card. A
// false positive would swallow someone's text into a broken card; a false
// negative merely shows JSON — so the parser must be strict.

import 'package:chattr/features/invites/invite_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips through the wire format', () {
    final decoded = InviteEnvelope.tryParse(
      const InviteEnvelope(chatId: 'c1', chatName: 'Familie', token: 't1')
          .encode(),
    );
    expect(decoded, isNotNull);
    expect(decoded!.chatId, 'c1');
    expect(decoded.chatName, 'Familie');
    expect(decoded.token, 't1');
  });

  test('ordinary messages and other envelopes are left alone', () {
    for (final body in [
      'Hallo!',
      '',
      '{"_chattr_media":1}',
      '{"_chattr_summarize":1,"scope":"unread"}',
      // Talking ABOUT the marker is not an invitation.
      'Der Marker heisst _chattr_invite, oder?',
      // Broken JSON carrying the marker degrades to a normal message.
      '{"_chattr_invite":1, kaputt',
      // Marker present but fields missing/mistyped: not a card.
      '{"_chattr_invite":1}',
      '{"_chattr_invite":1,"chat_id":1,"chat_name":"x","token":"t"}',
    ]) {
      expect(InviteEnvelope.tryParse(body), isNull, reason: body);
    }
    expect(InviteEnvelope.tryParse(null), isNull);
  });
}
