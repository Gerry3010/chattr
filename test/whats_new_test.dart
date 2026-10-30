// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// "New in <version>" cards: which are unread, in which order, and how the
// buttons behave — Back is GONE on the first card, not disabled.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/features/whats_new/whats_new_catalog.dart';
import 'package:chattr/features/whats_new/whats_new_rules.dart';
import 'package:chattr/screens/whats_new/whats_new_dialog.dart';

void main() {
  group('Regeln', () {
    test('Versionen werden als Zahlen verglichen, nicht als Text', () {
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('1.32.0', '1.32.0+104'), 0);
      expect(compareVersions('1.32', '1.32.0'), 0);
    });

    test('ungelesen: nicht gesehen, nicht neuer als die App, älteste zuerst',
        () {
      final out = unreadWhatsNew(
        catalogVersions: ['1.40.0', '1.10.0', '1.9.0', '1.33.0'],
        seen: {'1.33.0'},
        installed: '1.35.2',
      );
      expect(out, ['1.9.0', '1.10.0']);
    });

    test('eine Karte kündigt nie an, was die App noch nicht hat', () {
      expect(
          unreadWhatsNew(
              catalogVersions: ['1.32.0'], seen: {}, installed: '1.31.0'),
          isEmpty);
    });

    test('der Titel lässt ein angehängtes .0 weg', () {
      expect(displayVersion('1.32.0'), '1.32');
      expect(displayVersion('1.32.1'), '1.32.1');
    });

    test('jeder Katalog-Eintrag hat einen Text in beiden Sprachen', () {
      // Guard against a card that would render its raw key.
      for (final e in whatsNewCatalog.values) {
        expect(e.headlineKey, startsWith('whats_new.entries.'));
        expect(e.bodyKey, startsWith('whats_new.entries.'));
      }
    });
  });

  group('Dialog', () {
    Future<void> pump(WidgetTester t, List<String> versions) =>
        t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) => Center(
                child: TextButton(
                  onPressed: () => showDialog<bool>(
                    context: c,
                    builder: (_) => WhatsNewDialog(versions: versions),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));

    Future<void> open(WidgetTester t) async {
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
    }

    const back = ValueKey('whats_new_back');
    const next = ValueKey('whats_new_next');
    const done = ValueKey('whats_new_done');

    testWidgets('eine Karte: kein Zurück, nur Gelesen', (t) async {
      await pump(t, ['1.32.0']);
      await open(t);
      expect(find.byKey(back), findsNothing);
      expect(find.byKey(next), findsNothing);
      expect(find.byKey(done), findsOneWidget);
      await t.tap(find.byKey(done));
      await t.pumpAndSettle();
      expect(find.byType(WhatsNewDialog), findsNothing);
    });

    testWidgets('mehrere Karten: Weiter, Zurück erst ab der zweiten',
        (t) async {
      await pump(t, ['1.32.0', '1.32.0']);
      await open(t);
      expect(find.byKey(back), findsNothing);
      expect(find.byKey(next), findsOneWidget);

      await t.tap(find.byKey(next));
      await t.pumpAndSettle();
      expect(find.byKey(back), findsOneWidget);
      expect(find.byKey(done), findsOneWidget);

      await t.tap(find.byKey(back));
      await t.pumpAndSettle();
      expect(find.byKey(back), findsNothing);
      expect(find.byKey(next), findsOneWidget);
    });
  });
}
