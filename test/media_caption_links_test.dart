// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// 2026-10-23: a link in a photo caption showed as plain text. A bare URL is
// not markdown, and only markdown captions were linked.

import 'package:chattr/features/media/widgets/media_caption_text.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<TextSpan> _spans(WidgetTester tester) {
  final out = <TextSpan>[];
  void collect(InlineSpan s) {
    if (s is! TextSpan) return;
    if (s.text != null) out.add(s);
    for (final c in s.children ?? const <InlineSpan>[]) {
      collect(c);
    }
  }

  for (final t in tester.widgetList<RichText>(find.byType(RichText))) {
    collect(t.text);
  }
  return out;
}

Future<void> _show(WidgetTester tester, String caption,
    {Set<String> mentions = const {}}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaCaptionText(
          caption: caption,
          isOwn: false,
          mentionUsernames: mentions,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('ein Link in der Bildunterschrift ist antippbar', (tester) async {
    await _show(tester, 'Schau mal https://chattr.at/blog an');
    final link = _spans(tester).where((s) => s.text!.contains('chattr.at'));
    expect(link, isNotEmpty);
    expect(link.first.recognizer, isA<TapGestureRecognizer>());
  });

  testWidgets('eine E-Mail-Adresse ebenso', (tester) async {
    await _show(tester, 'Schreib an info@chattr.at');
    final mail = _spans(tester).where((s) => s.text!.contains('info@chattr.at'));
    expect(mail, isNotEmpty);
    expect(mail.first.recognizer, isA<TapGestureRecognizer>());
  });

  testWidgets('Link und Erwähnung in einer Unterschrift', (tester) async {
    await _show(tester, '@bob schau https://chattr.at', mentions: {'bob'});
    final spans = _spans(tester);
    expect(spans.any((s) => s.recognizer is TapGestureRecognizer), isTrue);
    expect(spans.any((s) => s.text == '@bob'), isTrue);
  });

  testWidgets('ohne Link bleibt sie markierbar wie bisher', (tester) async {
    await _show(tester, 'schöner Sonnenuntergang');
    expect(find.byType(SelectableText), findsOneWidget);
  });
}
