// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The timestamp in YouTube links. It was NEVER read until 2026-08-23: whoever
// shared "from minute 3" gave the other party the beginning. `startSeconds` did
// exist in the player, but only for resuming from the PiP window.

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/message_links.dart';

Uri _u(String s) => Uri.parse(s);

void main() {
  group('youtubeStartSeconds', () {
    test('bare seconds (the youtu.be share form)', () {
      expect(youtubeStartSeconds(_u('https://youtu.be/dQw4w9WgXcQ?t=90')), 90);
    });

    test('seconds with an s', () {
      expect(
        youtubeStartSeconds(_u('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90s')),
        90,
      );
    });

    test('compound m/s and h/m/s', () {
      expect(
        youtubeStartSeconds(_u('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s')),
        90,
      );
      expect(
        youtubeStartSeconds(_u('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1h2m3s')),
        3723,
      );
    });

    test('start= (the embedding parameter)', () {
      expect(
        youtubeStartSeconds(_u('https://www.youtube.com/embed/dQw4w9WgXcQ?start=42')),
        42,
      );
    });

    test('the old form in the fragment', () {
      expect(
        youtubeStartSeconds(_u('https://www.youtube.com/watch?v=dQw4w9WgXcQ#t=1m30s')),
        90,
      );
    });

    test('HH:MM:SS and MM:SS are read, although YouTube does not produce them',
        () {
      expect(parseTimeToken('1:30'), 90);
      expect(parseTimeToken('1:02:03'), 3723);
    });

    test('without a timestamp: null, not 0', () {
      expect(youtubeStartSeconds(_u('https://youtu.be/dQw4w9WgXcQ')), isNull);
    });

    test('t=0 is like no timestamp', () {
      expect(youtubeStartSeconds(_u('https://youtu.be/dQw4w9WgXcQ?t=0')), isNull);
    });

    test('not a YouTube link: null, even with t=', () {
      expect(youtubeStartSeconds(_u('https://example.com/x?t=90')), isNull);
    });

    test('nonsense yields null, never a guessed number', () {
      expect(parseTimeToken('abc'), isNull);
      expect(parseTimeToken(''), isNull);
      expect(parseTimeToken(null), isNull);
      expect(parseTimeToken('1:2:3:4'), isNull);
      expect(parseTimeToken('1h2x'), isNull);
    });
  });
}
