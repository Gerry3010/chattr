// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// A message the markdown parser refuses to parse must still be READABLE.
//
// The refusal rule itself moved on 2026-08-12 (it now measures nesting depth
// and marker density instead of length, so ordinary long prose keeps its
// formatting) — but everything below is about what happens AFTER a refusal,
// which is unchanged. The inputs here are simply built to be genuinely refused
// under the current rule rather than merely long.
//
// Found in the wild 2026-08-05: agent messages over kMaxMarkdownChars arrived
// on Gerry's iPhone as EMPTY bubbles. The parse cap worked as designed
// (hasMarkdown → false), but the bubble was chosen by a different predicate —
// the message @-mentioned a member, which routes to MarkdownMessageBubble
// regardless of length. There SafeMarkdown parsed to zero nodes and rendered
// Column(children: []) — a bubble with nothing in it.
//
// The same hole swallows a crafted deeply-nested message, where
// parseMarkdownNodes catches the parser error and also returns []. So the
// hardening that stops a peer from freezing the app made them able to blank a
// message instead. Both cases must degrade to plain text, never to nothing.

import 'package:chattr/features/messages/message_markdown.dart';
import 'package:chattr/screens/chat/components/safe_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, String data,
    {Set<String> mentions = const {}}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SafeMarkdown(
          data: data,
          textColor: const Color(0xFF000000),
          linkColor: const Color(0xFF0000FF),
          mentionUsernames: mentions,
        ),
      ),
    ),
  );
}

void main() {
  group('SafeMarkdown with unparseable input', () {
    testWidgets('an over-long message still renders its text', (tester) async {
      // Shaped like the real one: a mention (which is what routed it here),
      // markdown that will never be parsed, and length past the cap.
      // Shaped like the real one, but nested past the depth limit so the
      // parser genuinely declines it.
      final data = '${'> ' * (kMaxMarkdownDepth + 5)}'
          '@Gerry **Android-Seite steht** — Branch `feat/x`. ENDE-MARKER';
      expect(parseMarkdownNodes(data), isEmpty); // parser declines, by design

      await _pump(tester, data, mentions: {'Gerry'});

      expect(find.textContaining('Android-Seite steht'), findsOneWidget);
      expect(find.textContaining('ENDE-MARKER'), findsOneWidget);
    });

    testWidgets('a pathologically nested message still renders its text',
        (tester) async {
      final data = '${'> ' * 8000}VERSTECKT';
      expect(parseMarkdownNodes(data), isEmpty);

      await _pump(tester, data);

      expect(find.textContaining('VERSTECKT'), findsOneWidget);
    });

    testWidgets('the fallback still highlights mentions and keeps links',
        (tester) async {
      final data = '${'> ' * (kMaxMarkdownDepth + 5)}'
          '@Gerry schau https://chattr.at an.';
      expect(parseMarkdownNodes(data), isEmpty);

      await _pump(tester, data, mentions: {'Gerry'});

      expect(find.textContaining('@Gerry'), findsOneWidget);
      expect(find.textContaining('chattr.at'), findsOneWidget);
    });

    testWidgets('empty input stays empty — no stray blank line',
        (tester) async {
      await _pump(tester, '');
      expect(find.byType(Text), findsNothing);
      expect(find.byType(RichText), findsNothing);
    });
  });

  group('SafeMarkdown regression guard', () {
    testWidgets('short markdown is still parsed, not dumped as plain text',
        (tester) async {
      await _pump(tester, '**fett** und `code`');
      // The asterisks must be consumed by the parser, not printed.
      expect(find.textContaining('**fett**'), findsNothing);
      expect(find.textContaining('fett'), findsOneWidget);
    });
  });
}
