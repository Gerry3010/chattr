// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-35 (C2): the preview parser and the e-mail pattern backtracked on
// input built for it — 7.5 s for a 64 KiB page, 4.5 s for one message, both on
// the UI isolate. The page and the message belong to someone else.

import 'package:chattr/features/messages/link_preview_parser.dart';
import 'package:chattr/features/messages/message_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('liest og:title und og:image, beide Attribut-Reihenfolgen', () {
    final r = parseLinkPreviewHtml((
      '<html><head>'
          '<meta content="Ein &amp; Titel" property="og:title">'
          '<meta property="og:image" content="/bild.jpg">'
          '</head></html>',
      'https://example.org/seite',
    ));
    expect(r.title, 'Ein & Titel');
    expect(r.image, 'https://example.org/bild.jpg');
  });

  test('ohne og: der <title>, ohne alles: nichts', () {
    expect(
      parseLinkPreviewHtml(('<title> Hallo </title>', 'https://x.at')).title,
      'Hallo',
    );
    final empty = parseLinkPreviewHtml(('<p>nichts</p>', 'https://x.at'));
    expect(empty.title, isNull);
    expect(empty.image, isNull);
  });

  test('eine Seite, gebaut zum Hängen, ist schnell durch', () {
    // A meta tag that never closes, then 200 000 more characters.
    final evil = '<meta property="og:title" content="x${'a' * 200000}';
    final watch = Stopwatch()..start();
    parseLinkPreviewHtml((evil * 2, 'https://x.at'));
    expect(watch.elapsedMilliseconds, lessThan(500));
  });

  test('E-Mail-Muster: lange Läufe ohne @ hängen nicht mehr', () {
    final evil = '${'a.' * 50000}x';
    final watch = Stopwatch()..start();
    expect(extractEmails(evil), isEmpty);
    expect(watch.elapsedMilliseconds, lessThan(500));
  });

  test('E-Mail-Muster findet normale Adressen weiter', () {
    expect(extractEmails('schreib an info@chattr.at, danke'),
        ['info@chattr.at']);
    expect(extractEmails('@gerry ist keine Adresse'), isEmpty);
  });
}
