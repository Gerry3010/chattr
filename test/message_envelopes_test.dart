// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Envelope cards must not offer Edit or Copy (Gerry, 2026-08-13: he shared a
// calendar entry, opened "edit", and got the raw `{"_chattr_event":1,…}`).
// Saving that would have broken the card for every recipient.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/message_envelopes.dart';

void main() {
  group('isEnvelopeMessage', () {
    test('a shared place is an envelope', () {
      expect(
        isEnvelopeMessage(
          '{"_chattr_location":1,"lat":48.2082,"lon":16.3738,'
          '"name":"Stephansdom"}',
        ),
        isTrue,
      );
    });

    test('a calendar entry is an envelope — the case Gerry hit', () {
      expect(
        isEnvelopeMessage(
          '{"_chattr_event":1,"title":"End of the World",'
          '"start":"2026-11-13T00:00:00.000Z","end":"2026-11-14T00:00:00.000Z",'
          '"all_day":true}',
        ),
        isTrue,
      );
    });

    test('a group invitation is an envelope', () {
      expect(
        isEnvelopeMessage(
          '{"_chattr_invite":1,"chat_id":"c1","chat_name":"Gruppe",'
          '"token":"abc"}',
        ),
        isTrue,
      );
    });

    test('ordinary prose is not — Edit and Copy must survive', () {
      expect(isEnvelopeMessage('Treffen wir uns um acht?'), isFalse);
      expect(isEnvelopeMessage('{ nicht wirklich json'), isFalse);
      expect(isEnvelopeMessage(''), isFalse);
      expect(isEnvelopeMessage(null), isFalse);
    });

    test('a JSON message that is none of ours stays editable', () {
      // Only OUR markers count. Someone pasting JSON into a chat is writing
      // text and must keep every text action.
      expect(isEnvelopeMessage('{"hello":"world"}'), isFalse);
    });

    test('media is deliberately not an envelope here', () {
      // Media has its own action rules — a caption is prose someone wrote.
      expect(
        isEnvelopeMessage(
          '{"_chattr_media":1,"media_type":"image","name":"a.png",'
          '"mime":"image/png","size":1,"path":"p","key":"k"}',
        ),
        isFalse,
      );
    });
  });
}
