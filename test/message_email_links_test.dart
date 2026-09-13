// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/messages/message_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeUrl', () {
    test('mailto stays mailto — and does not become a foreign site', () {
      // The actual fault: this used to become `https://mailto:sebi@example.at`,
      // which Dart reads as host `example.at`. The link looked right and opened
      // the browser.
      final uri = normalizeUrl('mailto:sebi@example.at');
      expect(uri?.scheme, 'mailto');
      expect(uri?.path, 'sebi@example.at');
    });

    test('a bare address becomes mailto', () {
      expect(normalizeUrl('sebi@example.at').toString(),
          'mailto:sebi@example.at');
    });

    test('tel passes through', () {
      expect(normalizeUrl('tel:+43123').toString(), 'tel:+43123');
    });

    test('www bekommt weiterhin https', () {
      expect(normalizeUrl('www.x.dev').toString(), 'https://www.x.dev');
    });

    test('a foreign scheme is not offered', () {
      // Allowlist: what is not http/https/mailto/tel stays text.
      expect(normalizeUrl('javascript:alert(1)'), isNull);
      expect(normalizeUrl('intent://x'), isNull);
      expect(normalizeUrl('file:///etc/passwd'), isNull);
    });

    test('an empty target is no target', () {
      expect(normalizeUrl('mailto:'), isNull);
      expect(normalizeUrl('   '), isNull);
    });
  });

  group('extractEmails', () {
    test('finds the address in running text', () {
      expect(extractEmails('schreib an sebi@example.at bitte'),
          ['sebi@example.at']);
    });

    test('the @ of a mention is not an address', () {
      expect(extractEmails('hallo @gerry, schau mal'), isEmpty);
    });

    test('what sits inside a URL is not an address', () {
      // `https://user@host/x` carries an @ of its own — it belongs to the link.
      expect(extractEmails('siehe https://user@host.dev/x'), isEmpty);
    });

    test('without an ending, no address', () {
      expect(extractEmails('preis@stueck'), isEmpty);
    });
  });

  group('linkTokenPattern', () {
    test('URL and address side by side, each one whole', () {
      final hits = linkTokenPattern
          .allMatches('mail sebi@example.at und https://user@host.dev/x jetzt')
          .map((m) => m.group(0))
          .toList();
      expect(hits, ['sebi@example.at', 'https://user@host.dev/x']);
    });

    test('the URL beats the address inside it', () {
      // If the mail form stood first, it would rip `user@host.dev` out and half
      // a link would be left behind.
      final hits = linkTokenPattern
          .allMatches('https://user@host.dev/x')
          .map((m) => m.group(0))
          .toList();
      expect(hits, ['https://user@host.dev/x']);
    });
  });
}
