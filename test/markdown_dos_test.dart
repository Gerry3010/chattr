// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// #95 hardening: a crafted deeply-nested markdown message (e.g. thousands of
// "> ") must never crash or freeze the renderer.
//
// The original guard was a 2000-character length cap, and it measured the wrong
// thing in both directions (found 2026-08-12, when a long agent write-up lost
// its formatting): ordinary prose was refused for being wordy, while a short
// wall of ">>>>…" — exactly what the cap was written for — went straight
// through. The rule now asks how DEEP and how DENSE a message is; length is
// only a ceiling on plain parse cost.
//
//   flutter test test/markdown_dos_test.dart

import 'package:chattr/features/messages/message_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the guard measures the hazard, not the word count', () {
    test('deep nesting is refused however short it is', () {
      // The case the length cap used to miss entirely: well under any length
      // limit, and the only input here that can actually blow the stack.
      final shallow = '${'> ' * (kMaxMarkdownDepth + 40)}x';
      expect(shallow.length, lessThan(2000));
      expect(hasMarkdown(shallow), isFalse);
      expect(parseMarkdownNodes(shallow), isEmpty);
    });

    test('a wall of markers is refused', () {
      final dense = '*_~`[]' * 200; // 1200 chars, all control characters
      expect(hasMarkdown(dense), isFalse);
      expect(parseMarkdownNodes(dense), isEmpty);
    });

    test('a long, ordinary, formatted message keeps its formatting', () {
      // The regression that started this: an agent's write-up — bold, headings,
      // lists, code, a table — a few thousand characters long. Nothing about it
      // is dangerous, and it used to render as a wall of raw asterisks.
      final buffer = StringBuffer('## Bericht\n\n');
      for (var i = 0; i < 60; i++) {
        buffer.writeln('- **Punkt $i** — eine ganz gewöhnliche Zeile mit '
            '`code`, einem [Link](https://example.org) und *Betonung*.');
      }
      final long = buffer.toString();
      expect(long.length, greaterThan(2000),
          reason: 'must exceed the old cap to prove the point');
      expect(long.length, lessThan(kMaxMarkdownChars));
      expect(hasMarkdown(long), isTrue);
    });

    test('normal quoting and nesting still works', () {
      expect(hasMarkdown('> a quote'), isTrue);
      expect(hasMarkdown('> > nested twice'), isTrue);
      expect(hasMarkdown('${'> ' * kMaxMarkdownDepth}still fine'), isTrue);
    });

    test('short heavily-marked text is not mistaken for an attack', () {
      // '**hi**' is 6 of 6 marker characters; the density rule must not fire
      // below the minimum length or it would reject the commonest markdown
      // there is.
      expect(hasMarkdown('**hi**'), isTrue);
      expect(hasMarkdown('~~weg~~'), isTrue);
      expect(hasMarkdown('`x`'), isTrue);
    });
  });

  group('the outer ceiling still holds', () {
    test('an absurdly long message is never parsed', () {
      final huge = '${'> ' * 20000}x';
      expect(huge.length > kMaxMarkdownChars, isTrue);
      expect(hasMarkdown(huge), isFalse);
      expect(parseMarkdownNodes(huge), isEmpty);
    });

    test('long plain text stays plain, no parse', () {
      expect(hasMarkdown('a' * (kMaxMarkdownChars + 500)), isFalse);
    });

    test('anything that slips through still cannot throw', () {
      // The parser stays wrapped: the structural rules are a filter, not a
      // proof, and a throw must never reach the widget tree.
      expect(() => parseMarkdownNodes('${'> ' * 900}x'), returnsNormally);
      expect(() => hasMarkdown('${'*' * 5000}x'), returnsNormally);
    });
  });

  test('normal short markdown is still detected', () {
    expect(hasMarkdown('**bold** and *italic*'), isTrue);
    expect(hasMarkdown('- one\n- two'), isTrue);
    expect(hasMarkdown('> a quote'), isTrue);
    expect(hasMarkdown('just plain words here'), isFalse);
  });
}
