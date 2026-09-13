// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Links pointing directly at a file. Reported on 2026-08-23: an .mp4 from our
// own CMS yielded nothing but the bare link — such addresses return no HTML,
// hence no og data for the preview to hang on.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/message_links.dart';

Uri _u(String s) => Uri.parse(s);

void main() {
  group('directMediaKind', () {
    test('Video-Endungen', () {
      expect(directMediaKind(_u('https://cms.example.at/v/clip.mp4')),
          LinkMediaKind.video);
      expect(directMediaKind(_u('https://x.dev/a.WEBM')), LinkMediaKind.video);
    });

    test('Bild-Endungen', () {
      expect(directMediaKind(_u('https://x.dev/foto.jpg')), LinkMediaKind.image);
      expect(directMediaKind(_u('https://x.dev/a/b/c.png')), LinkMediaKind.image);
    });

    test('Ton-Endungen', () {
      expect(directMediaKind(_u('https://x.dev/lied.mp3')), LinkMediaKind.audio);
    });

    test('ordinary pages: null', () {
      expect(directMediaKind(_u('https://example.com/artikel')), isNull);
      expect(directMediaKind(_u('https://example.com/')), isNull);
      expect(directMediaKind(_u('https://example.com/x.html')), isNull);
    });

    test('a query does not interfere — the kind is in the path', () {
      expect(directMediaKind(_u('https://x.dev/clip.mp4?token=abc&v=2')),
          LinkMediaKind.video);
    });

    test('a dot at the end without an extension: null rather than guesswork', () {
      expect(directMediaKind(_u('https://x.dev/datei.')), isNull);
    });
  });

  group('linkFileName', () {
    test('takes the last path segment', () {
      expect(linkFileName(_u('https://cms.example.at/v/mein%20clip.mp4')),
          'mein clip.mp4');
    });

    test('without a path: null', () {
      expect(linkFileName(_u('https://example.com')), isNull);
    });
  });
}
