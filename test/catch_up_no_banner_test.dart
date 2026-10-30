// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Caught-up messages must not trigger banners.
//
// Reported on 2026-08-19 with a screenshot: after opening the app around ten
// banners popped up at once. The first, real push had come correctly — the rest
// came from the catch-up run, which sends every missed message through EXACTLY
// the same path as one arriving live. That is deliberate (decryption, prekey
// consumption, persistence and delivery confirmation should run identically),
// only the banner must not ride along.
//
// The delicate part is not the marking itself but its PASSING ON: the
// GlobalMessageHandler re-emits the decrypted event via `copyWith`, and that
// second event is exactly what the notification path sees. If `catchUp` drops
// out there, the fix is without effect and nobody notices — hence this as a
// test of its own.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/events/event_types.dart';
import 'package:chattr/features/messages/global_message_handler.dart';
import 'package:chattr/features/messages/message_model.dart';

Message _pending({String id = 'm1', String? ciphertext = 'zzz'}) => Message(
      id: id,
      chatId: 'c1',
      senderId: 'other',
      recipientId: 'me',
      encryptedContent: ciphertext,
      createdAt: DateTime.utc(2026, 8, 19, 12),
    );

void main() {
  group('catchUpEventFor', () {
    test('markiert nachgeholte Nachrichten', () {
      final event = catchUpEventFor(_pending());
      expect(event, isNotNull);
      expect(event!.catchUp, isTrue);
    });

    test('skips rows without ciphertext', () {
      expect(catchUpEventFor(_pending(ciphertext: null)), isNull);
      expect(catchUpEventFor(_pending(ciphertext: '')), isNull);
    });
  });

  group('passing the marking on', () {
    test('copyWith keeps it — that is the actual fix', () {
      final caught = catchUpEventFor(_pending())!;

      // Exactly what the GlobalMessageHandler does after decrypting.
      final reemitted = caught
          .copyWith(decrypted: true, content: 'hallo', replyToPreview: '')
          .asProcessed() as NewMessageEvent;

      expect(reemitted.decrypted, isTrue);
      expect(
        reemitted.catchUp,
        isTrue,
        reason: 'without passing it on, the banner path sees a live event'
            'und der Fix ist wirkungslos',
      );
    });

    test('an event arriving live stays unmarked', () {
      final live = NewMessageEvent(
        chatId: 'c1',
        messageId: 'm2',
        senderId: 'other',
        content: 'zzz',
        messageType: MessageType.user,
      );
      expect(live.catchUp, isFalse);
      expect(
        (live.copyWith(decrypted: true, content: 'hallo') as NewMessageEvent)
            .catchUp,
        isFalse,
      );
    });

    test('what comes over the wire is never marked', () {
      // A counter-check as a safeguard: even if a server sent the field along,
      // it must not be able to suppress banners.
      final fromWire = NewMessageEvent.fromJson({
        'type': 'new_message',
        'chat_id': 'c1',
        'message_id': 'm3',
        'sender_id': 'other',
        'content': 'zzz',
        'message_type': 'user',
        'catchUp': true,
        'catch_up': true,
      });
      expect(fromWire.catchUp, isFalse);
    });
  });
}
