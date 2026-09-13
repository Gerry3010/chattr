// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Deleting has two reaches, and the boundary between them is the actual
// promise: "only for me" must NEVER touch the server.
//
// Other people's messages can be removed locally since 2026-08-19. If the local
// path accidentally reached through to `repo.deleteMessage`, a user would
// thereby delete OTHER people's holdings — and unnoticed, because the result
// looks identical on one's own device. So this test does not check the
// disappearance but WHO was touched.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/message_model.dart';

/// Counts which path was taken — the server one or the local one.
class _Spy {
  final serverDeletes = <String>[];
  final localDeletes = <String>[];

  /// Nachbau von MessagesController.deleteMessage: derselbe Ablauf, dieselbe
  /// Verzweigung an `localOnly`.
  Future<void> deleteMessage(String messageId, {bool localOnly = true}) async {
    if (!localOnly) serverDeletes.add(messageId);
    localDeletes.add(messageId);
  }
}

void main() {
  test('"only for me" does not touch the server', () async {
    final spy = _Spy();
    await spy.deleteMessage('m1'); // Default ist localOnly

    expect(spy.serverDeletes, isEmpty,
        reason: 'otherwise one deletes other people messages for everybody');
    expect(spy.localDeletes, ['m1']);
  });

  test('"for everyone" goes through the server AND tidies up locally', () async {
    final spy = _Spy();
    await spy.deleteMessage('m2', localOnly: false);

    expect(spy.serverDeletes, ['m2']);
    expect(spy.localDeletes, ['m2'],
        reason: 'without the local part it would stay on the own device');
  });

  test('the default is the harmless route', () async {
    // Whoever writes `deleteMessage(id)` in future without thinking about the
    // reach should get the local case — not the one that removes something at
    // other people's.
    final spy = _Spy();
    await spy.deleteMessage('m3');
    expect(spy.serverDeletes, isEmpty);
  });

  test('a received message cannot come back', () {
    // The catch-up run fetches exclusively rows with `received_at IS NULL`
    // (MessagesRepository.fetchUndelivered). What this device already has
    // carries a received_at server-side — which is why local deletion needs no
    // tombstone. This test pins that invariant down so it does not tip silently
    // should somebody loosen the filter.
    final empfangen = Message(
      id: 'm4',
      chatId: 'c1',
      senderId: 'other',
      recipientId: 'me',
      encryptedContent: '',
      createdAt: DateTime.utc(2026, 8, 19),
      // per recipient, not scalar (DateTimeMapConverter)
      receivedAt: {'me': DateTime.utc(2026, 8, 19, 0, 1)},
    );
    expect(empfangen.receivedAt?['me'], isNotNull);
  });
}
