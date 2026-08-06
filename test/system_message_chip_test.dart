// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chattr/features/messages/message_model.dart';
import 'package:chattr/screens/chat/components/system_message_chip.dart';
import 'package:chatview/chatview.dart' as chatview;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The point of the four states is that they are TELLABLE APART while
/// scrolling. A mapping that compiles but paints every chip the same colour
/// would look correct in code review and be useless on screen, so the
/// distinctness is asserted rather than assumed.
void main() {
  Future<({Color background, IconData icon})> render(
    WidgetTester tester,
    SystemMessageState state, {
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: SystemMessageChip(text: 'Alice joined', state: state),
        ),
      ),
    );

    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(SystemMessageChip),
        matching: find.byType(Container),
      ),
    );
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byType(SystemMessageChip),
        matching: find.byType(Icon),
      ),
    );
    return (
      background: (container.decoration! as BoxDecoration).color!,
      icon: icon.icon!,
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets('every state gets its own colour and icon (${brightness.name})',
        (tester) async {
      final rendered = <SystemMessageState, ({Color background, IconData icon})>{};
      for (final state in SystemMessageState.values) {
        rendered[state] = await render(tester, state, brightness: brightness);
      }

      expect(
        rendered.values.map((r) => r.background).toSet(),
        hasLength(SystemMessageState.values.length),
        reason: 'two states share a background colour',
      );
      expect(
        rendered.values.map((r) => r.icon).toSet(),
        hasLength(SystemMessageState.values.length),
        reason: 'two states share an icon',
      );
    });

    testWidgets('the chip is opaque in ${brightness.name} mode',
        (tester) async {
      // The tint is blended ONTO the surface, not laid over it: the chat
      // wallpaper behind a system message is unknown, and a translucent pill
      // over a photo is unreadable.
      for (final state in SystemMessageState.values) {
        final r = await render(tester, state, brightness: brightness);
        expect(r.background.a, 1.0, reason: '${state.name} is translucent');
      }
    });
  }

  testWidgets('long text wraps instead of overflowing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SystemMessageChip(
            text: 'Gerry ' * 40,
            state: SystemMessageState.warning,
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  test('systemStateOf survives a message with no state attached', () {
    // Anything that builds a chatview.Message without going through
    // _convertMessage (the unread divider, a future call site) must not blow
    // up the builder.
    final bare = chatview.Message(
      id: 'x',
      message: 'hi',
      createdAt: DateTime.now(),
      sentBy: systemId,
    );

    expect(systemStateOf(bare), SystemMessageState.info);
  });

  test('systemStateOf ignores a state name it does not know', () {
    final future = chatview.Message(
      id: 'x',
      message: 'hi',
      createdAt: DateTime.now(),
      sentBy: systemId,
      update: const {systemStateKey: 'catastrophe'},
    );

    expect(systemStateOf(future), SystemMessageState.info);
  });
}
