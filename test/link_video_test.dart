// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/messages/message_links.dart';

void main() {
  group('youtubeVideoId', () {
    test('parses the common URL shapes', () {
      const id = 'dQw4w9WgXcQ';
      final urls = [
        'https://www.youtube.com/watch?v=$id',
        'https://youtube.com/watch?v=$id&t=42s',
        'https://m.youtube.com/watch?v=$id',
        'https://youtu.be/$id',
        'https://youtu.be/$id?si=share',
        'https://www.youtube.com/shorts/$id',
        'https://www.youtube.com/embed/$id',
        'https://www.youtube.com/live/$id',
      ];
      for (final url in urls) {
        expect(youtubeVideoId(Uri.parse(url)), id, reason: url);
      }
    });

    test('rejects non-video and non-YouTube URLs', () {
      final urls = [
        'https://www.youtube.com/',
        'https://www.youtube.com/@channel',
        'https://www.youtube.com/watch',
        'https://www.youtube.com/playlist?list=PL123456789',
        'https://notyoutube.com/watch?v=dQw4w9WgXcQ',
        'https://example.com/youtu.be/dQw4w9WgXcQ',
      ];
      for (final url in urls) {
        expect(youtubeVideoId(Uri.parse(url)), isNull, reason: url);
      }
    });
  });

  group('isYoutubeShorts', () {
    test('only shorts URLs are vertical', () {
      expect(
        isYoutubeShorts(Uri.parse('https://www.youtube.com/shorts/abc123XYZ_-')),
        isTrue,
      );
      expect(
        isYoutubeShorts(Uri.parse('https://youtube.com/shorts/abc123XYZ_-')),
        isTrue,
      );
      expect(
        isYoutubeShorts(
            Uri.parse('https://www.youtube.com/watch?v=abc123XYZ_-')),
        isFalse,
      );
      expect(isYoutubeShorts(Uri.parse('https://youtu.be/abc123XYZ_-')),
          isFalse);
      expect(isYoutubeShorts(Uri.parse('https://www.youtube.com/shorts/')),
          isFalse);
    });
  });

  group('isRedditUrl', () {
    test('matches reddit hosts and only those', () {
      final reddit = [
        'https://www.reddit.com/r/flutter/comments/abc123/title/',
        'https://reddit.com/r/flutter/s/XyZ123',
        'https://old.reddit.com/r/flutter/comments/abc123/',
        'https://redd.it/abc123',
        'https://v.redd.it/abcdef123456',
      ];
      for (final url in reddit) {
        expect(isRedditUrl(Uri.parse(url)), isTrue, reason: url);
      }
      final other = [
        'https://example.com/reddit.com/x',
        'https://notreddit.com/r/x',
        'https://fake-reddit.com/',
      ];
      for (final url in other) {
        expect(isRedditUrl(Uri.parse(url)), isFalse, reason: url);
      }
    });
  });

  group('redditHlsFromDirectLink', () {
    test('derives the HLS playlist from v.redd.it links', () {
      expect(
        redditHlsFromDirectLink(Uri.parse('https://v.redd.it/abcdef123456')),
        'https://v.redd.it/abcdef123456/HLSPlaylist.m3u8',
      );
    });

    test('null for post links and malformed ids', () {
      expect(
        redditHlsFromDirectLink(
            Uri.parse('https://www.reddit.com/r/x/comments/abc123/')),
        isNull,
      );
      expect(redditHlsFromDirectLink(Uri.parse('https://v.redd.it/')), isNull);
      expect(
        redditHlsFromDirectLink(Uri.parse('https://v.redd.it/UPPER%20case')),
        isNull,
      );
    });
  });
}
