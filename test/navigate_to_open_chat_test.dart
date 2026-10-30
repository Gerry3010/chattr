// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

// CHAT-53: a tap on a notification for the chat that is already open pushed a
// SECOND screen of it (`pushAndRemoveUntil`). The old screen, disposed only
// after the exit transition, saw "active chat = my id" and cleared it — the id
// the new screen had just set. From then on the open chat showed in-app
// banners for its own messages. The same mistake openChatAtMessage already
// avoids (2026-08-23); navigateToChat now goes back to the open chat instead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chattr/core/navigation/chat_navigation.dart';
import 'package:chattr/core/navigation/navigation_service.dart';
import 'package:chattr/features/chats/chat_model.dart';
import 'package:chattr/screens/chat/chat_view_screen.dart';

void main() {
  late NavigationService service;

  setUp(() {
    service = NavigationService();
    OpenChats.leave('c1');
  });

  tearDown(() => OpenChats.leave('c1'));

  Future<void> pumpStack(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: service.navigatorKey,
      home: const Text('chat list'),
    ));
    // The open chat (a stand-in page under the real route name) …
    service.navigatorKey.currentState!.push(MaterialPageRoute<void>(
      settings: RouteSettings(name: chatRouteName('c1')),
      builder: (_) => const Text('chat c1'),
    ));
    OpenChats.enter('c1');
    await tester.pumpAndSettle();
    // … and something on top of it, say its info page.
    service.navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Text('chat info'),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Tipp auf die Benachrichtigung des offenen Chats: zurück dorthin',
      (tester) async {
    await pumpStack(tester);

    service.navigateToChat(Chat(id: 'c1', createdAt: DateTime(2026)));
    await tester.pumpAndSettle();

    expect(find.text('chat c1'), findsOneWidget);
    expect(find.text('chat info'), findsNothing);
    expect(find.byType(ChatViewScreen), findsNothing,
        reason: 'kein zweiter Bildschirm desselben Chats');
  });
}
