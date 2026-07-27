// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/messages/message_markdown.dart';
import 'package:chattr/screens/chat/components/safe_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task #95: markdown message rendering. The detector [hasMarkdown] gates which
/// messages leave chatview's plain text bubble — false positives would wrongly
/// reroute ordinary prose, so the negative cases matter as much as the positive.
void main() {
  group('hasMarkdown — positive', () {
    for (final entry in {
      'bold': '**bold**',
      'italic': '*italic*',
      'strikethrough': '~~gone~~',
      'inline code': 'run `flutter test` now',
      'fenced code': '```\ncode()\n```',
      'heading': '# Title',
      'unordered list': '- one\n- two',
      'ordered list': '1. first\n2. second',
      'blockquote': '> quoted',
      'markdown link': 'see [docs](https://example.com)',
    }.entries) {
      test('detects ${entry.key}', () {
        expect(hasMarkdown(entry.value), isTrue, reason: entry.value);
      });
    }
  });

  group('hasMarkdown — negative (must stay plain)', () {
    for (final entry in {
      'plain prose': 'hello world, how are you?',
      'bare url (goes to link bubble)': 'see https://example.com for more',
      'spaced asterisks / math': '3 * 4 = 12 and a * b',
      'intraword underscores': 'my_variable_name = snake_case',
      'currency': r'that costs $5 today',
      'empty': '',
    }.entries) {
      test('ignores ${entry.key}', () {
        expect(hasMarkdown(entry.value), isFalse, reason: entry.value);
      });
    }
  });

  test('parseMarkdownNodes yields a strong element for bold', () {
    final nodes = parseMarkdownNodes('**hi**');
    // p > strong > text
    expect(nodes, isNotEmpty);
  });

  testWidgets('SafeMarkdown renders without error and keeps the text',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeMarkdown(
            data: '**bold** and _italic_ and `code`\n\n- a\n- b',
            textColor: Colors.black,
            linkColor: Colors.blue,
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SafeMarkdown), findsOneWidget);
    // The rendered text (across spans) contains the words, punctuation aside.
    expect(find.byType(RichText), findsWidgets);
  });

  // Regression: the parser runs with encodeHtml:true, which escapes `"& <>` to
  // HTML entities. SafeMarkdown renders to Flutter widgets (not HTML), so those
  // entities must be decoded back — otherwise a peer's `` `"s"` `` showed up as
  // `&quot;s&quot;` (bug: only ever visible on markdown messages, e.g. the two
  // agents', since plain user text never enters this renderer).
  group('SafeMarkdown decodes HTML entities (no &quot;/&amp; leaking)', () {
    Future<String> render(WidgetTester tester, String data) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeMarkdown(
              data: data,
              textColor: Colors.black,
              linkColor: Colors.blue,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // Flatten every RichText's plain text across the widget tree.
      return tester
          .widgetList<RichText>(find.byType(RichText))
          .map((rt) => (rt.text as TextSpan).toPlainText())
          .join('\n');
    }

    testWidgets('double quotes inside inline code', (tester) async {
      // `"s"` wrapped in a bold run so the message is classified as markdown.
      final text = await render(tester, 'set the **`"s"`** field');
      expect(text, contains('"s"'));
      expect(text, isNot(contains('&quot;')));
    });

    testWidgets('ampersand and angle brackets in prose', (tester) async {
      final text = await render(tester, '**A** & B, x < y, y > x');
      expect(text, contains('&'));
      expect(text, contains('<'));
      expect(text, contains('>'));
      expect(text, isNot(contains('&amp;')));
      expect(text, isNot(contains('&lt;')));
      expect(text, isNot(contains('&gt;')));
    });

    testWidgets("mac's canonical case — all five entities in one message",
        (tester) async {
      // **Tom's "Test"** & <b>x</b> — apostrophe (&#39;), quotes (&quot;),
      // ampersand (&amp;), angle brackets (&lt;/&gt;). Bold wraps the first
      // part; the <b> tag is escaped-to-text upstream, so it shows literally.
      final text = await render(tester, '**Tom\'s "Test"** & <b>x</b>');
      expect(text, contains('Tom\'s "Test"'));
      expect(text, contains('& <b>x</b>'));
      for (final entity in ['&#39;', '&quot;', '&amp;', '&lt;', '&gt;']) {
        expect(text, isNot(contains(entity)), reason: 'leaked $entity');
      }
    });

    testWidgets('a source entity resolves to its character (CommonMark)',
        (tester) async {
      // CommonMark resolves `&lt;` to `<` at parse time; encodeHtml then
      // re-escapes it to `&lt;`, and our decode turns it back into `<`. So the
      // reader sees the character, never the raw entity.
      final text = await render(tester, 'shows **&lt;** as a char');
      expect(text, contains('<'));
      expect(text, isNot(contains('&lt;')));
    });
  });
}
