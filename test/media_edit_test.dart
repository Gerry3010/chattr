// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Pre-send media-editing gate. The routing that decides WHICH editor applies to
// a media item (and on which platform) is extracted into the pure
// `mediaEditKind` so it can be verified without touching native trim code:
//   - images edit everywhere (pro_image_editor is pure-Flutter),
//   - video trimming is native → mobile only,
//   - audio and generic files have no editor.

import 'package:chattr/features/media/editing/media_edit_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mediaEditKind routing', () {
    test('images are editable on every platform', () {
      for (final mime in ['image/jpeg', 'image/png', 'image/webp', 'image/heic']) {
        expect(mediaEditKind(mime, isMobile: true), MediaEditKind.image);
        expect(mediaEditKind(mime, isMobile: false), MediaEditKind.image);
      }
    });

    test('video is editable on mobile only (native trim)', () {
      expect(mediaEditKind('video/mp4', isMobile: true), MediaEditKind.video);
      expect(mediaEditKind('video/quicktime', isMobile: true),
          MediaEditKind.video);
      // Desktop/web: no native trim → send unedited.
      expect(mediaEditKind('video/mp4', isMobile: false), MediaEditKind.none);
    });

    test('audio and generic files are never editable', () {
      for (final mime in [
        'audio/mpeg',
        'audio/mp4',
        'application/pdf',
        'application/octet-stream',
        'text/plain',
      ]) {
        expect(mediaEditKind(mime, isMobile: true), MediaEditKind.none);
        expect(mediaEditKind(mime, isMobile: false), MediaEditKind.none);
      }
    });

    test('unknown mime falls back to file → no editor', () {
      expect(mediaEditKind('', isMobile: true), MediaEditKind.none);
      expect(mediaEditKind('weird/thing', isMobile: true), MediaEditKind.none);
    });
  });
}
