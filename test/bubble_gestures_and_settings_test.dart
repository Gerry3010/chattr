// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-15: double tap did nothing (the package flag was off), and the reaction
// pill could only remove. Now: media → reaction (❤️ unless changed), text →
// copy mode, pill in a group with one kind → join in.
// CHAT-38: Recents for CallKit become a setting, and the push name table goes
// with the account.

import 'package:chattr/features/calls/call_system_ui.dart';
import 'package:chattr/features/calls/calls_in_recents_setting.dart';
import 'package:chattr/features/chat_view/bubble_gestures.dart';
import 'package:chattr/features/push_notifications/push_render_cache.dart';
import 'package:chattr/features/reactions/double_tap_reaction_setting.dart';
import 'package:chattr/screens/chat/components/text_selection_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

DoubleTapAction _action({
  bool isSystem = false,
  bool canInteract = true,
  bool isMedia = false,
  bool isText = true,
  bool isDecrypted = true,
  bool isEnvelope = false,
}) =>
    doubleTapActionFor(
      isSystem: isSystem,
      canInteract: canInteract,
      isMedia: isMedia,
      isText: isText,
      isDecrypted: isDecrypted,
      isEnvelope: isEnvelope,
    );

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Doppeltippen', () {
    test('Foto oder Video: Reaktion', () {
      expect(_action(isMedia: true, isText: false), DoubleTapAction.react);
    });
    test('Text: Kopiermodus', () {
      expect(_action(), DoubleTapAction.copyMode);
    });
    test('nichts bei Hinweisen, Karten, Unlesbarem und ohne Mitgliedschaft',
        () {
      expect(_action(isSystem: true), DoubleTapAction.none);
      expect(_action(isEnvelope: true), DoubleTapAction.none);
      expect(_action(isDecrypted: false), DoubleTapAction.none);
      expect(_action(canInteract: false, isMedia: true), DoubleTapAction.none);
    });
  });

  group('Reaktions-Pille', () {
    test('Gruppe mit einer Sorte: mitreagieren', () {
      expect(
          pillTapJoins(isGroup: true, reactionKinds: 1, canInteract: true),
          isTrue);
    });
    test('mehrere Sorten, 1:1 oder ohne Mitgliedschaft: Liste', () {
      expect(
          pillTapJoins(isGroup: true, reactionKinds: 2, canInteract: true),
          isFalse);
      expect(
          pillTapJoins(isGroup: false, reactionKinds: 1, canInteract: true),
          isFalse);
      expect(
          pillTapJoins(isGroup: true, reactionKinds: 1, canInteract: false),
          isFalse);
    });
  });

  group('Einstellungen', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('Doppeltipp-Reaktion: ❤️, änderbar, bleibt gespeichert', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(doubleTapReactionProvider), '❤️');
      await c.read(doubleTapReactionProvider.notifier).set('🔥');
      expect(c.read(doubleTapReactionProvider), '🔥');

      final again = ProviderContainer();
      addTearDown(again.dispose);
      again.read(doubleTapReactionProvider);
      await _settle();
      expect(again.read(doubleTapReactionProvider), '🔥');
    });

    test('Anrufliste: standardmäßig an, abschaltbar, landet in CallKit',
        () async {
      expect(await CallsInRecentsController.read(), isTrue);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(callsInRecentsProvider.notifier).setEnabled(false);
      expect(await CallsInRecentsController.read(), isFalse);

      final params = incomingCallParams(
        signalId: 's',
        chatId: 'c',
        listInRecents: false,
      );
      expect(params.ios?.includesCallsInRecents, isFalse);
      expect(
        incomingCallParams(signalId: 's', chatId: 'c').ios
            ?.includesCallsInRecents,
        isTrue,
      );
    });

    test('Abmelden räumt die Push-Namenstabelle weg', () async {
      await PushRenderCache.putNames({'chat-1': 'Alice'});
      expect((await PushRenderCache.read()).names, {'chat-1': 'Alice'});
      await PushRenderCache.clear();
      expect((await PushRenderCache.read()).names, isEmpty);
    });
  });

  testWidgets('Kopiermodus: Text markierbar, „Alles kopieren“ kopiert',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showTextSelectionSheet(context, 'Treffen um 18 Uhr'),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('text_selection_sheet_text')),
        findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(
              find.byKey(const ValueKey('text_selection_sheet_text')))
          .data,
      'Treffen um 18 Uhr',
    );

    await tester.tap(find.byKey(const ValueKey('text_selection_copy_all')));
    await tester.pumpAndSettle();
    expect(copied, 'Treffen um 18 Uhr');
    expect(find.byKey(const ValueKey('text_selection_sheet_text')),
        findsNothing);
  });
}
