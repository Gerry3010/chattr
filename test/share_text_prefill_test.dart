// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/share_target/share_text_edit_sheet.dart';

void main() {
  group('shared-link prefill', () {
    test('a bare link opens with room above it and the caret at the top', () {
      final v = shareEditInitialValue('https://example.com/artikel');
      expect(v.text, '\n\nhttps://example.com/artikel');
      expect(v.selection.baseOffset, 0,
          reason: 'sonst muss man den Cursor erst am Link vorbeimanövrieren');
    });

    test('untouched, it still sends as the plain URL (send trims)', () {
      final v = shareEditInitialValue('https://example.com');
      expect(v.text.trim(), 'https://example.com');
    });

    test('shared prose is left exactly as it came, caret at the end', () {
      const prose = 'Schau dir das an, ziemlich gut';
      final v = shareEditInitialValue(prose);
      expect(v.text, prose);
      expect(v.selection.baseOffset, prose.length);
    });

    test('text that merely contains a link is prose, not a bare link', () {
      const mixed = 'lies das https://example.com';
      expect(shareEditInitialValue(mixed).text, mixed);
    });

    test('non-http schemes get no special treatment', () {
      for (final s in ['mailto:a@b.de', 'ftp://host/x', 'example.com']) {
        expect(shareEditInitialValue(s).text, s, reason: s);
      }
    });
  });
}
