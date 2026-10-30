// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// The highlight has to be actually drawn, too.
//
// The test next door (`self_mention_highlight_test.dart`) checks the pure
// logic: which section of text means me. That is the branch that is hard to get
// wrong anyway. This is about the one that can fail silently — whether the
// bubble passes the marking through and it arrives in the finished text tree.
// At exactly this spot something has slipped past me twice, because I checked
// the logic instead of the result.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/media/widgets/media_caption_text.dart';
import 'package:chattr/features/mentions/mention_spans.dart';
import 'package:chattr/screens/chat/components/safe_markdown.dart';

/// Alle Textabschnitte eines gerenderten [SafeMarkdown] flach ziehen.
List<TextSpan> _spansOf(WidgetTester tester) {
  final out = <TextSpan>[];
  void sammeln(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null) out.add(s);
      for (final k in s.children ?? const <InlineSpan>[]) {
        sammeln(k);
      }
    }
  }

  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    final span = t.textSpan;
    if (span != null) sammeln(span);
  }
  // Captions are selectable and therefore sit in SelectableText, not in Text —
  // otherwise this helper would simply find nothing there and the test would
  // pass without having checked anything.
  for (final t in tester.widgetList<SelectableText>(
    find.byType(SelectableText),
  )) {
    final span = t.textSpan;
    if (span != null) sammeln(span);
  }
  return out;
}

TextSpan _spanMit(List<TextSpan> spans, String text) =>
    spans.firstWhere((s) => s.text == text,
        orElse: () => throw StateError(
              'kein Abschnitt "$text" — vorhanden: '
              '${spans.map((s) => s.text).toList()}',
            ));

void main() {
  const mentionColor = Color(0xFF2196F3);
  final namen = {'bob', 'alice', 'all'};

  group('mentionSpans', () {
    test('my mention gets a ground, a foreign one does not', () {
      final spans = mentionSpans(
        '@alice @bob',
        const TextStyle(),
        usernames: namen,
        mentionColor: mentionColor,
        selfTokens: const {'bob'},
      ).cast<TextSpan>();

      expect(_spanMit(spans, '@bob').style?.backgroundColor, isNotNull);
      expect(_spanMit(spans, '@alice').style?.backgroundColor, isNull);
    });

    test('both stay in the accent colour and bold', () {
      // The reason is ADDED, it does not replace the existing styling —
      // otherwise a mention of somebody else would suddenly look different from
      // before.
      final spans = mentionSpans(
        '@alice @bob',
        const TextStyle(),
        usernames: namen,
        mentionColor: mentionColor,
        selfTokens: const {'bob'},
      ).cast<TextSpan>();

      for (final t in ['@bob', '@alice']) {
        expect(_spanMit(spans, t).style?.color, mentionColor);
        expect(_spanMit(spans, t).style?.fontWeight, FontWeight.w600);
      }
    });

    test('the ground is translucent, not opaque', () {
      // Opaque would be a second bubble inside the text; the bubble colour has
      // to come through for it to read as a marking.
      final spans = mentionSpans(
        '@bob',
        const TextStyle(),
        usernames: namen,
        mentionColor: mentionColor,
        selfTokens: const {'bob'},
      ).cast<TextSpan>();
      final ground = _spanMit(spans, '@bob').style!.backgroundColor!;
      expect(ground.a, greaterThan(0.0));
      expect(ground.a, lessThan(0.5));
    });

    test('without selfTokens no span has a ground', () {
      final spans = mentionSpans(
        '@alice @bob',
        const TextStyle(),
        usernames: namen,
        mentionColor: mentionColor,
      ).cast<TextSpan>();
      expect(spans.every((s) => s.style?.backgroundColor == null), isTrue);
    });

    test('ordinary text stays untouched', () {
      final spans = mentionSpans(
        'hallo bob',
        const TextStyle(),
        usernames: namen,
        mentionColor: mentionColor,
        selfTokens: const {'bob'},
      ).cast<TextSpan>();
      expect(spans.single.text, 'hallo bob');
      expect(spans.single.style?.backgroundColor, isNull);
    });
  });

  group('SafeMarkdown passes the marking through', () {
    Future<void> show(
      WidgetTester tester,
      String text, {
      Set<String> selfTokens = const {},
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SafeMarkdown(
              data: text,
              textColor: const Color(0xFF000000),
              linkColor: mentionColor,
              mentionUsernames: namen,
              selfMentionTokens: selfTokens,
            ),
          ),
        ),
      );
    }

    testWidgets('my mention in running text is highlighted',
        (tester) async {
      await show(tester, 'hey @bob und @alice', selfTokens: const {'bob'});
      final spans = _spansOf(tester);
      expect(_spanMit(spans, '@bob').style?.backgroundColor, isNotNull);
      expect(_spanMit(spans, '@alice').style?.backgroundColor, isNull);
    });

    testWidgets('inside bold type as well', (tester) async {
      // Markdown splits the text into blocks of its own; the mention must not
      // get lost in the process.
      await show(tester, '**dringend @bob**', selfTokens: const {'bob'});
      expect(
        _spanMit(_spansOf(tester), '@bob').style?.backgroundColor,
        isNotNull,
      );
    });

    testWidgets('without a marking (a message I wrote) everything stays plain',
        (tester) async {
      await show(tester, 'hey @bob und @alice');
      final spans = _spansOf(tester);
      expect(_spanMit(spans, '@bob').style?.backgroundColor, isNull);
      expect(_spanMit(spans, '@alice').style?.backgroundColor, isNull);
    });

    testWidgets('@all is highlighted when it means me', (tester) async {
      await show(tester, '@all bitte lesen', selfTokens: const {'all'});
      expect(
        _spanMit(_spansOf(tester), '@all').style?.backgroundColor,
        isNotNull,
      );
    });
  });

  group('captions count too', () {
    // The chat-list marker searches the decrypted message as a whole — envelope
    // included. A caption with "@bob" made the marker light up in the list
    // while there was nothing to be found in the chat: the caption was drawn
    // without any mention highlighting at all.
    Future<void> show(
      WidgetTester tester,
      String caption, {
      Set<String> selfTokens = const {},
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaCaptionText(
              caption: caption,
              isOwn: false,
              mentionUsernames: namen,
              selfMentionTokens: selfTokens,
            ),
          ),
        ),
      );
    }

    testWidgets('a plain caption: my mention is highlighted',
        (tester) async {
      await show(tester, 'schau @bob, und @alice', selfTokens: const {'bob'});
      final spans = _spansOf(tester);
      expect(_spanMit(spans, '@bob').style?.backgroundColor, isNotNull);
      expect(_spanMit(spans, '@alice').style?.backgroundColor, isNull);
    });

    testWidgets('formatierte Unterschrift ebenso', (tester) async {
      await show(tester, '**schau @bob**', selfTokens: const {'bob'});
      expect(
        _spanMit(_spansOf(tester), '@bob').style?.backgroundColor,
        isNotNull,
      );
    });

    testWidgets('it stays selectable', (tester) async {
      // The highlight is a styling on the spans, not a different widget —
      // selecting and copying text has to keep working.
      await show(tester, 'schau @bob', selfTokens: const {'bob'});
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('a caption without a mention stays as it was',
        (tester) async {
      await show(tester, 'schöner Sonnenuntergang');
      expect(find.text('schöner Sonnenuntergang'), findsOneWidget);
    });
  });
}
