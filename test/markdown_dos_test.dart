// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// #95 hardening: a crafted deeply-nested markdown message (e.g. thousands of
// "> ") must never crash or freeze the renderer. The length cap keeps over-long
// input off the markdown path; the parser is defensive against any throw.

import 'package:chattr/features/messages/message_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('over-length nested-blockquote message is NOT treated as markdown', () {
    final huge = '${'> ' * 8000}x'; // ~16 KB, ~8000 nesting levels
    expect(huge.length > kMaxMarkdownChars, isTrue);
    expect(hasMarkdown(huge), isFalse); // no parse → renders as plain text
    expect(parseMarkdownNodes(huge), isEmpty); // defensive, never throws
  });

  test('deeply nested input UNDER the cap parses without crashing', () {
    final nested = '${'> ' * 900}x'; // 1800 chars < cap, 900 levels
    expect(() => parseMarkdownNodes(nested), returnsNormally);
    expect(() => hasMarkdown(nested), returnsNormally);
  });

  test('long plain text (no formatting) stays plain, no parse', () {
    final longPlain = 'a' * (kMaxMarkdownChars + 500);
    expect(hasMarkdown(longPlain), isFalse);
  });

  test('normal short markdown is still detected', () {
    expect(hasMarkdown('**bold** and *italic*'), isTrue);
    expect(hasMarkdown('- one\n- two'), isTrue);
    expect(hasMarkdown('> a quote'), isTrue);
    expect(hasMarkdown('just plain words here'), isFalse);
  });
}
