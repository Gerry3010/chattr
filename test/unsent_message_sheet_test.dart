// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/messages/outgoing_message.dart';
import 'package:chattr/screens/chat/components/unsent_message_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> calls;

  setUp(() => calls = []);

  Widget host({SendFailure? failure, bool sending = false}) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                UnsentReceipt(onTap: () => calls.add('tap')),
                TextButton(
                  onPressed: () => showUnsentMessageSheet(
                    context,
                    failure: failure,
                    sending: sending,
                    onRetry: () => calls.add('retry'),
                    onDiscard: () => calls.add('discard'),
                    onCopy: () => calls.add('copy'),
                  ),
                  child: const Text('open'),
                ),
              ],
            ),
          ),
        ),
      );

  group('Nicht gesendet (CHAT-66)', () {
    testWidgets('rotes Zeichen ist antippbar', (tester) async {
      await tester.pumpWidget(host());
      expect(find.byIcon(Icons.error), findsOneWidget);
      await tester.tap(find.byIcon(Icons.error));
      expect(calls, ['tap']);
    });

    testWidgets('kein Netz: Grund, Erneut senden, Verwerfen', (tester) async {
      await tester.pumpWidget(host(failure: SendFailure.network));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('chat_view.unsent.title'), findsOneWidget);
      expect(find.text('chat_view.unsent.network'), findsOneWidget);

      await tester.tap(find.text('chat_view.unsent.retry'));
      await tester.pumpAndSettle();
      expect(calls, ['retry']);
      expect(find.text('chat_view.unsent.title'), findsNothing,
          reason: 'das Blatt schließt sich vor der Aktion');
    });

    testWidgets('abgelehnt: eigener Text, Verwerfen geht', (tester) async {
      await tester.pumpWidget(host(failure: SendFailure.rejected));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('chat_view.unsent.rejected'), findsOneWidget);
      await tester.tap(find.text('chat_view.unsent.discard'));
      await tester.pumpAndSettle();
      expect(calls, ['discard']);
    });

    testWidgets('noch unterwegs: nur Kopieren, kein Erneut senden',
        (tester) async {
      await tester.pumpWidget(host(sending: true));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('chat_view.unsent.sending'), findsOneWidget);
      expect(find.text('chat_view.unsent.retry'), findsNothing);
      expect(find.text('chat_view.unsent.discard'), findsNothing);
      await tester.tap(find.text('chat_view.copy'));
      await tester.pumpAndSettle();
      expect(calls, ['copy']);
    });
  });
}
