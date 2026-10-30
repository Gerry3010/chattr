// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// Editing a photo's caption changes exactly the caption — path, key and any
// field this build does not know stay as they were (SeB, 2026-10-03).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/media_attachment.dart';

void main() {
  final body = jsonEncode({
    MediaAttachment.marker: 1,
    'path': 'chat/msg/media-0.enc',
    'key': 'K3Y=',
    'mime': 'image/jpeg',
    'caption': 'alt',
    'zukunft': {'von': 'einer neueren App'},
  });

  test('ersetzt nur die Bildunterschrift', () {
    final out = jsonDecode(replaceCaption(body, '  neu  ')!) as Map;
    expect(out['caption'], 'neu');
    expect(out['path'], 'chat/msg/media-0.enc');
    expect(out['key'], 'K3Y=');
    expect(out['zukunft'], {'von': 'einer neueren App'});
  });

  test('leer entfernt die Bildunterschrift, das Bild bleibt', () {
    final out = replaceCaption(body, '   ')!;
    expect(MediaAlbum.tryParse(out)!.caption, isNull);
    expect(MediaAlbum.tryParse(out)!.first.path, 'chat/msg/media-0.enc');
  });

  test('ein Bild ohne Text bekommt eine', () {
    final plain = jsonEncode({
      MediaAttachment.marker: 1,
      'path': 'p',
      'key': 'k',
      'mime': 'image/png',
    });
    expect(MediaAlbum.tryParse(replaceCaption(plain, 'Hallo')!)!.caption,
        'Hallo');
  });

  test('kein Medien-Umschlag: nichts zu ersetzen', () {
    expect(replaceCaption('einfach Text', 'x'), isNull);
  });
}
