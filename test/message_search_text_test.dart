// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Reported by Gerry (2026-09-02): in the in-chat search, raw JSON envelopes
// stood for media and shots. Two faults in one — the row was unreadable, AND
// the hit often was not one at all: "jpg", "items" or "http" stand in every
// media envelope.
//
// The rule: a medium is findable only through its caption, and only the caption
// is displayed. A shot never has text.

import 'package:chattr/features/media/media_attachment.dart';
import 'package:chattr/features/media/shot_envelope.dart';
import 'package:chattr/features/messages/message_search_text.dart';
import 'package:flutter_test/flutter_test.dart';

MediaAttachment _image({String name = 'urlaub.jpg'}) => MediaAttachment(
      mediaType: MediaType.image,
      name: name,
      mime: 'image/jpeg',
      size: 1234,
      path: 'chat/msg/urlaub.enc',
      keyB64: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    );

void main() {
  group('durchsuchbarerText', () {
    test('ordinary text stays as it is', () {
      expect(searchableText('Treffen wir uns um acht?'),
          'Treffen wir uns um acht?');
    });

    test('empty and null have no text', () {
      expect(searchableText(null), isNull);
      expect(searchableText('   '), isNull);
    });

    test('a medium WITHOUT a caption has no text', () {
      final album = MediaAlbum(items: [_image()]).encode();
      expect(searchableText(album), isNull);
    });

    test('a medium WITH a caption yields exactly that', () {
      final album =
          MediaAlbum(items: [_image()], caption: 'Sonnenuntergang am See')
              .encode();
      expect(searchableText(album), 'Sonnenuntergang am See');
    });

    test('a shot never has text', () {
      expect(searchableText(ShotEnvelope.of(_image()).encode()), isNull);
    });
  });

  group('trifftSuche', () {
    test('finds the caption', () {
      final album =
          MediaAlbum(items: [_image()], caption: 'Sonnenuntergang').encode();
      expect(matchesSearch(album, 'sonnen'), isTrue);
      expect(matchesSearch(album, 'SONNEN'.toLowerCase()), isTrue);
    });

    test('does NOT find the envelope around it', () {
      // That was the actual fault: these words stand in EVERY media envelope,
      // so the search found pictures indiscriminately.
      final album =
          MediaAlbum(items: [_image()], caption: 'Sonnenuntergang').encode();
      for (final word in ['jpg', 'items', 'image', 'urlaub', 'enc']) {
        expect(matchesSearch(album, word), isFalse, reason: 'traf auf "$word"');
      }
    });

    test('a shot is matched by nothing', () {
      final shot = ShotEnvelope.of(_image()).encode();
      // Not via path or key either — those are precisely what stands in the
      // envelope.
      for (final word in ['shot', 'urlaub', 'enc', 'chat', 'aaaa']) {
        expect(matchesSearch(shot, word), isFalse, reason: 'traf auf "$word"');
      }
    });

    test('ordinary text is still found', () {
      expect(matchesSearch('Treffen wir uns um acht?', 'acht'), isTrue);
      expect(matchesSearch('Treffen wir uns um acht?', 'neun'), isFalse);
    });
  });
}
